import Foundation
import Testing
@testable import Prestel

@Suite
@MainActor
struct CodeReviewModelTests {
    @Test func missingReviewKeysDefaultClosedAndPreferredWidth() throws {
        let old = WindowDescriptor(
            id: UUID(),
            tabs: [TabDescriptor(directory: FileManager.default.homeDirectoryForCurrentUser.path)],
            selectedID: nil,
            sidebarVisible: true,
            sidebarWidth: 172
        )
        var payload = try JSONEncoder().encode(old)
        var json = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        json.removeValue(forKey: "reviewVisible")
        json.removeValue(forKey: "reviewWidth")
        payload = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(WindowDescriptor.self, from: payload)
        #expect(decoded.reviewVisible == false)
        #expect(decoded.reviewWidth == 420)
    }

    @Test func invalidReviewWidthFallsBackAndClamps() throws {
        #expect(WindowDescriptor.clampedReviewWidth(.nan) == 420)
        #expect(WindowDescriptor.clampedReviewWidth(.infinity) == 420)
        #expect(WindowDescriptor.clampedReviewWidth(10) == 256)
        #expect(WindowDescriptor.clampedReviewWidth(900) == 720)
        let restored = TerminalModel(
            restoration: WindowDescriptor(
                id: UUID(),
                tabs: [TabDescriptor()],
                selectedID: nil,
                sidebarVisible: true,
                sidebarWidth: 172,
                reviewVisible: true,
                reviewWidth: 900
            )
        )
        #expect(restored.reviewVisible)
        #expect(restored.reviewWidth == 720)
    }

    @Test func adoptingWindowStartsWithReviewClosed() {
        let source = TerminalModel()
        let tab = source.tabs[0]
        _ = source.detachTab(tab.id)
        let adopted = TerminalModel(adopting: tab)
        #expect(!adopted.reviewVisible)
        #expect(adopted.reviewWidth == 420)
    }

    @Test func lateResultFromPreviousRepositoryIsRejected() async {
        let runner = GatedReviewService()
        let model = CodeReviewModel(service: runner, watcher: NullWatcher(), expandByDefault: false)
        let sessionA = TerminalSession(descriptor: TabDescriptor(directory: "/tmp/repo-a"))
        let sessionB = TerminalSession(descriptor: TabDescriptor(directory: "/tmp/repo-b"))
        model.bind(visible: true, windowID: UUID(), session: sessionA)
        try? await Task.sleep(for: .milliseconds(30))
        model.bind(visible: true, windowID: UUID(), session: sessionB)
        await runner.release("a")
        try? await Task.sleep(for: .milliseconds(50))
        await runner.release("b")
        await waitUntilReady(model)
        #expect(model.snapshot?.revision.key.basename == "repo-b")
        #expect(model.loadState == .ready)
    }

    @Test func closingReviewKeepsSnapshotForReopen() async {
        let runner = GatedReviewService()
        let model = CodeReviewModel(service: runner, watcher: NullWatcher(), expandByDefault: false)
        let session = TerminalSession(descriptor: TabDescriptor(directory: "/tmp/repo-b"))
        await runner.release("b")
        model.bind(visible: true, windowID: UUID(), session: session)
        await waitUntilReady(model)
        model.bind(visible: false, windowID: UUID(), session: session)
        #expect(model.loadState == .hidden)
        #expect(model.snapshot?.revision.key.basename == "repo-b")
        model.bind(visible: true, windowID: UUID(), session: session)
        #expect(model.loadState == .ready)
        #expect(model.snapshot?.revision.key.basename == "repo-b")
    }

    @Test func rebindingVisibleSessionDoesNotCancelInFlightLoad() async {
        let runner = GatedReviewService()
        let model = CodeReviewModel(service: runner, watcher: NullWatcher(), expandByDefault: false)
        let session = TerminalSession(descriptor: TabDescriptor(directory: "/tmp/repo-b"))
        model.bind(visible: true, windowID: UUID(), session: session)
        model.bind(visible: true, windowID: UUID(), session: session)
        model.bind(visible: true, windowID: UUID(), session: session)
        await runner.release("b")
        await waitUntilReady(model)
        #expect(model.loadState == .ready)
        #expect(model.snapshot?.revision.key.basename == "repo-b")
    }

    @Test func bindFromPanelOpenAnimationReachesReadyWithoutAnotherTab() async {
        let runner = GatedReviewService()
        let model = CodeReviewModel(service: runner, watcher: NullWatcher(), expandByDefault: false)
        let session = TerminalSession(descriptor: TabDescriptor(directory: "/tmp/repo-b"))
        await runner.release("b")
        ShellPanelAnimation.run {
            model.bind(visible: true, windowID: UUID(), session: session)
        }
        await waitUntilReady(model)
        #expect(model.loadState == .ready)
        #expect(model.snapshot?.revision.key.basename == "repo-b")
    }

