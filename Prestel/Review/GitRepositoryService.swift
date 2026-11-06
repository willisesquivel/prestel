import Darwin
import Foundation

actor GitRepositoryService: GitReviewServicing {
    private let runner: any GitCommandExecuting
    private var cache = ReviewContentCache()

    init(runner: any GitCommandExecuting = GitProcessRunner.shared) {
        self.runner = runner
    }

    func resolveRepository(directory: String) async throws -> RepositoryKey? {
        let inside: GitCommandResult
        do {
            inside = try await git(
                directory: directory,
                arguments: ["rev-parse", "--is-inside-work-tree"],
                timeout: ReviewBudgets.discoveryTimeout,
                limit: 4_096
            )
        } catch GitRunnerError.failed(let status, _) where status == 128 {
            return nil
        }
        let insideText = text(inside.stdout).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if insideText == "false" {
            do {
                let bare = try await git(
                    directory: directory,
                    arguments: ["rev-parse", "--is-bare-repository"],
                    timeout: ReviewBudgets.discoveryTimeout,
                    limit: 4_096
                )
                if text(bare.stdout).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" {
                    throw GitReviewServiceError.bareRepository
                }
            } catch GitReviewServiceError.bareRepository {
                throw GitReviewServiceError.bareRepository
            } catch {
                return nil
            }
            return nil
        }
        if insideText != "true" { return nil }

        let worktree = try await pathOutput(directory: directory, arguments: ["rev-parse", "--show-toplevel"])
        let gitDir = try await pathOutput(directory: directory, arguments: ["rev-parse", "--absolute-git-dir"])
        let common = try await pathOutput(directory: directory, arguments: ["rev-parse", "--git-common-dir"])
        let commonAbsolute: String
        if common.hasPrefix("/") {
            commonAbsolute = common
        } else {
            commonAbsolute = URL(fileURLWithPath: worktree).appendingPathComponent(common).standardizedFileURL.path
        }
        return RepositoryKey(worktreeRoot: worktree, gitDirectory: gitDir, commonGitDirectory: commonAbsolute)
    }

    func loadCatalog(for key: RepositoryKey, generation: UInt64) async throws -> ReviewSnapshot {
        let statusData = try await git(
            directory: key.worktreeRoot,
            arguments: [
                "--no-optional-locks", "-C", key.worktreeRoot,
                "-c", "color.ui=never",
                "-c", "core.fsmonitor=",
                "-c", "core.useBuiltinFSMonitor=false",
                "-c", "diff.autoRefreshIndex=false",
                "status", "--porcelain=v2", "-z", "--branch",
                "--untracked-files=all", "--no-ahead-behind",
                "--ignore-submodules=none", "--find-renames"
            ],
            timeout: ReviewBudgets.operationTimeout,
            limit: ReviewBudgets.statusOutputBytes
        )
        let parsed = GitStatusParser.parse(statusData.stdout)
        let stagedStats = try await numstat(root: key.worktreeRoot, staged: true)
        let unstagedStats = try await numstat(root: key.worktreeRoot, staged: false)
        let fingerprint = indexFingerprint(gitDirectory: key.gitDirectory)
        let files = Self.catalog(
            status: parsed,
            staged: stagedStats,
            unstaged: unstagedStats
        )
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        let revision = RepositoryRevision(
            key: key,
            headOID: parsed.branch.oid,
            branchName: parsed.branch.head,
            isDetached: parsed.branch.isDetached,
            isUnborn: parsed.branch.isUnborn,
            indexFingerprint: fingerprint,
            generation: generation
        )
        return ReviewSnapshot(
            revision: revision,
            files: files,
            additions: additions,
            deletions: deletions,
            isComplete: !parsed.isTruncated,
            isClean: files.isEmpty,
            isBare: false,
            waitingOnIndexLock: FileManager.default.fileExists(atPath: (key.gitDirectory as NSString).appendingPathComponent("index.lock")),
            diagnostic: parsed.isTruncated ? "Status output exceeded the catalog budget." : nil
        )
    }

    func loadComparison(
        for key: RepositoryKey,
        file: ChangedFile,
        comparison: ComparisonSummary,
        generation: UInt64,
        loadLarge: Bool
    ) async throws -> FileDiff {
        if file.kind == .conflicted || comparison.kind == .conflict {
            return try await loadConflictPreview(key: key, file: file, comparison: comparison)
        }
        if file.kind == .submodule || comparison.newMode == "160000" || comparison.oldMode == "160000" {
            return FileDiff(
                fileID: file.id,
                comparison: comparison.kind,
                revision: "\(generation):\(file.id):\(comparison.kind.rawValue)",
                hunks: [],
                oldSource: nil,
                newSource: nil,
                limitation: .submodule(summary: "Submodule changed."),
                patchText: "",
                additions: comparison.additions ?? 0,
                deletions: comparison.deletions ?? 0
            )
        }
        if isSymlink(comparison) {
            return try await loadSymlinkDiff(key: key, file: file, comparison: comparison)
        }

        let patch = try await loadPatch(key: key, file: file, comparison: comparison)
        if comparison.isBinary || patch.isBinary {
            return FileDiff(
                fileID: file.id,
                comparison: comparison.kind,
                revision: "\(generation):\(file.id):\(comparison.kind.rawValue)",
                hunks: [],
                oldSource: nil,
                newSource: nil,
                limitation: .binary,
                patchText: patch.raw,
                additions: comparison.additions ?? 0,
                deletions: comparison.deletions ?? 0
            )
        }

        let changedLines = patch.hunks.reduce(0) { total, hunk in
            total + hunk.lines.filter { $0.kind != .context }.count
        }
        let patchBytes = patch.raw.utf8.count
        if !loadLarge, (patchBytes > ReviewBudgets.automaticPatchBytes || changedLines > ReviewBudgets.automaticChangedLines) {
            return FileDiff(
                fileID: file.id,
                comparison: comparison.kind,
                revision: "\(generation):\(file.id):\(comparison.kind.rawValue)",
                hunks: [],
                oldSource: nil,
                newSource: nil,
                limitation: .large(reason: patchBytes > ReviewBudgets.automaticPatchBytes
                    ? "This patch exceeds 1 MB."
                    : "This patch has more than 10,000 changed lines."),
                patchText: patch.raw,
                additions: comparison.additions ?? 0,
                deletions: comparison.deletions ?? 0
            )
        }
        if patchBytes > ReviewBudgets.explicitPatchBytes || changedLines > ReviewBudgets.explicitDisplayedLines {
            return FileDiff(
                fileID: file.id,
                comparison: comparison.kind,
                revision: "\(generation):\(file.id):\(comparison.kind.rawValue)",
                hunks: [],
                oldSource: nil,
                newSource: nil,
                limitation: .large(reason: "This diff exceeds the display limit."),
                patchText: "",
                additions: comparison.additions ?? 0,
                deletions: comparison.deletions ?? 0
            )
        }

        if patch.hunks.isEmpty, comparison.oldMode != comparison.newMode {
            return FileDiff(
                fileID: file.id,
                comparison: comparison.kind,
                revision: "\(generation):\(file.id):\(comparison.kind.rawValue)",
                hunks: [],
                oldSource: nil,
                newSource: nil,
                limitation: .modeOnly,
                patchText: patch.raw,
                additions: 0,
                deletions: 0
            )
        }

        let oldSource = try await sourceSnapshot(key: key, comparison: comparison, side: .old)
        let newSource = try await sourceSnapshot(key: key, comparison: comparison, side: .new)
        if let oldSource, let newSource {
            try Self.validate(patch: patch, old: oldSource, new: newSource)
        }
        let additions = patch.hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count }
        let deletions = patch.hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count }
        return FileDiff(
            fileID: file.id,
            comparison: comparison.kind,
            revision: "\(generation):\(file.id):\(comparison.kind.rawValue):\(comparison.newOID ?? "")",
            hunks: patch.hunks,
            oldSource: oldSource,
            newSource: newSource,
            limitation: .none,
            patchText: patch.raw,
            additions: additions,
            deletions: deletions
        )
    }

    private enum SnapshotSide { case old, new }

    private func loadPatch(key: RepositoryKey, file: ChangedFile, comparison: ComparisonSummary) async throws -> UnifiedDiffParser.ParsedPatch {
        var arguments = [
            "--no-optional-locks", "-C", key.worktreeRoot,
            "-c", "color.ui=never",
            "-c", "core.fsmonitor=",
            "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-prefix",
            "-U\(ReviewBudgets.contextLines)", "--find-renames"
        ]
        switch comparison.kind {
        case .staged:
            arguments.append("--cached")
        case .unstaged:
            break
        case .untracked:
            arguments.append(contentsOf: ["--no-index", "--", "/dev/null", comparison.newPath.display])
            let result = try await git(
                directory: key.worktreeRoot,
                arguments: arguments,
                timeout: ReviewBudgets.operationTimeout,
                limit: ReviewBudgets.explicitPatchBytes,
                treatDiffExitAsSuccess: true
            )
            return try UnifiedDiffParser.parse(result.stdout)
        case .conflict:
            break
        }
        if let oldPath = comparison.oldPath, oldPath.display != comparison.newPath.display {
            arguments.append(contentsOf: ["--", oldPath.display, comparison.newPath.display])
        } else {
            arguments.append(contentsOf: ["--", comparison.newPath.display])
        }
        let result = try await git(
            directory: key.worktreeRoot,
            arguments: arguments,
            timeout: ReviewBudgets.operationTimeout,
            limit: ReviewBudgets.explicitPatchBytes,
            treatDiffExitAsSuccess: true
        )
        return try UnifiedDiffParser.parse(result.stdout)
    }

    private func sourceSnapshot(key: RepositoryKey, comparison: ComparisonSummary, side: SnapshotSide) async throws -> SourceSnapshot? {
        switch (comparison.kind, side) {
        case (.staged, .old):
            guard let oid = comparison.oldOID, oid != String(repeating: "0", count: oid.count) else {
                return SourceSnapshot(identity: "empty", text: "", data: Data(), isBinary: false, hasTrailingNewline: false, exceedsBudget: false)
            }
            return try await blob(root: key.worktreeRoot, oid: oid)
        case (.staged, .new):
            guard let oid = comparison.newOID, oid != String(repeating: "0", count: oid.count) else { return nil }
            return try await blob(root: key.worktreeRoot, oid: oid)
        case (.unstaged, .old):
            guard let oid = comparison.oldOID, oid != String(repeating: "0", count: oid.count) else {
                return SourceSnapshot(identity: "empty", text: "", data: Data(), isBinary: false, hasTrailingNewline: false, exceedsBudget: false)
            }
            return try await blob(root: key.worktreeRoot, oid: oid)
        case (.unstaged, .new), (.untracked, .new), (.conflict, .new):
            return try workingTreeFile(root: key.worktreeRoot, relative: comparison.newPath.display)
        case (.untracked, .old), (.conflict, .old):
            return SourceSnapshot(identity: "empty", text: "", data: Data(), isBinary: false, hasTrailingNewline: false, exceedsBudget: false)
        }
    }

    private func blob(root: String, oid: String) async throws -> SourceSnapshot {
        if let cached = cache.body(identity: "blob:\(oid)") { return cached }
        let result = try await git(
            directory: root,
            arguments: ["--no-optional-locks", "-C", root, "cat-file", "-p", oid],
            timeout: ReviewBudgets.operationTimeout,
            limit: ReviewBudgets.sourceSnapshotBytes + 1
        )
        let snapshot = Self.snapshot(identity: "blob:\(oid)", data: result.stdout)
        cache.store(snapshot)
        return snapshot
    }

    private func workingTreeFile(root: String, relative: String) throws -> SourceSnapshot {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return SourceSnapshot(identity: "missing:\(relative)", text: "", data: Data(), isBinary: false, hasTrailingNewline: false, exceedsBudget: false)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw GitReviewServiceError.unreadable(relative)
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            let data = Data(destination.utf8)
            return SourceSnapshot(identity: "symlink:\(relative):\(destination)", text: destination, data: data, isBinary: false, hasTrailingNewline: false, exceedsBudget: false)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let snapshot = Self.snapshot(identity: "worktree:\(relative):\(info.st_mtimespec.tv_sec):\(info.st_size)", data: data)
        cache.store(snapshot)
        return snapshot
    }

    private func loadSymlinkDiff(key: RepositoryKey, file: ChangedFile, comparison: ComparisonSummary) async throws -> FileDiff {
        let oldTarget = try await sourceSnapshot(key: key, comparison: comparison, side: .old)?.text ?? ""
        let newTarget = try await sourceSnapshot(key: key, comparison: comparison, side: .new)?.text ?? ""
        return FileDiff(
            fileID: file.id,
            comparison: comparison.kind,
            revision: "symlink:\(file.id):\(oldTarget)->\(newTarget)",
            hunks: [],
            oldSource: nil,
            newSource: nil,
            limitation: .symlink(target: "\(oldTarget) → \(newTarget)"),
            patchText: "",
            additions: oldTarget == newTarget ? 0 : 1,
            deletions: oldTarget == newTarget ? 0 : 1
        )
    }

    private func loadConflictPreview(key: RepositoryKey, file: ChangedFile, comparison: ComparisonSummary) async throws -> FileDiff {
        let snapshot = try workingTreeFile(root: key.worktreeRoot, relative: comparison.newPath.display)
        let text = snapshot.text ?? ""
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let hunkLines: [DiffLine] = lines.enumerated().map { index, line in
            DiffLine(kind: .context, oldNumber: index + 1, newNumber: index + 1, text: line, missingNewline: false)
        }
        let hunk = DiffHunk(oldStart: 1, oldCount: hunkLines.count, newStart: 1, newCount: hunkLines.count, header: "Working file", lines: hunkLines)
        return FileDiff(
            fileID: file.id,
            comparison: .conflict,
            revision: "conflict:\(file.id):\(snapshot.identity)",
            hunks: snapshot.isBinary ? [] : [hunk],
            oldSource: nil,
            newSource: snapshot,
            limitation: snapshot.isBinary ? .binary : .conflictPreview,
            patchText: "",
            additions: 0,
            deletions: 0
        )
    }

    private func numstat(root: String, staged: Bool) async throws -> [GitNumstatParser.Record] {
        var arguments = [
            "--no-optional-locks", "-C", root,
            "-c", "color.ui=never",
            "diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "--find-renames"
        ]
        if staged { arguments.append("--cached") }
        let result = try await git(
            directory: root,
            arguments: arguments,
            timeout: ReviewBudgets.operationTimeout,
            limit: ReviewBudgets.statusOutputBytes,
            treatDiffExitAsSuccess: true
        )
        return GitNumstatParser.parse(result.stdout)
    }

    private func git(
        directory: String,
        arguments: [String],
        timeout: Duration,
        limit: Int,
        treatDiffExitAsSuccess: Bool = false
    ) async throws -> GitCommandResult {
        try await runner.run(
            GitCommandRequest(
                directory: directory,
                arguments: arguments,
                timeout: timeout,
                outputLimit: limit,
                treatDiffExitAsSuccess: treatDiffExitAsSuccess
            )
        )
    }

    private func pathOutput(directory: String, arguments: [String]) async throws -> String {
        let result = try await git(directory: directory, arguments: arguments, timeout: ReviewBudgets.discoveryTimeout, limit: 64 * 1024)
        var text = text(result.stdout)
        if text.hasSuffix("\n") { text.removeLast() }
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    func commitMaterial(for key: RepositoryKey, paths: [String], untrackedPaths: [String]) async throws -> CommitMaterial {
        let subjects = await recentSubjects(root: key.worktreeRoot)
        guard !paths.isEmpty else {
            return CommitMaterial(diff: "", recentSubjects: subjects)
        }
        var diff = try await workingDiff(root: key.worktreeRoot, paths: paths)
        let untracked = try untrackedPreview(root: key.worktreeRoot, paths: untrackedPaths)
        if !untracked.isEmpty {
            if !diff.isEmpty { diff += "\n" }
            diff += untracked
        }
        return CommitMaterial(diff: diff, recentSubjects: subjects)
    }

    func commit(in key: RepositoryKey, paths: [String], message: String, push: Bool) async throws -> CommitOutcome {
        let message = CommitMessage.prepared(message)
        guard !CommitMessage.subjectLine(message).isEmpty else {
            throw GitReviewServiceError.commitRejected("Write a commit message first.")
        }
        guard !paths.isEmpty else {
            throw GitReviewServiceError.commitRejected("There is nothing to commit.")
        }
        let lock = (key.gitDirectory as NSString).appendingPathComponent("index.lock")
        if FileManager.default.fileExists(atPath: lock) {
            throw GitReviewServiceError.commitRejected("Wait for the Git operation to finish.")
        }
        do {
            try await stage(root: key.worktreeRoot, paths: paths)
            _ = try await git(
                directory: key.worktreeRoot,
                arguments: ["-C", key.worktreeRoot, "commit", "-m", message],
                timeout: ReviewBudgets.commitTimeout,
                limit: 256 * 1024
            )
        } catch let error as GitReviewServiceError {
            throw error
        } catch GitRunnerError.failed(_, let stderr) {
            throw GitReviewServiceError.commitRejected(CommitDigest.failureLine(stderr, fallback: "Git could not commit."))
        }
        guard push else { return .committed }
        return await pushHead(root: key.worktreeRoot)
    }

    func pullRequestURL(for key: RepositoryKey) async -> URL? {
        let root = key.worktreeRoot
        guard let branch = try? await pathOutput(directory: root, arguments: ["rev-parse", "--abbrev-ref", "HEAD"]),
              branch != "HEAD" else {
            return nil
        }
        // The page must belong to the remote the push went to, which is not
        // always `origin`.
        let name = await pushRemoteName(root: root, branch: branch)
        guard let remote = try? await pathOutput(directory: root, arguments: ["remote", "get-url", "--push", name]) else {
            return nil
        }
        return CommitPlanner.pullRequestURL(remote: remote, branch: branch)
    }

    /// The remote a plain `git push` from `branch` uses once an upstream exists;
    /// a branch without one is pushed to `origin` with `-u`.
    private func pushRemoteName(root: String, branch: String) async -> String {
        func config(_ key: String) async -> String? {
            guard let value = try? await pathOutput(directory: root, arguments: ["config", "--get", key]),
                  !value.isEmpty else { return nil }
            return value
        }
        guard await config("branch.\(branch).merge") != nil else { return "origin" }
        if let name = await config("branch.\(branch).pushRemote") { return name }
        if let name = await config("remote.pushDefault") { return name }
        return await config("branch.\(branch).remote") ?? "origin"
    }

    /// Stages what still needs it. A file already in the index is left as is:
    /// one the user split with `git add -p` keeps only its staged hunks in the
    /// commit, and a staged deletion or rename side has nothing left in the
    /// work tree for `git add` to match.
    private func stage(root: String, paths: [String]) async throws {
        let inIndex = try await stagedPaths(root: root, paths: paths)
        let paths = paths.filter { !inIndex.contains($0) }
        var start = 0
        while start < paths.count {
            let end = min(start + 100, paths.count)
            var arguments = ["-C", root, "add", "--"]
            arguments.append(contentsOf: paths[start..<end])
            _ = try await git(
                directory: root,
                arguments: arguments,
                timeout: ReviewBudgets.commitTimeout,
                limit: 256 * 1024
            )
            start = end
        }
    }

    /// Paths among `paths` whose index entry differs from HEAD.
    private func stagedPaths(root: String, paths: [String]) async throws -> Set<String> {
        var staged = Set<String>()
        var start = 0
        while start < paths.count {
            let end = min(start + 100, paths.count)
            var arguments = ["-C", root, "diff", "--cached", "--name-only", "-z", "--no-renames", "--"]
            arguments.append(contentsOf: paths[start..<end])
            let result = try await git(
                directory: root,
                arguments: arguments,
                timeout: ReviewBudgets.commitTimeout,
                limit: 1024 * 1024
            )
            staged.formUnion(text(result.stdout).split(separator: "\u{0}").map(String.init))
            start = end
        }
        return staged
    }

    private func pushHead(root: String) async -> CommitOutcome {
        let branch: String
        do {
            branch = try await pathOutput(directory: root, arguments: ["rev-parse", "--abbrev-ref", "HEAD"])
        } catch {
            return .committedPushFailed("Committed. The branch name could not be read, so nothing was pushed.")
        }
        if branch == "HEAD" {
            return .committedPushFailed("Committed. This checkout is detached, so nothing was pushed.")
        }
        let remotes: String
        do {
            let result = try await git(
                directory: root,
                arguments: ["remote"],
                timeout: ReviewBudgets.discoveryTimeout,
                limit: 64 * 1024
            )
            remotes = text(result.stdout)
        } catch {
            return .committedPushFailed("Committed. The remotes could not be read, so nothing was pushed.")
        }
        let names = remotes.split(whereSeparator: \.isNewline).map(String.init)
        var hasUpstream = false
        do {
            _ = try await git(
                directory: root,
                arguments: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
                timeout: ReviewBudgets.discoveryTimeout,
                limit: 4_096
            )
            hasUpstream = true
        } catch {
            hasUpstream = false
        }
        if !hasUpstream, !names.contains("origin") {
            return .committedPushFailed("Committed. There is no remote to push to.")
        }
        let arguments = hasUpstream
            ? ["-C", root, "push"]
            : ["-C", root, "push", "-u", "origin", "HEAD"]
        do {
            _ = try await git(
                directory: root,
                arguments: arguments,
                timeout: ReviewBudgets.pushTimeout,
                limit: 256 * 1024
            )
            return .committed
        } catch GitRunnerError.failed(_, let stderr) {
            let line = CommitDigest.failureLine(stderr, fallback: "the remote rejected the push")
            return .committedPushFailed("Committed. Push failed: \(line)")
        } catch {
            return .committedPushFailed("Committed. Push failed.")
        }
    }

    private func recentSubjects(root: String) async -> [String] {
        do {
            let result = try await git(
                directory: root,
                arguments: ["log", "-12", "--format=%s"],
                timeout: ReviewBudgets.discoveryTimeout,
                limit: 16 * 1024
            )
            let newest = text(result.stdout)
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(12)
                .map { String($0.prefix(120)) }
            return Array(newest.reversed())
        } catch {
            return []
        }
    }

    private func workingDiff(root: String, paths: [String]) async throws -> String {
        do {
            return try await diffText(root: root, extra: ["HEAD"], paths: paths)
        } catch GitRunnerError.failed {
            let staged = try await diffText(root: root, extra: ["--cached"], paths: paths)
            let unstaged = try await diffText(root: root, extra: [], paths: paths)
            return [staged, unstaged].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private func diffText(root: String, extra: [String], paths: [String]) async throws -> String {
        var chunks: [String] = []
        var start = 0
        while start < paths.count {
            let end = min(start + 40, paths.count)
            let batch = Array(paths[start..<end])
            do {
                let chunk = try await diffOutput(root: root, extra: extra, paths: batch)
                if !chunk.isEmpty { chunks.append(chunk) }
            } catch GitRunnerError.outputLimitExceeded {
                // One huge file must not sink the whole draft. Read the files of
                // this batch one at a time and stub the ones that are too big.
                for path in batch {
                    do {
                        let chunk = try await diffOutput(root: root, extra: extra, paths: [path])
                        if !chunk.isEmpty { chunks.append(chunk) }
                    } catch GitRunnerError.outputLimitExceeded {
                        chunks.append("diff --git a/\(path) b/\(path)\n[large change not shown]")
                    }
                }
            }
            start = end
        }
        return chunks.joined(separator: "\n")
    }

    private func diffOutput(root: String, extra: [String], paths: [String]) async throws -> String {
        var arguments = [
            "--no-optional-locks", "-C", root,
            "-c", "color.ui=never",
            "diff", "--no-ext-diff", "--no-textconv", "--no-color",
            "-U1", "--find-renames"
        ]
        arguments.append(contentsOf: extra)
        arguments.append("--")
        arguments.append(contentsOf: paths)
        let result = try await git(
            directory: root,
            arguments: arguments,
            timeout: ReviewBudgets.operationTimeout,
            limit: ReviewBudgets.commitDiffBytes,
            treatDiffExitAsSuccess: true
        )
        return text(result.stdout)
    }

    private func untrackedPreview(root: String, paths: [String]) throws -> String {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        var parts: [String] = []
        for relative in paths {
            let preview = try previewFile(root: rootURL, relative: relative)
            let block = "new file \(relative)\n\(preview)"
            parts.append(block)
        }
        return parts.joined(separator: "\n")
    }

    private func previewFile(root: URL, relative: String) throws -> String {
        let fileURL = URL(fileURLWithPath: relative, relativeTo: root).standardizedFileURL
        let rootPath = root.path
        guard fileURL.path == rootPath || fileURL.path.hasPrefix(rootPath + "/") else {
            return "[path omitted]\n"
        }
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else { return "[unreadable]\n" }
        if (info.st_mode & S_IFMT) == S_IFLNK { return "[symlink]\n" }
        if (info.st_mode & S_IFMT) != S_IFREG { return "[not a file]\n" }
        if info.st_size == 0 { return "[empty]\n" }
        // Only the start of a new file says what it is; never read all of a big one.
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "[unreadable]\n" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: ReviewBudgets.commitPreviewBytes), !data.isEmpty else {
            return "[unreadable]\n"
        }
        if data.prefix(8_000).contains(0) { return "[binary file]\n" }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        if Int64(data.count) < Int64(info.st_size) { text += "\n[rest of file not shown]" }
        return text + "\n"
    }

    private func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    private func indexFingerprint(gitDirectory: String) -> String {
        let index = (gitDirectory as NSString).appendingPathComponent("index")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: index),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else {
            return "missing"
        }
        return "\(size.intValue):\(modified.timeIntervalSince1970)"
    }

    private func isSymlink(_ comparison: ComparisonSummary) -> Bool {
        comparison.oldMode == "120000" || comparison.newMode == "120000"
    }

    static func snapshot(identity: String, data: Data) -> SourceSnapshot {
        let exceeds = data.count > ReviewBudgets.sourceSnapshotBytes
        let bounded = exceeds ? data.prefix(ReviewBudgets.sourceSnapshotBytes) : data
        let isBinary = bounded.contains(0)
        if isBinary {
            return SourceSnapshot(identity: identity, text: nil, data: Data(bounded), isBinary: true, hasTrailingNewline: false, exceedsBudget: exceeds)
        }
        guard let text = String(data: bounded, encoding: .utf8) else {
            return SourceSnapshot(identity: identity, text: nil, data: Data(bounded), isBinary: false, hasTrailingNewline: false, exceedsBudget: exceeds)
        }
        return SourceSnapshot(
            identity: identity,
            text: text,
            data: Data(bounded),
            isBinary: false,
            hasTrailingNewline: text.hasSuffix("\n"),
            exceedsBudget: exceeds
        )
    }

    static func validate(patch: UnifiedDiffParser.ParsedPatch, old: SourceSnapshot, new: SourceSnapshot) throws {
        guard let oldText = old.text, let newText = new.text else { return }
        let oldLines = Array(oldText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)).map(String.init)
        let newLines = Array(newText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)).map(String.init)
        for hunk in patch.hunks {
            for line in hunk.lines {
                switch line.kind {
                case .deletion, .context:
                    if let number = line.oldNumber, oldLines.indices.contains(number - 1), oldLines[number - 1] != line.text {
                        throw GitReviewServiceError.sourceMismatch
                    }
                case .addition:
                    if let number = line.newNumber, newLines.indices.contains(number - 1), newLines[number - 1] != line.text {
                        throw GitReviewServiceError.sourceMismatch
                    }
                }
            }
        }
    }

    static func catalog(
        status: GitStatusParser.ParsedStatus,
        staged: [GitNumstatParser.Record],
        unstaged: [GitNumstatParser.Record]
    ) -> [ChangedFile] {
        var files: [String: ChangedFile] = [:]
        func stats(in records: [GitNumstatParser.Record], path: String) -> GitNumstatParser.Record? {
            records.first { $0.path.display == path }
        }

        for record in status.ordinary {
            let path = record.path
            let xy = record.xy.padding(toLength: 2, withPad: ".", startingAt: 0)
            let indexState = xy.prefix(1)
            let workState = xy.suffix(1)
            var comparisons: [ComparisonSummary] = []
            if indexState != "." {
                let stat = stats(in: staged, path: path.display)
                comparisons.append(
                    ComparisonSummary(
                        kind: .staged,
                        additions: stat?.additions,
                        deletions: stat?.deletions,
                        isBinary: stat?.isBinary ?? false,
                        oldPath: nil,
                        newPath: path,
                        oldMode: record.headMode,
                        newMode: record.indexMode,
                        oldOID: record.headOID,
                        newOID: record.indexOID
                    )
                )
            }
            if workState != "." {
                let stat = stats(in: unstaged, path: path.display)
                comparisons.append(
                    ComparisonSummary(
                        kind: .unstaged,
                        additions: stat?.additions,
                        deletions: stat?.deletions,
                        isBinary: stat?.isBinary ?? false,
                        oldPath: nil,
                        newPath: path,
                        oldMode: record.indexMode,
                        newMode: record.worktreeMode,
                        oldOID: record.indexOID,
                        newOID: nil
                    )
                )
            }
            files[path.display] = ChangedFile(
                identityPath: path,
                kind: kind(from: xy, submodule: record.submodule, headMode: record.headMode, indexMode: record.indexMode, worktreeMode: record.worktreeMode),
                comparisons: comparisons,
                oldPath: nil
            )
        }

        for record in status.renames {
            let path = record.path
            let xy = record.xy.padding(toLength: 2, withPad: ".", startingAt: 0)
            var comparisons: [ComparisonSummary] = []
            if xy.prefix(1) != "." {
                let stat = stats(in: staged, path: path.display) ?? staged.first { $0.path.display == path.display || $0.origPath?.display == record.origPath.display }
                comparisons.append(
                    ComparisonSummary(
                        kind: .staged,
                        additions: stat?.additions,
                        deletions: stat?.deletions,
                        isBinary: stat?.isBinary ?? false,
                        oldPath: record.origPath,
                        newPath: path,
                        oldMode: record.headMode,
                        newMode: record.indexMode,
                        oldOID: record.headOID,
                        newOID: record.indexOID
                    )
                )
            }
            if xy.suffix(1) != "." {
                let stat = stats(in: unstaged, path: path.display)
                comparisons.append(
                    ComparisonSummary(
                        kind: .unstaged,
                        additions: stat?.additions,
                        deletions: stat?.deletions,
                        isBinary: stat?.isBinary ?? false,
                        oldPath: record.origPath,
                        newPath: path,
                        oldMode: record.indexMode,
                        newMode: record.worktreeMode,
                        oldOID: record.indexOID,
                        newOID: nil
                    )
                )
            }
            files[path.display] = ChangedFile(
                identityPath: path,
                kind: record.isCopy ? .copied : .renamed,
                comparisons: comparisons,
                oldPath: record.origPath
            )
        }

        for record in status.unmerged {
            files[record.path.display] = ChangedFile(
                identityPath: record.path,
                kind: .conflicted,
                comparisons: [
                    ComparisonSummary(
                        kind: .conflict,
                        additions: nil,
                        deletions: nil,
                        isBinary: false,
                        oldPath: nil,
                        newPath: record.path,
                        oldMode: record.stage2Mode,
                        newMode: record.worktreeMode,
                        oldOID: record.stage2OID,
                        newOID: nil
                    )
                ],
                oldPath: nil
            )
        }

        for path in status.untracked {
            files[path.display] = ChangedFile(
                identityPath: path,
                kind: .untracked,
                comparisons: [
                    ComparisonSummary(
                        kind: .untracked,
                        additions: nil,
                        deletions: nil,
                        isBinary: false,
                        oldPath: nil,
                        newPath: path,
                        oldMode: nil,
                        newMode: nil,
                        oldOID: nil,
                        newOID: nil
                    )
                ],
                oldPath: nil
            )
        }

        return files.values.sorted { $0.identityPath.display.localizedStandardCompare($1.identityPath.display) == .orderedAscending }
    }

    private static func kind(from xy: String, submodule: String, headMode: String, indexMode: String, worktreeMode: String) -> FileChangeKind {
        if submodule.hasPrefix("S") { return .submodule }
        if headMode == "120000" || indexMode == "120000" || worktreeMode == "120000" { return .symlink }
        if xy.contains("A") { return .added }
        if xy.contains("D") { return .deleted }
        if xy.contains("T") { return .typeChange }
        if xy.contains("M"), headMode != indexMode || indexMode != worktreeMode, !xy.contains("M") {
            return .modeChange
        }
        if xy.contains("M"), xy.filter({ $0 == "M" }).count == 0 {
            return .modeChange
        }
        if headMode != indexMode, indexMode == worktreeMode, !xy.contains("M"), !xy.contains("A"), !xy.contains("D") {
            return .modeChange
        }
        return .modified
    }
}

enum GitReviewServiceError: Error, Equatable {
    case bareRepository
    case sourceMismatch
    case unreadable(String)
    case commitRejected(String)
}

private struct ReviewContentCache {
    private var items: [String: SourceSnapshot] = [:]
    private var bytes = 0

    func body(identity: String) -> SourceSnapshot? { items[identity] }

    mutating func store(_ snapshot: SourceSnapshot) {
        if items[snapshot.identity] != nil { return }
        let size = snapshot.data.count
        while bytes + size > ReviewBudgets.contentCacheBytes, let key = items.keys.first {
            bytes -= items[key]?.data.count ?? 0
            items.removeValue(forKey: key)
        }
        items[snapshot.identity] = snapshot
        bytes += size
    }
}
