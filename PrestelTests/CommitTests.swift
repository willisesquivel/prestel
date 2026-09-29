import Foundation
import Testing
@testable import Prestel

@Suite
struct CommitTests {
    @Test func selectionSkipsConflictsUnsafePathsAndKeepsOrder() {
        let files = [
            sample("b.swift"),
            sample("a.swift", kind: .conflicted, lanes: [.conflict]),
            sample("../outside"),
            ChangedFile(
                identityPath: ReviewPath(display: "bad", bytes: [0xFF], isLossless: false),
                kind: .modified,
                comparisons: [lane("bad", .unstaged)],
                oldPath: nil
            )
        ]
        let selection = CommitPlanner.selection(from: files)
        #expect(selection.paths == ["b.swift"])
        #expect(selection.conflictPaths == ["a.swift"])
        #expect(selection.unsafePaths == ["../outside", "bad"])
    }

    @Test func pullRequestURLFollowsTheRemoteHost() {
        #expect(CommitPlanner.pullRequestURL(remote: "git@github.com:ian/prestel.git", branch: "feat/commit")?.absoluteString
            == "https://github.com/ian/prestel/pull/new/feat/commit")
        #expect(CommitPlanner.pullRequestURL(remote: "https://github.com/ian/prestel", branch: "main")?.absoluteString
            == "https://github.com/ian/prestel/pull/new/main")
        #expect(CommitPlanner.pullRequestURL(remote: "ssh://git@gitlab.com/group/sub/app.git", branch: "fix")?.absoluteString
            == "https://gitlab.com/group/sub/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=fix")
        #expect(CommitPlanner.pullRequestURL(remote: "git@bitbucket.org:team/app.git", branch: "fix")?.absoluteString
            == "https://bitbucket.org/team/app/pull-requests/new?source=fix")
        #expect(CommitPlanner.pullRequestURL(remote: "/Users/ian/repos/app.git", branch: "fix") == nil)
        #expect(CommitPlanner.pullRequestURL(remote: "git@github.com:ian/prestel.git", branch: "HEAD") == nil)
    }

    @Test func refusalBlocksConflictsLocksDetachedPushesAndIncompleteCatalogs() {
        let files = [sample("File.swift")]
        #expect(CommitPlanner.refusal(files: files, push: false, detached: false, indexLocked: true, catalogComplete: true) == "Wait for the Git operation to finish.")
        #expect(CommitPlanner.refusal(files: files, push: false, detached: false, indexLocked: false, catalogComplete: false) == "The file list is incomplete. Refresh before committing.")
        #expect(CommitPlanner.refusal(files: [sample("a.swift", kind: .conflicted, lanes: [.conflict])], push: false, detached: false, indexLocked: false, catalogComplete: true) == "Resolve the conflicted files before committing.")
        #expect(CommitPlanner.refusal(files: files, push: true, detached: true, indexLocked: false, catalogComplete: true) == "This checkout is detached. Commit without pushing.")
        #expect(CommitPlanner.refusal(files: files, push: false, detached: true, indexLocked: false, catalogComplete: true) == nil)
        #expect(!CommitPlanner.canSubmit(files: files, message: "  \n", push: false, detached: false, indexLocked: false, catalogComplete: true))
        #expect(CommitPlanner.canSubmit(files: files, message: "Fix send slot visibility", push: false, detached: false, indexLocked: false, catalogComplete: true))
    }

    @Test func subjectCleanupMatchesAMaintainerLine() {
        #expect(CommitMessage.prepared("  Fix send slot visibility\n") == "Fix send slot visibility")
        #expect(CommitMessage.prepared("  Fix send slot visibility\n\nThe slot stayed visible after send.\n") == "Fix send slot visibility\n\nThe slot stayed visible after send.")
        #expect(CommitMessage.subjectLine("  Fix send slot visibility\n\nThe slot stayed visible after send.") == "Fix send slot visibility")
        #expect(CommitMessage.composed(subject: "Fix send slot visibility.", detail: "Update files") == "Fix send slot visibility")
        #expect(CommitMessage.composed(subject: "Fix send slot visibility.", detail: "The slot stayed visible after send.") == "Fix send slot visibility\n\nThe slot stayed visible after send.")
        #expect(CommitMessage.subject(from: "\"Fix send slot visibility.\"") == "Fix send slot visibility")
        #expect(CommitMessage.subject(from: "Commit: Fix send slot visibility") == "Fix send slot visibility")
        #expect(CommitMessage.subject(from: "“Keep the slot.”") == "Keep the slot")
        let long = Array(repeating: "alpha", count: 20).joined(separator: " ")
        let clipped = CommitMessage.subject(from: long)
        #expect(clipped.count <= CommitMessage.maxSubjectLength)
        #expect(clipped.split(separator: " ").allSatisfy { $0 == "alpha" })
        #expect(CommitMessage.isWeak("Update files"))
        #expect(CommitMessage.isWeak("Fix"))
        #expect(!CommitMessage.isWeak("Fix send slot visibility"))
    }

    @Test func digestChunksWithoutDroppingContent() {
        let diff = String(repeating: "line\n", count: 80) + "last line"
        let chunks = CommitDigest.chunks(diff, budget: 100)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == diff)
        #expect(chunks.allSatisfy { $0.count <= 100 })
        #expect(CommitDigest.failureLine("hint: set upstream\nfatal: no upstream\n", fallback: "failed") == "no upstream")
    }

    @Test func localModelSelectionPrefersTheCodeModel() {
        #expect(OllamaCommitModel.preferredModel(in: ["other:latest", "qwen3-coder:30b"]) == "qwen3-coder:30b")
        #expect(OllamaCommitModel.preferredModel(in: ["other:latest", "qwen2.5-coder:7b"]) == "qwen2.5-coder:7b")
        #expect(OllamaCommitModel.preferredModel(in: ["other:latest", "gpt-oss-20b:latest"]) == "gpt-oss-20b:latest")
        #expect(OllamaCommitModel.preferredModel(in: ["qwen2.5-coder:1.5b", "gpt-oss-20b:latest"]) == "gpt-oss-20b:latest")
        #expect(OllamaCommitModel.preferredModel(in: ["other:latest", "qwen3-coder:480b-cloud"]) == nil)
    }

    @Test func promptCarriesTheDiffNotOnlyTheFileNames() {
        let body = CommitMessagePrompt.body(
            repository: "prestel",
            branch: "main",
            files: [sample("IOStrip.cpp", additions: 62, deletions: 11)],
            diff: "+ keep the slot",
            recentSubjects: ["Add terminal tabs"]
        )
        #expect(body.contains("Repository: prestel"))
        #expect(body.contains("Modified IOStrip.cpp +62 -11"))
        #expect(body.contains("+ keep the slot"))
        #expect(body.contains("- Add terminal tabs"))
        #expect(body.contains("Write the commit message."))
        #expect(CommitMessagePrompt.instructions.contains("72 characters"))
    }

    @Test func commitWritesTheWorkingTreeAndLeavesIgnoredFiles() async throws {
        let root = try GitFixture.make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.removeItem(atPath: (root as NSString).appendingPathComponent("unstaged.txt"))
        let service = GitRepositoryService()
        let key = try #require(try await service.resolveRepository(directory: root))
        let snapshot = try await service.loadCatalog(for: key, generation: 1)
        let selection = CommitPlanner.selection(from: snapshot.files)
        #expect(selection.paths.contains("unstaged.txt"))
        #expect(selection.paths.contains(".gitignore"))
        #expect(!selection.paths.contains("skip.log"))
        let material = try await service.commitMaterial(for: key, paths: selection.paths, untrackedPaths: selection.untrackedPaths)
        #expect(material.diff.contains("untracked.txt"))
        #expect(material.recentSubjects.contains("base"))
        let outcome = try await service.commit(in: key, paths: selection.paths, message: "Record the working tree files", push: false)
        #expect(outcome == .committed)
        let subject = try GitFixture.output(["log", "-1", "--format=%s"], in: root)
        #expect(subject.trimmingCharacters(in: .whitespacesAndNewlines) == "Record the working tree files")
        let status = try GitFixture.output(["status", "--porcelain"], in: root)
        #expect(status == " M both.txt\n")
        let both = try GitFixture.output(["show", "HEAD:both.txt"], in: root)
        // both.txt was split with `git add -p`: only the staged hunk is committed.
        #expect(both == "staged-both\n")
        let listed = try GitFixture.output(["ls-files"], in: root)
        #expect(listed.contains(".gitignore"))
        #expect(!listed.contains("skip.log"))
        #expect(!listed.contains("unstaged.txt"))
    }

    @Test func draftMaterialIncludesFilesPastTheOldDiffCutoff() async throws {
        let root = try GitFixture.make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for index in 0..<45 {
            let name = String(format: "change-%02d.txt", index)
            let content = "marker-\(index) " + String(repeating: "code line\n", count: 40)
            try content.write(toFile: (root as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let untracked = String(repeating: "new code line\n", count: 500) + "last untracked behavior\n"
        try untracked.write(toFile: (root as NSString).appendingPathComponent("new-large.txt"), atomically: true, encoding: .utf8)
        try GitFixture.run(["add", "change-*.txt"], in: root)
        let service = GitRepositoryService()
        let key = try #require(try await service.resolveRepository(directory: root))
        let snapshot = try await service.loadCatalog(for: key, generation: 1)
        let selection = CommitPlanner.selection(from: snapshot.files)
        let material = try await service.commitMaterial(for: key, paths: selection.paths, untrackedPaths: selection.untrackedPaths)
        #expect(material.diff.count > 6_000)
        #expect(material.diff.contains("marker-0 "))
        #expect(material.diff.contains("marker-44 "))
        #expect(material.diff.contains("last untracked behavior"))
        #expect(CommitDigest.chunks(material.diff, budget: 6_000).joined() == material.diff)
    }

    @Test func commitKeepsStagedRenamesWhole() async throws {
        let root = try GitFixture.make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try GitFixture.run(["mv", "staged.txt", "renamed.txt"], in: root)
        let service = GitRepositoryService()
        let key = try #require(try await service.resolveRepository(directory: root))
        let snapshot = try await service.loadCatalog(for: key, generation: 1)
        let paths = CommitPlanner.selection(from: snapshot.files).paths
        _ = try await service.commit(in: key, paths: paths, message: "Rename the staged file", push: false)
        let listed = try GitFixture.output(["ls-tree", "-r", "--name-only", "HEAD"], in: root).split(separator: "\n").map(String.init)
        #expect(listed.contains("renamed.txt"))
        #expect(!listed.contains("staged.txt"))
    }

    @Test func pullRequestFollowsTheUpstreamRemote() async throws {
        let root = try GitFixture.make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try GitFixture.run(["remote", "add", "origin", "https://github.com/me/fork.git"], in: root)
        try GitFixture.run(["remote", "add", "upstream", "git@github.com:team/project.git"], in: root)
        let service = GitRepositoryService()
        let key = try #require(try await service.resolveRepository(directory: root))
        // No upstream yet: the push goes to origin.
        #expect(await service.pullRequestURL(for: key)?.absoluteString == "https://github.com/me/fork/pull/new/main")
        try GitFixture.run(["config", "branch.main.remote", "upstream"], in: root)
        try GitFixture.run(["config", "branch.main.merge", "refs/heads/main"], in: root)
        #expect(await service.pullRequestURL(for: key)?.absoluteString == "https://github.com/team/project/pull/new/main")
    }

    @MainActor @Test func clipboardWritesAcceptBoundedText() {
        #expect(TerminalSession.clipboardText(from: Data("hello".utf8)) == "hello")
        #expect(TerminalSession.clipboardText(from: Data()) == nil)
        #expect(TerminalSession.clipboardText(from: Data([0xFF, 0xFE])) == nil)
        #expect(TerminalSession.clipboardText(from: Data(count: TerminalSession.maxClipboardWriteBytes + 1)) == nil)
    }

    @Test func pushWithoutARemoteKeepsTheCommit() async throws {
        let root = try GitFixture.make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let service = GitRepositoryService()
        let key = try #require(try await service.resolveRepository(directory: root))
        let snapshot = try await service.loadCatalog(for: key, generation: 1)
        let paths = CommitPlanner.selection(from: snapshot.files).paths
        let outcome = try await service.commit(in: key, paths: paths, message: "Record the working tree files", push: true)
        #expect(outcome == .committedPushFailed("Committed. There is no remote to push to."))
        let subject = try GitFixture.output(["log", "-1", "--format=%s"], in: root)
        #expect(subject.trimmingCharacters(in: .whitespacesAndNewlines) == "Record the working tree files")
    }
}

@Suite
@MainActor
struct CommitComposerModelTests {
    @Test func commitSubmitsTheListedPathsAndName() async {
        let service = RecordingCommitService(pushFailure: nil)
        let model = CodeReviewModel(service: service, watcher: CommitNullWatcher(), expandByDefault: false)
        let session = TerminalSession(descriptor: TabDescriptor(directory: "/tmp/repo-b"))
        model.bind(visible: true, windowID: UUID(), session: session)
        await waitUntil { model.loadState == .ready }
        #expect(model.loadState == .ready)
        model.openCommitComposer()
        model.updateCommitMessage("  Fix send slot visibility\n")
        model.commitFromComposer()
        await waitUntil { await service.recorded() != nil }
        let recorded = await service.recorded()
        #expect(recorded?.message == "Fix send slot visibility")
        #expect(recorded?.paths == ["IOStrip.cpp"])
        #expect(recorded?.push == false)
        #expect(model.commitDraft == nil)
    }

    @Test func failedPushStaysInTheComposer() async {
        let service = RecordingCommitService(pushFailure: "Committed. There is no remote to push to.")
        let model = CodeReviewModel(service: service, watcher: CommitNullWatcher(), expandByDefault: false)
        let session = TerminalSession(descriptor: TabDescriptor(directory: "/tmp/repo-b"))
        model.bind(visible: true, windowID: UUID(), session: session)
        await waitUntil { model.loadState == .ready }
        model.openCommitComposer()
        model.updateCommitMessage("Fix send slot visibility")
        model.updateCommitAction(.push)
        model.commitFromComposer()
        await waitUntil { model.commitDraft?.notice != nil }
        #expect(model.commitDraft?.notice == "Committed. There is no remote to push to.")
        #expect(model.commitDraft?.isCommitting == false)
    }
}

private func waitUntil(_ ready: @MainActor () async -> Bool) async {
    for _ in 0..<50 {
        if await ready() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private func sample(
    _ path: String,
    kind: FileChangeKind = .modified,
    lanes: [FileComparisonKind] = [.unstaged],
    additions: Int = 1,
    deletions: Int = 0
) -> ChangedFile {
    ChangedFile(
        identityPath: .from(path),
        kind: kind,
        comparisons: lanes.map { lane(path, $0, additions: additions, deletions: deletions) },
        oldPath: nil
    )
}

private func lane(
    _ path: String,
    _ kind: FileComparisonKind,
    additions: Int = 1,
    deletions: Int = 0
) -> ComparisonSummary {
    ComparisonSummary(
        kind: kind,
        additions: additions,
        deletions: deletions,
        isBinary: false,
        oldPath: nil,
        newPath: .from(path),
        oldMode: "100644",
        newMode: "100644",
        oldOID: nil,
        newOID: nil
    )
}

private actor RecordingCommitService: GitReviewServicing {
    private let pushFailure: String?
    private var recordedCommit: (paths: [String], message: String, push: Bool)?

    init(pushFailure: String?) {
        self.pushFailure = pushFailure
    }

    func recorded() -> (paths: [String], message: String, push: Bool)? {
        recordedCommit
    }

    func resolveRepository(directory: String) async throws -> RepositoryKey? {
        RepositoryKey(worktreeRoot: "/tmp/repo-b", gitDirectory: "/tmp/repo-b/.git", commonGitDirectory: "/tmp/repo-b/.git")
    }

    func loadCatalog(for key: RepositoryKey, generation: UInt64) async throws -> ReviewSnapshot {
        ReviewSnapshot(
            revision: RepositoryRevision(
                key: key,
                headOID: "abc",
                branchName: "main",
                isDetached: false,
                isUnborn: false,
                indexFingerprint: "1",
                generation: generation
            ),
            files: [sample("IOStrip.cpp", additions: 62, deletions: 11)],
            additions: 62,
            deletions: 11,
            isComplete: true,
            isClean: false,
            isBare: false,
            waitingOnIndexLock: false,
            diagnostic: nil
        )
    }

    func loadComparison(
        for key: RepositoryKey,
        file: ChangedFile,
        comparison: ComparisonSummary,
        generation: UInt64,
        loadLarge: Bool
    ) async throws -> FileDiff {
        FileDiff(
            fileID: file.id,
            comparison: comparison.kind,
            revision: "test",
            hunks: [],
            oldSource: nil,
            newSource: nil,
            limitation: .none,
            patchText: "",
            additions: 0,
            deletions: 0
        )
    }

    func commit(in key: RepositoryKey, paths: [String], message: String, push: Bool) async throws -> CommitOutcome {
        recordedCommit = (paths, message, push)
        if push, let pushFailure {
            return .committedPushFailed(pushFailure)
        }
        return .committed
    }
}

private final class CommitNullWatcher: RepositoryWatching, @unchecked Sendable {
    func events(for key: RepositoryKey) -> AsyncStream<RepositoryInvalidation> {
        AsyncStream { $0.finish() }
    }
    func stop(_ key: RepositoryKey) {}
    func stopAll() {}
}
