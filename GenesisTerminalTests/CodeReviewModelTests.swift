import Foundation
import Testing
@testable import GenesisTerminal

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
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.snapshot?.revision.key.basename == "repo-b")
        #expect(model.loadState == .ready)
    }

    @Test func closingReviewKeepsSnapshotForReopen() async {
        let runner = GatedReviewService()
        let model = CodeReviewModel(service: runner, watcher: NullWatcher(), expandByDefault: false)
        let session = TerminalSession(descriptor: TabDescriptor(directory: "/tmp/repo-b"))
        await runner.release("b")
        model.bind(visible: true, windowID: UUID(), session: session)
        try? await Task.sleep(for: .milliseconds(80))
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
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.loadState == .ready)
        #expect(model.snapshot?.revision.key.basename == "repo-b")
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
