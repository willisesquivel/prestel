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

    @Test func failureLineSkipsHintsAndFatalPrefix() {
        #expect(CommitDigest.failureLine("hint: set upstream\nfatal: no upstream\n", fallback: "failed") == "no upstream")
    }

    @Test func streamedSubjectsStayHiddenUntilTheyCannotBeVague() {
        // Everything the weak list would reject is held back while it streams...
        for weak in ["U", "Update", "Update files", "Update the code", "Various changes"] {
            #expect(!CommitMessage.isSafeToShow(partialSubject: weak))
        }
        // ...and anything shown is already too long to be on that list.
        #expect(CommitMessage.isSafeToShow(partialSubject: "Keep the send slot visible"))
        #expect(!CommitMessage.isWeak("Keep the send slot visible"))
    }

    @Test func buildOutputAndLockfilesAreNoise() {
        for path in [
            "build-xcode-stage4/CMakeCache.txt", "build/out.o", "node_modules/a/index.js",
            "app/Pods/Foo/Foo.m", "package-lock.json", "web/yarn.lock", "App.xcodeproj/project.pbxproj",
            "dist/app.min.js", "Sources/cache.pyc"
        ] {
            #expect(CommitDigest.isNoise(path), "\(path)")
        }
        for path in [
            "Prestel/Review/CommitPlanner.swift", "README.md", "scripts/build-dmg.sh",
            "Sources/Builder.swift", "docs/build.md", "buildings.txt"
        ] {
            #expect(!CommitDigest.isNoise(path), "\(path)")
        }
    }

    @Test func generatedFilesSummarizeByTopLevelDirectory() {
        let files = [
            sample("build-x/a.txt", additions: 6, deletions: 1),
            sample("build-x/CMakeFiles/b.txt", additions: 4, deletions: 2),
            sample("package-lock.json", additions: 10, deletions: 3)
        ]
        let lines = CommitDigest.summary(of: files)
        #expect(lines == ["build-x/ - 2 files, +10 -3", "package-lock.json - 1 file, +10 -3"])
        let body = CommitMessagePrompt.body(repository: "r", branch: "main", files: [], generated: files, diff: "", recentSubjects: [])
        #expect(body.contains("Generated or build files, diffs not shown:"))
        #expect(body.contains("- build-x/ - 2 files, +10 -3"))
        #expect(body.contains("(none besides the generated files below)"))
    }

    @Test func bodiesAreTidiedIntoOneBulletStyle() {
        let raw = """
            ## Changes
            * **Stream** the draft into the box
            • Hold back vague subjects
            – Hold back vague subjects
            -
            - Restore the old text on failure
            """
        let tidy = CommitMessage.tidied(detail: raw)
        // One bullet style, markdown gone, the empty and repeated bullets dropped.
        #expect(tidy == "Changes\n- Stream the draft into the box\n- Hold back vague subjects\n- Restore the old text on failure")
        let many = (1...9).map { "- point \($0)" }.joined(separator: "\n")
        #expect(CommitMessage.tidied(detail: many).split(separator: "\n").count == CommitMessage.maxBodyBullets)
        #expect(CommitMessage.composed(subject: "Add streaming", detail: "**Bold** sentence.") == "Add streaming\n\nBold sentence.")
    }

    @Test func draftMaterialSurvivesHugeFiles() async throws {
        let root = try GitFixture.make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // A tracked file whose diff is far past the read limit, and a huge new file.
        let huge = String(repeating: "0123456789\n", count: 150_000)
        try huge.write(toFile: (root as NSString).appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        try GitFixture.run(["add", "staged.txt"], in: root)
        try ("first line of the new file\n" + huge).write(toFile: (root as NSString).appendingPathComponent("huge-new.txt"), atomically: true, encoding: .utf8)
        let service = GitRepositoryService()
        let key = try #require(try await service.resolveRepository(directory: root))
        let snapshot = try await service.loadCatalog(for: key, generation: 1)
        let selection = CommitPlanner.selection(from: snapshot.files)
        let material = try await service.commitMaterial(for: key, paths: selection.paths, untrackedPaths: selection.untrackedPaths)
        #expect(material.diff.contains("diff --git a/staged.txt b/staged.txt\n[large change not shown]"))
        #expect(material.diff.contains("first line of the new file"))
        #expect(material.diff.contains("[rest of file not shown]"))
        #expect(material.diff.contains("unstaged"))
        #expect(material.diff.count < 200_000)
    }

    @Test func instructionEchoesAreRejectedAndRecovered() {
        for echo in ["at most 72 characters", "At most 72 chars", "One specific git commit subject", "No trailing period", "The commit subject line"] {
            #expect(CommitMessage.isInstructionEcho(echo), "\(echo)")
            #expect(CommitMessage.isWeak(echo), "\(echo)")
            #expect(!CommitMessage.isSafeToShow(partialSubject: echo + " and some more words"), "\(echo)")
        }
        // Real subjects that merely mention the words are fine.
        for real in ["Fix EQ gear gliding on Dynamic toggle", "Escape special characters in file paths", "Trim names to 72 characters"] {
            #expect(!CommitMessage.isInstructionEcho(real), "\(real)")
            #expect(!CommitMessage.isWeak(real), "\(real)")
        }
        // The real subject landed in the body: it becomes the subject.
        let fixed = CommitMessage.composed(
            subject: "at most 72 characters",
            detail: "Fix EQ gear gliding on Dynamic toggle: decouple icon fade from layout"
        )
        #expect(fixed == "Fix EQ gear gliding on Dynamic toggle: decouple icon fade from layout")
        let withBody = CommitMessage.composed(
            subject: "at most 72 characters",
            detail: "Fix EQ gear gliding\n\n- Decouple the icon fade from layout"
        )
        #expect(withBody == "Fix EQ gear gliding\n\n- Decouple the icon fade from layout")
        // Nothing to recover from.
        #expect(CommitMessage.composed(subject: "at most 72 characters", detail: "") == "")
    }

    @Test func fitLeavesASmallDiffAlone() {
        let diff = "diff --git a/a.txt b/a.txt\n+one\n"
        #expect(CommitDigest.fit(diff, budget: 5_000) == diff)
    }

    @Test func fitKeepsEveryFileAndStaysNearTheBudget() {
        func section(_ name: String, lines: Int) -> String {
            "diff --git a/\(name) b/\(name)\nnew file mode 100644\n" + String(repeating: "+code line\n", count: lines)
        }
        let diff = [
            section("huge.swift", lines: 2_000),
            section("small.swift", lines: 3),
            "new file notes.txt\n" + String(repeating: "note line\n", count: 600)
        ].joined(separator: "\n")
        let fitted = CommitDigest.fit(diff, budget: 1_500)
        #expect(fitted.count <= 1_500 + 200)
        #expect(fitted.contains("diff --git a/huge.swift"))
        #expect(fitted.contains("diff --git a/small.swift"))
        #expect(fitted.contains("new file notes.txt"))
        // The small file is whole; the large ones are cut and say so.
        #expect(fitted.contains("diff --git a/small.swift b/small.swift\nnew file mode 100644\n+code line\n+code line\n+code line"))
        #expect(fitted.contains("[truncated]"))
    }

    @Test func fitStaysBoundedWithHundredsOfFiles() {
        let diff = (0..<200).map { "diff --git a/f\($0).txt b/f\($0).txt\n" + String(repeating: "+x\n", count: 50) }
            .joined(separator: "\n")
        let fitted = CommitDigest.fit(diff, budget: 2_000)
        #expect(fitted.count <= 2_000 + 200)
        #expect(fitted.contains("diff --git a/f0.txt"))
        #expect(fitted.contains("more files not shown"))
    }

    @Test func promptCapsTheFileList() {
        let files = (0..<(CommitMessagePrompt.maxListedFiles + 5)).map { sample("file\($0).swift") }
        let body = CommitMessagePrompt.body(repository: "prestel", branch: "main", files: files, diff: "", recentSubjects: [])
        #expect(body.contains("and 5 more files"))
        #expect(!body.contains("file\(CommitMessagePrompt.maxListedFiles + 4).swift"))
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
        #expect(body.contains("Subject style: Plain sentence-case imperative"))
        #expect(!body.contains("feat:"))
        #expect(!body.contains("Add terminal tabs"))
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
        #expect(material.diff.contains("staged-both"))
        #expect(!material.diff.contains("unstaged-both"))
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
        let fitted = CommitDigest.fit(material.diff, budget: CommitMessageGenerator.evidenceCharacters)
        #expect(fitted.contains("change-00.txt"))
        #expect(fitted.contains("change-44.txt"))
        #expect(fitted.contains("new-large.txt"))
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

    @Test func stagedOnlyCommitLeavesUnstagedAndUntrackedFilesAlone() async throws {
        let root = try GitFixture.make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let service = GitRepositoryService()
        let key = try #require(try await service.resolveRepository(directory: root))
        let snapshot = try await service.loadCatalog(for: key, generation: 1)
        let selection = CommitPlanner.selection(from: snapshot.files, stagedOnly: true)
        #expect(selection.paths.sorted() == ["both.txt", "staged.txt"])
        #expect(selection.untrackedPaths.isEmpty)
        let material = try await service.commitMaterial(for: key, paths: selection.paths, untrackedPaths: selection.untrackedPaths, stagedOnly: true)
        #expect(material.diff.contains("staged-both"))
        #expect(!material.diff.contains("unstaged-both"))
        let outcome = try await service.commit(in: key, paths: selection.paths, message: "Commit staged only", push: false, stagedOnly: true)
        #expect(outcome == .committed)
        let status = try GitFixture.output(["status", "--porcelain"], in: root)
        let lines = status.split(separator: "\n").map(String.init)
        #expect(lines.contains(" M both.txt"))
        #expect(lines.contains(" M unstaged.txt"))
        #expect(lines.contains("?? untracked.txt"))
        #expect(!lines.contains { $0.hasSuffix(" staged.txt") })
    }

    @Test func mixedChangeDraftPreservesNewFileAndMatchesCommitScope() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prestel-mixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root.appendingPathComponent("Prestel/Review"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Prestel.xcodeproj"), withIntermediateDirectories: true)
        try GitFixture.run(["init", "-b", "main"], in: root.path)
        try GitFixture.run(["config", "user.name", "Prestel"], in: root.path)
        try GitFixture.run(["config", "user.email", "prestel@example.com"], in: root.path)
        try GitFixture.run(["config", "commit.gpgsign", "false"], in: root.path)

        let baseModel = """
        import Foundation

        final class CodeReviewModel {
            private var pendingStagingCount = 0
            private func enqueueIndexMutation(key: String) {
                pendingStagingCount += 1
                debounceTask?.cancel()
                Task {
                    self.pendingStagingCount = max(0, self.pendingStagingCount - 1)
                    guard self.activeKey == key else { return }
                    if failedError != nil {
                        self.evictCachedDiffs()
                        await self.reloadCatalog(for: key)
                    } else {
                        self.evictCachedDiffs()
                        if self.pendingStagingCount == 0 {
                            await self.reloadCatalog(for: key)
                        }
                    }
                }
            }

            private func reloadCatalog(for key: String) async {
                guard pendingStagingCount == 0 else { return }
            }
        }
        """
        let baseComposer = """
        import SwiftUI

        struct CommitDialog: View {
            var body: some View {
                VStack {
                    CommitActionPicker(selection: actionBinding, isDisabled: false)
                    commitButton
                }
            }

            private var commitButton: some View {
                Text("Commit")
                    .font(.system(size: 14, weight: .medium))
            }

            private var actionBinding: Binding<Int> {
                Binding(get: { 0 }, set: { model.updateCommitAction($0) })
            }
        }

        /// Capsule segmented control: a recessed track with a raised white thumb.
        private struct CommitActionPicker: View {
            @Binding var selection: Int
            var isDisabled: Bool
            var body: some View {
                HStack(spacing: 0) {
                    Text("Commit")
                }
            }
        }
        """
        let baseTable = """
        import SwiftUI

        struct ReviewFileHeaderRow: View {
            var body: some View {
                Button(action: {}) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
            }
        }
        """
        try baseModel.write(to: root.appendingPathComponent("Prestel/Review/CodeReviewModel.swift"), atomically: true, encoding: .utf8)
        try baseComposer.write(to: root.appendingPathComponent("Prestel/Review/CommitComposer.swift"), atomically: true, encoding: .utf8)
        try baseTable.write(to: root.appendingPathComponent("Prestel/Review/ReviewTableView.swift"), atomically: true, encoding: .utf8)
        try "// project\n".write(to: root.appendingPathComponent("Prestel.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        try GitFixture.run(["add", "."], in: root.path)
        try GitFixture.run(["commit", "-m", "Add per-file staging"], in: root.path)

        // Apply staging/review edits (unrelated to the commit action picker)
        let editedModel = """
        import Foundation

        final class CodeReviewModel {
            private var pendingStagingCount = 0
            private func enqueueIndexMutation(key: String) {
                pendingStagingCount += 1
                loadTask?.cancel()
                debounceTask?.cancel()
                Task {
                    guard self.activeKey == key else {
                        self.pendingStagingCount = max(0, self.pendingStagingCount - 1)
                        return
                    }
                    self.evictCachedDiffs()
                    if failedError != nil {
                        await self.reloadCatalog(for: key, expectedPending: self.pendingStagingCount)
                    } else if self.pendingStagingCount == 1 {
                        await self.reloadCatalog(for: key, expectedPending: 1)
                    }
                    self.pendingStagingCount = max(0, self.pendingStagingCount - 1)
                }
            }

            private func reloadCatalog(for key: String, expectedPending: Int) async {
                guard pendingStagingCount == expectedPending else { return }
            }
        }
        """
        let editedTable = """
        import SwiftUI

        struct ReviewFileHeaderRow: View {
            var body: some View {
                Button(action: {}) {
                    Image(systemName: "chevron.right")
                        .contentTransition(.identity)
                }
                .buttonStyle(ReviewHeaderIconButtonStyle(isHovered: false))
            }
        }

        private struct ReviewHeaderIconButtonStyle: ButtonStyle {
            var isHovered: Bool
            func makeBody(configuration: Configuration) -> some View {
                configuration.label
            }
        }
        """

        // Apply Lume-style commit action picker changes (new ~250-line file + composer edit)
        let paddingLines = (0..<170).map { "    private var segmentMetric\($0): CGFloat { CGFloat(\($0)) }" }.joined(separator: "\n")
        let pickerFile = """
        import AppKit
        import QuartzCore
        import SwiftUI

        struct CommitActionPicker: NSViewRepresentable {
            @Binding var selection: Int
            var isDisabled: Bool

            func makeNSView(context: Context) -> CommitActionPickerView {
                CommitActionPickerView(selection: selection)
            }

            func updateNSView(_ view: CommitActionPickerView, context: Context) {
                view.update(selection: selection)
            }
        }

        final class CommitActionPickerView: NSView {
            static let height: CGFloat = 36
            private let track = CALayer()
            private let pill = CALayer()
            private var position: CGFloat = 0.5
            private var target: CGFloat = 0.5
            private var velocity: CGFloat = 0
        \(paddingLines)

            init(selection: Int) {
                super.init(frame: .zero)
            }

            override func mouseDown(with event: NSEvent) {
                target = 1.5
            }

            override func mouseDragged(with event: NSEvent) {
                target = 2.5
                startMotion()
            }

            override func mouseUp(with event: NSEvent) {
                choose(Int(target))
            }

            private func placePill() {
                let stretch = min(0.45, abs(velocity) * 0.035)
                pill.frame = CGRect(x: position * 100, y: 3, width: 100 * (1 + stretch), height: 30)
            }

            private func startMotion() {
                let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in }
                RunLoop.main.add(timer, forMode: .common)
            }

            private func step() {
                // Lume's damped spring retains velocity when the pointer retargets it.
                let stiffness: CGFloat = 420
                let damping = 2 * 0.72 * stiffness.squareRoot()
                velocity += (stiffness * (target - position) - damping * velocity) * (1.0 / 120.0)
                position += velocity * (1.0 / 120.0)
                placePill()
            }
        }
        """
        let editedComposer = """
        import SwiftUI

        struct CommitDialog: View {
            var body: some View {
                VStack {
                    CommitActionPicker(selection: actionBinding, isDisabled: false)
                        .pointerStyle(.default)
                    commitButton
                }
            }

            private var commitButton: some View {
                Text("Commit")
                    .font(.system(size: 14, weight: .medium))
                    .contentTransition(.identity)
            }

            private var actionBinding: Binding<Int> {
                Binding(get: { 0 }, set: { action in
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { model.updateCommitAction(action) }
                })
            }
        }
        """

        try editedModel.write(to: root.appendingPathComponent("Prestel/Review/CodeReviewModel.swift"), atomically: true, encoding: .utf8)
        try editedTable.write(to: root.appendingPathComponent("Prestel/Review/ReviewTableView.swift"), atomically: true, encoding: .utf8)
        try pickerFile.write(to: root.appendingPathComponent("Prestel/Review/CommitActionPicker.swift"), atomically: true, encoding: .utf8)
        try editedComposer.write(to: root.appendingPathComponent("Prestel/Review/CommitComposer.swift"), atomically: true, encoding: .utf8)
        try "// project + picker\n".write(to: root.appendingPathComponent("Prestel.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)

        let service = GitRepositoryService()
        let key = try #require(try await service.resolveRepository(directory: root.path))

        // Case 1: Mixed working tree (nothing staged, stagedOnly = false) must include both changes
        // and preserve bottom-of-file picker evidence + full modified hunk evidence.
        let mixedSnapshot = try await service.loadCatalog(for: key, generation: 1)
        let mixedSelection = CommitPlanner.selection(from: mixedSnapshot.files, stagedOnly: false)
        let mixedSelected = mixedSnapshot.files.filter { mixedSelection.paths.contains($0.identityPath.display) }
        let mixedFiles = mixedSelected.filter { !CommitDigest.isNoise($0.identityPath.display) }
        let mixedGenerated = mixedSelected.filter { CommitDigest.isNoise($0.identityPath.display) }
        let mixedMaterial = try await service.commitMaterial(
            for: key,
            paths: mixedSelection.paths.filter { !CommitDigest.isNoise($0) },
            untrackedPaths: mixedSelection.untrackedPaths.filter { !CommitDigest.isNoise($0) },
            stagedOnly: false
        )
        let mixedFitted = CommitDigest.fit(mixedMaterial.diff, budget: CommitMessageGenerator.evidenceCharacters)
        let mixedBody = CommitMessagePrompt.body(
            repository: key.basename,
            branch: "main",
            files: mixedFiles,
            generated: mixedGenerated,
            diff: mixedFitted,
            recentSubjects: mixedMaterial.recentSubjects,
            stagedOnly: false
        )

        #expect(mixedBody.contains("Added Prestel/Review/CommitActionPicker.swift"))
        #expect(mixedBody.contains("Modified Prestel/Review/CodeReviewModel.swift"))
        #expect(mixedBody.contains("Modified Prestel/Review/CommitComposer.swift"))
        #expect(mixedBody.contains("Modified Prestel/Review/ReviewTableView.swift"))
        #expect(mixedBody.contains("Prestel.xcodeproj/ - 1 file"))
        #expect(mixedFitted.contains("mouseDragged"))
        #expect(mixedFitted.contains("placePill"))
        #expect(mixedFitted.contains("stretch"))
        #expect(mixedFitted.contains("Lume's damped spring"))
        #expect(mixedFitted.contains("enqueueIndexMutation"))
        #expect(mixedFitted.contains("expectedPending"))
        #expect(mixedFitted.contains("pendingStagingCount == 1"))
        #expect(mixedFitted.contains("-private struct CommitActionPicker: View"))
        #expect(mixedFitted.contains("ReviewHeaderIconButtonStyle"))

        // Case 2: Stage only picker changes (stagedOnly = true) must include picker evidence
        // and contain zero references to unstaged staging or review-table internals.
        try GitFixture.run(["add", "Prestel/Review/CommitActionPicker.swift", "Prestel/Review/CommitComposer.swift", "Prestel.xcodeproj/project.pbxproj"], in: root.path)
        let stagedSnapshot = try await service.loadCatalog(for: key, generation: 2)
        let stagedSelection = CommitPlanner.selection(from: stagedSnapshot.files, stagedOnly: true)
        #expect(stagedSelection.paths.sorted() == [
            "Prestel.xcodeproj/project.pbxproj",
            "Prestel/Review/CommitActionPicker.swift",
            "Prestel/Review/CommitComposer.swift"
        ])
        let stagedSelected = stagedSnapshot.files.filter { stagedSelection.paths.contains($0.identityPath.display) }
        let stagedFiles = stagedSelected.filter { !CommitDigest.isNoise($0.identityPath.display) }
        let stagedGenerated = stagedSelected.filter { CommitDigest.isNoise($0.identityPath.display) }
        let stagedMaterial = try await service.commitMaterial(
            for: key,
            paths: stagedSelection.paths.filter { !CommitDigest.isNoise($0) },
            untrackedPaths: stagedSelection.untrackedPaths.filter { !CommitDigest.isNoise($0) },
            stagedOnly: true
        )
        let stagedFitted = CommitDigest.fit(stagedMaterial.diff, budget: CommitMessageGenerator.evidenceCharacters)
        let stagedBody = CommitMessagePrompt.body(
            repository: key.basename,
            branch: "main",
            files: stagedFiles,
            generated: stagedGenerated,
            diff: stagedFitted,
            recentSubjects: stagedMaterial.recentSubjects,
            stagedOnly: true
        )

        #expect(stagedBody.contains("Added Prestel/Review/CommitActionPicker.swift"))
        #expect(stagedBody.contains("Modified Prestel/Review/CommitComposer.swift"))
        #expect(stagedFitted.contains("mouseDragged"))
        #expect(stagedFitted.contains("placePill"))
        #expect(stagedFitted.contains("stretch"))
        #expect(stagedFitted.contains("Lume's damped spring"))
        #expect(stagedFitted.contains("-private struct CommitActionPicker: View"))
        #expect(!stagedBody.contains("CodeReviewModel"))
        #expect(!stagedBody.contains("pendingStagingCount"))
        #expect(!stagedBody.contains("enqueueIndexMutation"))
        #expect(!stagedBody.contains("ReviewTableView"))
    }

    @Test func missingDiffEvidenceOmitsRecentSubjectsAndRequestsNoBullets() {
        #expect(!CommitDigest.hasMeaningfulDiff(""))
        #expect(!CommitDigest.hasMeaningfulDiff("diff --git a/Big.swift b/Big.swift\n[large change not shown]"))
        #expect(!CommitDigest.hasMeaningfulDiff("new file Big.bin\n[binary file]"))
        #expect(CommitDigest.hasMeaningfulDiff("+let x = 1"))
        #expect(CommitDigest.hasMeaningfulDiff("new file notes.txt\nhello"))

        let stub = "diff --git a/Big.swift b/Big.swift\n[large change not shown]"
        let body = CommitMessagePrompt.body(
            repository: "prestel",
            branch: "main",
            files: [sample("Big.swift", kind: .added, lanes: [.staged], additions: 500, deletions: 0)],
            diff: stub,
            recentSubjects: ["Add per-file staging"]
        )
        #expect(body.contains("Subject style:"))
        #expect(!body.contains("Add per-file staging"))
        #expect(body.contains("No code diff is available. State only what the file list shows and leave bullets empty."))
    }

    @Test func styleGuidanceInfersRepoConventionWithoutLeakingTopics() {
        let sentenceSubjects = [
            "Add per-file staging",
            "Match Lume’s commit tab animation in Prestel"
        ]
        #expect(CommitMessagePrompt.subjectStyle(from: sentenceSubjects) == .sentenceCase)
        let sentence = CommitMessagePrompt.styleGuidance(from: sentenceSubjects)
        #expect(sentence.contains("Plain sentence-case imperative"))
        #expect(sentence.contains("no prefix or colon"))
        #expect(!sentence.contains("feat:"))
        #expect(!sentence.contains("fix:"))
        #expect(!sentence.contains("refactor:"))
        #expect(!sentence.contains("chore:"))
        #expect(!sentence.contains("staging"))
        #expect(!sentence.contains("Lume"))

        let lowercaseSubjects = [
            "fix parser edge case",
            "add retry guard"
        ]
        #expect(CommitMessagePrompt.subjectStyle(from: lowercaseSubjects) == .lowercase)
        let lowercase = CommitMessagePrompt.styleGuidance(from: lowercaseSubjects)
        #expect(lowercase.contains("Plain lowercase imperative"))
        #expect(lowercase.contains("no prefix or colon"))
        #expect(!lowercase.contains("feat:"))
        #expect(!lowercase.contains("refactor:"))

        let conventionalSubjects = [
            "feat(review): add staging",
            "fix: handle empty diff"
        ]
        #expect(CommitMessagePrompt.subjectStyle(from: conventionalSubjects) == .conventional)
        let conventional = CommitMessagePrompt.styleGuidance(from: conventionalSubjects)
        #expect(conventional.contains("Conventional commit format"))
    }

    @Test func subjectCleanupStripsUnwantedConventionalPrefixAndDanglingConnectors() {
        #expect(
            CommitMessage.subject(from: "feat(review): implement staged-only diff formatting", style: .sentenceCase)
                == "Implement staged-only diff formatting"
        )
        #expect(
            CommitMessage.subject(from: "refactor!: simplify staging queue", style: .lowercase)
                == "simplify staging queue"
        )
        #expect(
            CommitMessage.subject(from: "feat: iOS keychain sync", style: .sentenceCase)
                == "iOS keychain sync"
        )
        #expect(
            CommitMessage.subject(from: "feat(review): implement staged-only diff formatting", style: .conventional)
                == "feat(review): implement staged-only diff formatting"
        )
        #expect(
            CommitMessage.subject(from: "Fix EQ gear gliding on Dynamic toggle: decouple icon fade", style: .sentenceCase)
                == "Fix EQ gear gliding on Dynamic toggle: decouple icon fade"
        )
        #expect(
            CommitMessage.subject(from: "Review: Improve staging logic and UI styling", style: .sentenceCase)
                == "Improve staging logic and UI styling"
        )
        #expect(
            CommitMessage.subject(from: "Review: Improve staging logic and UI styling", style: .conventional)
                == "Review: Improve staging logic and UI styling"
        )
        #expect(
            CommitMessage.subject(from: "Review: Improve staging logic and UI styling")
                == "Review: Improve staging logic and UI styling"
        )
        #expect(
            CommitMessage.subject(from: "Review: ok", style: .sentenceCase)
                == "Review: ok"
        )

        let danglingAnd = CommitMessage.subject(
            from: "Implement staged-only commit message formatting and diff trimming for very long working trees"
        )
        #expect(danglingAnd.count <= CommitMessage.maxSubjectLength)
        #expect(!danglingAnd.hasSuffix(" and"))
        #expect(!danglingAnd.hasSuffix(" for"))
        #expect(!danglingAnd.hasSuffix(" of"))
        #expect(!danglingAnd.hasSuffix(" with"))
        #expect(!danglingAnd.hasSuffix(" or"))

        let danglingOf = CommitMessage.subject(
            from: "Implement staged-only commit message formatting and handling of long repository diffs"
        )
        #expect(danglingOf.count <= CommitMessage.maxSubjectLength)
        #expect(!danglingOf.hasSuffix(" of"))
        #expect(!danglingOf.hasSuffix(" and"))
    }

    @Test func trimmedModifiedDiffNeverEmitsEmptyHunkHeadersAndDeweightsTests() {
        func hunk(_ line: Int, _ ctx: String, body: [String]) -> String {
            (["@@ -\(line),2 +\(line),\(body.count + 2) @@ \(ctx)"] + body).joined(separator: "\n")
        }

        let smallProdA = (["diff --git a/Prestel/Review/GitRepositoryService.swift b/Prestel/Review/GitRepositoryService.swift"]
            + (1...6).map { idx in
                hunk(idx * 20, "private func helper\(idx)() {", body: [
                    "-        let old\(idx) = 0",
                    "+        let new\(idx) = \(idx)"
                ])
            }).joined(separator: "\n")

        let smallProdB = (["diff --git a/Prestel/Review/CommitMessageGenerator.swift b/Prestel/Review/CommitMessageGenerator.swift"]
            + (1...5).map { idx in
                hunk(idx * 15, "static func step\(idx)() {", body: [
                    "-        return oldStep\(idx)()",
                    "+        return newStep\(idx)()"
                ])
            }).joined(separator: "\n")

        let addedProdLines = (1...30).flatMap { idx in
            [
                "+    private static func extractedHelper\(idx)() -> Int {",
                "+        let value = \(idx) * 2",
                "+        let adjusted = value + 1",
                "+        return adjusted",
                "+    }"
            ]
        }
        let largeProd = (["diff --git a/Prestel/Review/CommitPlanner.swift b/Prestel/Review/CommitPlanner.swift"]
            + [hunk(120, "enum CommitDigest {", body: ["-        let legacy = true"] + addedProdLines)]).joined(separator: "\n")

        let largeTest = #"""
        diff --git a/PrestelTests/CommitTests.swift b/PrestelTests/CommitTests.swift
        @@ -350,2 +350,120 @@ struct CommitTests {
        +    @Test func verifyFixtureParsing() {
        +        let fixture = """
        +        struct FakePicker {
        +            func decoyMethod() {}
        +        }
        +        """
        +        let lines = Array(repeating: "+        let padding = 1", count: 80).joined(separator: "\n")
        +        #expect(!fixture.isEmpty && !lines.isEmpty)
        +    }
        """#

        let combined = [smallProdA, smallProdB, largeProd, largeTest].joined(separator: "\n")
        let fitted = CommitDigest.fit(combined, budget: 2_500)

        let fittedLines = fitted.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in fittedLines.indices where fittedLines[index] == "@@" || fittedLines[index].hasPrefix("@@ ") {
            #expect(index + 1 < fittedLines.count, "Hunk header at end of diff with no body: \(fittedLines[index])")
            let next = fittedLines[index + 1]
            #expect(next.hasPrefix("+") || next.hasPrefix("-"), "Empty hunk header \(fittedLines[index]) followed by \(next)")
        }

        #expect(fitted.contains("let new1 = 1") || fitted.contains("let new2 = 2") || fitted.contains("let new3 = 3"))
        #expect(fitted.contains("return newStep1()") || fitted.contains("return newStep2()"))
        #expect(fitted.contains("@Test func verifyFixtureParsing()"))
        #expect(!fitted.contains("struct FakePicker"))
    }

    @Test func bulletsCompositionStripsDuplicateMarkersAndBackticks() {
        let composed = CommitMessage.composed(
            subject: "Add spring-animated commit action picker.",
            bullets: [
                "- Added `CommitActionPicker` with spring motion",
                "• Updated `CommitComposer` button transitions",
                "   "
            ]
        )
        #expect(composed == "Add spring-animated commit action picker\n\n- Added CommitActionPicker with spring motion\n- Updated CommitComposer button transitions")

        let recovered = CommitMessage.composed(
            subject: "The commit subject line",
            bullets: [
                "- Add spring-animated commit action picker",
                "- Update CommitComposer transitions"
            ]
        )
        #expect(recovered == "Add spring-animated commit action picker\n\n- Update CommitComposer transitions")
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

    @Test func composerDefaultsToStagedOnlyWhenStagedFilesExist() async {
        let service = RecordingCommitService(
            pushFailure: nil,
            files: [
                sample("Staged.swift", lanes: [.staged], additions: 4, deletions: 1),
                sample("Unstaged.swift", lanes: [.unstaged], additions: 2, deletions: 0)
            ]
        )
        let model = CodeReviewModel(service: service, watcher: CommitNullWatcher(), expandByDefault: false)
        let session = TerminalSession(descriptor: TabDescriptor(directory: "/tmp/repo-b"))
        model.bind(visible: true, windowID: UUID(), session: session)
        await waitUntil { model.loadState == .ready }
        model.openCommitComposer()
        #expect(model.effectiveCommitStagedOnly == true)
        model.updateCommitMessage("Stage only")
        model.commitFromComposer()
        await waitUntil { await service.recorded() != nil }
        let recorded = await service.recorded()
        #expect(recorded?.paths == ["Staged.swift"])
        #expect(recorded?.stagedOnly == true)
    }

    @Test func draftWaitsForInFlightStagingBeforeReadingCommitMaterial() async throws {
        let service = GatedStagingCommitService()
        let model = CodeReviewModel(service: service, watcher: CommitNullWatcher(), expandByDefault: false)
        let session = TerminalSession(descriptor: TabDescriptor(directory: "/tmp/repo-b"))
        model.bind(visible: true, windowID: UUID(), session: session)
        await waitUntil { model.loadState == .ready }

        let target = try #require(model.snapshot?.files.first { $0.identityPath.display == "File.swift" })
        model.stageFile(target)
        model.openCommitComposer()
        model.draftCommitName()

        try? await Task.sleep(for: .milliseconds(40))
        #expect(await service.recordedMaterial() == nil)

        await service.releaseStaging()
        await waitUntil { await service.recordedMaterial() != nil }
        let recorded = await service.recordedMaterial()
        #expect(recorded?.paths == ["File.swift"])
        #expect(recorded?.untrackedPaths.isEmpty == true)
        #expect(recorded?.stagedOnly == true)
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
    private let files: [ChangedFile]
    private var recordedCommit: (paths: [String], message: String, push: Bool, stagedOnly: Bool)?

    init(pushFailure: String?, files: [ChangedFile] = [sample("IOStrip.cpp", additions: 62, deletions: 11)]) {
        self.pushFailure = pushFailure
        self.files = files
    }

    func recorded() -> (paths: [String], message: String, push: Bool, stagedOnly: Bool)? {
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
            files: files,
            additions: files.reduce(0) { $0 + $1.additions },
            deletions: files.reduce(0) { $0 + $1.deletions },
            isComplete: true,
            isClean: files.isEmpty,
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

    func commit(in key: RepositoryKey, paths: [String], message: String, push: Bool, stagedOnly: Bool) async throws -> CommitOutcome {
        recordedCommit = (paths, message, push, stagedOnly)
        if push, let pushFailure {
            return .committedPushFailed(pushFailure)
        }
        return .committed
    }
}

private actor GatedStagingCommitService: GitReviewServicing {
    private var stagingReleased = false
    private var files: [ChangedFile] = [
        sample("File.swift", lanes: [.unstaged], additions: 5, deletions: 1),
        sample("Other.swift", lanes: [.unstaged], additions: 3, deletions: 0)
    ]
    private var materialCall: (paths: [String], untrackedPaths: [String], stagedOnly: Bool)?

    func releaseStaging() {
        stagingReleased = true
    }

    func recordedMaterial() -> (paths: [String], untrackedPaths: [String], stagedOnly: Bool)? {
        materialCall
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
            files: files,
            additions: files.reduce(0) { $0 + $1.additions },
            deletions: files.reduce(0) { $0 + $1.deletions },
            isComplete: true,
            isClean: files.isEmpty,
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

    func stage(in key: RepositoryKey, paths: [String]) async throws {
        while !stagingReleased {
            try await Task.sleep(for: .milliseconds(10))
        }
        let stagedSet = Set(paths)
        files = files.map { file in
            stagedSet.contains(file.identityPath.display) ? file.optimisticallyStaged() : file
        }
    }

    func commitMaterial(for key: RepositoryKey, paths: [String], untrackedPaths: [String], stagedOnly: Bool) async throws -> CommitMaterial {
        materialCall = (paths, untrackedPaths, stagedOnly)
        throw CommitNameError.declined
    }
}

private final class CommitNullWatcher: RepositoryWatching, @unchecked Sendable {
    func events(for key: RepositoryKey) -> AsyncStream<RepositoryInvalidation> {
        AsyncStream { $0.finish() }
    }
    func stop(_ key: RepositoryKey) {}
    func stopAll() {}
}