    @Test func cancelledFirstLoadRetriesOnTheSameTab() async {
        let runner = GatedReviewService()
        let model = CodeReviewModel(service: runner, watcher: NullWatcher(), expandByDefault: false)
        let session = TerminalSession(descriptor: TabDescriptor(directory: "/tmp/repo-b"))
        model.bind(visible: true, windowID: UUID(), session: session)
        try? await Task.sleep(for: .milliseconds(20))
        model.bind(visible: false, windowID: UUID(), session: session)
        await runner.release("b")
        model.bind(visible: true, windowID: UUID(), session: session)
        await waitUntilReady(model)
        #expect(model.loadState == .ready)
        #expect(model.snapshot?.revision.key.basename == "repo-b")
    }

    @Test func stageAndUnstageFlipFileImmediatelyBeforeGitFinishes() async throws {
        let root = try GitFixture.make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = CodeReviewModel(service: GitRepositoryService(), watcher: NullWatcher(), expandByDefault: false)
        let session = TerminalSession(descriptor: TabDescriptor(directory: root))
        model.bind(visible: true, windowID: UUID(), session: session)
        await waitUntilReady(model)

        let untracked = try #require(model.snapshot?.files.first { $0.identityPath.display == "untracked.txt" })
        #expect(untracked.canStage)
        #expect(!untracked.isStaged)

        // Optimistic flip happens synchronously on click — before git add finishes.
        model.stageFile(untracked)
        let optimisticStaged = try #require(model.snapshot?.files.first { $0.identityPath.display == "untracked.txt" })
        #expect(optimisticStaged.isStaged)
        #expect(!optimisticStaged.canStage)
        #expect(optimisticStaged.canUnstage)
        #expect(optimisticStaged.additions == 1)

        // Immediate unstage flips right back synchronously and serializes after git add.
        model.unstageFile(optimisticStaged)
        let optimisticUnstaged = try #require(model.snapshot?.files.first { $0.identityPath.display == "untracked.txt" })
        #expect(!optimisticUnstaged.isStaged)
        #expect(optimisticUnstaged.canStage)
        #expect(optimisticUnstaged.kind == .untracked)

        // Let the queued git commands and catalog reconcile settle.
        try? await Task.sleep(for: .milliseconds(400))
        let settled = try #require(model.snapshot?.files.first { $0.identityPath.display == "untracked.txt" })
        #expect(!settled.isStaged)
        #expect(settled.kind == .untracked)
    }
}

/// The catalog load yields once before it publishes, so a fixed sleep can
/// return while the state is still `.resolving` or `.loading`. A busy suite
/// made 80ms too short. This follows `loadState` instead.
@MainActor
private func waitUntilReady(_ model: CodeReviewModel) async {
    let deadline = ContinuousClock().now.advanced(by: .seconds(15))
    while model.loadState != .ready {
        switch model.loadState {
        case .resolving, .loading, .waitingForGit, .hidden:
            if ContinuousClock().now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        default:
            return
        }
    }
}

private actor GatedReviewService: GitReviewServicing {
    private var released: Set<String> = []

    func release(_ token: String) {
        released.insert(token)
    }

    func resolveRepository(directory: String) async throws -> RepositoryKey? {
        let token = directory.hasSuffix("repo-a") ? "a" : "b"
        while !released.contains(token) {
            try await Task.sleep(for: .milliseconds(10))
            try Task.checkCancellation()
        }
        let name = token == "a" ? "repo-a" : "repo-b"
        return RepositoryKey(worktreeRoot: "/tmp/\(name)", gitDirectory: "/tmp/\(name)/.git", commonGitDirectory: "/tmp/\(name)/.git")
    }

    func loadCatalog(for key: RepositoryKey, generation: UInt64) async throws -> ReviewSnapshot {
        let name = key.basename
        return ReviewSnapshot(
            revision: RepositoryRevision(
                key: key,
                headOID: "abc",
                branchName: "main",
                isDetached: false,
                isUnborn: false,
                indexFingerprint: "1",
                generation: generation
            ),
            files: [],
            additions: 0,
            deletions: 0,
            isComplete: true,
            isClean: true,
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
}

private final class NullWatcher: RepositoryWatching, @unchecked Sendable {
    func events(for key: RepositoryKey) -> AsyncStream<RepositoryInvalidation> {
        AsyncStream { $0.finish() }
    }
    func stop(_ key: RepositoryKey) {}
    func stopAll() {}
}
