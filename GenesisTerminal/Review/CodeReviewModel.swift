import AppKit
import Combine
import Foundation

@MainActor
final class CodeReviewModel: ObservableObject {
    @Published private(set) var loadState: ReviewLoadState = .hidden
    @Published private(set) var snapshot: ReviewSnapshot?
    @Published private(set) var diffs: [String: FileDiff] = [:]
    @Published private(set) var highlights: [String: HighlightedSource] = [:]
    @Published var presentation = ReviewPresentationState()
    @Published var diagnostic: String?
    @Published var isRefreshing = false

    private let service: any GitReviewServicing
    private let watcher: any RepositoryWatching
    private let highlighter = ReviewSyntaxHighlighter()
    private var context: ReviewContext?
    private var contextGeneration: UInt64 = 0
    private var snapshotGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var safetyTask: Task<Void, Never>?
    private var presentationCache: [RepositoryKey: ReviewPresentationState] = [:]
    private var lastDirectory: String?
    private var lastSessionID: UUID?
    private var activeKey: RepositoryKey?
    private var expandByDefault: Bool
    private var appearanceGeneration: UInt64 = 0
    private var largeLoadIDs: Set<String> = []
    var onFocusReview: (() -> Void)?
    var onRestoreTerminalFocus: (() -> Void)?

    init(
        service: any GitReviewServicing = GitRepositoryService(),
        watcher: any RepositoryWatching = RepositoryWatcher(),
        expandByDefault: Bool = UserDefaults.standard.bool(forKey: "reviewExpandFilesByDefault")
    ) {
        self.service = service
        self.watcher = watcher
        self.expandByDefault = expandByDefault
    }

    var expandFilesByDefault: Bool {
        get { expandByDefault }
        set {
            expandByDefault = newValue
            UserDefaults.standard.set(newValue, forKey: "reviewExpandFilesByDefault")
        }
    }

    var showWhitespace = false

    func bind(visible: Bool, windowID: UUID, session: TerminalSession?) {
        guard visible else {
            hide()
            return
        }
        guard let session, session.kind == .terminal else {
            clearWork()
            loadState = .noTerminal
            snapshot = nil
            return
        }
        let directory = URL(fileURLWithPath: session.directory).standardizedFileURL.path
        guard !directory.isEmpty else { return }
        let sameContext = lastSessionID == session.id && lastDirectory == directory
        if sameContext {
            switch loadState {
            case .resolving, .loading, .ready, .waitingForGit:
                return
            case .hidden, .noTerminal, .noRepository, .noWorkingTree, .unavailable, .error:
                break
            }
        }
        lastSessionID = session.id
        lastDirectory = directory
        if sameContext, snapshot != nil {
            loadState = .ready
            contextGeneration += 1
            let next = ReviewContext(windowID: windowID, sessionID: session.id, directory: directory, generation: contextGeneration)
            context = next
            loadTask?.cancel()
            loadTask = Task { [weak self] in
                await self?.resolve(next)
            }
            return
        }
        contextGeneration += 1
        let next = ReviewContext(windowID: windowID, sessionID: session.id, directory: directory, generation: contextGeneration)
        context = next
        if !sameContext {
            diffs = [:]
            highlights = [:]
            diagnostic = nil
            watcher.stopAll()
            activeKey = nil
        }
        loadState = .resolving
        loadTask?.cancel()
        watchTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.resolve(next)
        }
    }

    func refresh(userInitiated: Bool = true) {
        guard let context else { return }
        if userInitiated { isRefreshing = true }
        snapshotGeneration += 1
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.resolve(context)
        }
    }

    func toggleFile(_ fileID: String) {
        if presentation.expandedFileIDs.contains(fileID) {
            presentation.expandedFileIDs.remove(fileID)
            presentation.collapsedFileIDs.insert(fileID)
        } else {
            presentation.expandedFileIDs.insert(fileID)
            presentation.collapsedFileIDs.remove(fileID)
            loadBodies(for: fileID)
        }
    }

    func expandAll() {
        guard let snapshot else { return }
        presentation.collapsedFileIDs.removeAll()
        for file in visibleFiles(in: snapshot) where file.kind != .conflicted {
            if shouldKeepCollapsed(file) { continue }
            presentation.expandedFileIDs.insert(file.id)
            loadBodies(for: file.id)
        }
    }

    func collapseAll() {
        presentation.expandedFileIDs.removeAll()
        if let snapshot {
            presentation.collapsedFileIDs = Set(snapshot.files.map(\.id))
        }
    }

    func setFilter(_ filter: ReviewFilter) {
        presentation.filter = filter
    }

    func loadLargeDiff(fileID: String, comparison: FileComparisonKind) {
        largeLoadIDs.insert("\(fileID):\(comparison.rawValue)")
        loadBodies(for: fileID, forceLarge: true)
    }

    func revealContext(fileID: String, hunkIndex: Int) {
        var values = presentation.revealedContext[fileID] ?? []
        values.insert(hunkIndex)
        presentation.revealedContext[fileID] = values
    }

    func copyRepositoryPath() {
        guard let path = snapshot?.revision.key.worktreeRoot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func openFile(_ file: ChangedFile) {
        guard file.isLossless, file.kind != .deleted else {
            reveal(file)
            return
        }
        guard let root = snapshot?.revision.key.worktreeRoot else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: root).appendingPathComponent(file.identityPath.display))
    }

    func reveal(_ file: ChangedFile) {
        guard file.isLossless, let root = snapshot?.revision.key.worktreeRoot else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(file.identityPath.display)
        if file.kind == .deleted {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func copyPath(_ file: ChangedFile, absolute: Bool) {
        guard file.isLossless else { return }
        let value: String
        if absolute, let root = snapshot?.revision.key.worktreeRoot {
            value = URL(fileURLWithPath: root).appendingPathComponent(file.identityPath.display).path
        } else {
            value = file.identityPath.display
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func copyPatch(for file: ChangedFile) {
        let patches = file.comparisons.compactMap { comparison in
            diffs[reviewDiffKey(file.id, comparison.kind)]?.patchText
        }.filter { !$0.isEmpty }
        guard !patches.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(patches.joined(separator: "\n"), forType: .string)
    }

    func visibleFiles(in snapshot: ReviewSnapshot) -> [ChangedFile] {
        snapshot.files.filter { $0.matches(presentation.filter) }
    }

    func filteredTotals(in snapshot: ReviewSnapshot) -> (additions: Int, deletions: Int, count: Int) {
        let files = visibleFiles(in: snapshot)
        return (
            files.reduce(0) { $0 + $1.additions },
            files.reduce(0) { $0 + $1.deletions },
            files.count
        )
    }

    func updateAppearance(_ dark: Bool) {
        appearanceGeneration += 1
        highlights.removeAll()
        for (key, diff) in diffs {
            highlight(diff, key: key)
        }
    }

    func shutdown() {
        hide()
        watcher.stopAll()
    }

    private func hide() {
        loadTask?.cancel()
        watchTask?.cancel()
        debounceTask?.cancel()
        safetyTask?.cancel()
        watcher.stopAll()
        if let activeKey, snapshot != nil {
            presentationCache[activeKey] = presentation
            trimPresentationCache()
        }
        loadState = .hidden
        isRefreshing = false
    }

    private func clearWork() {
        loadTask?.cancel()
        watchTask?.cancel()
        debounceTask?.cancel()
        safetyTask?.cancel()
        watcher.stopAll()
        activeKey = nil
        context = nil
        lastDirectory = nil
        diffs = [:]
        highlights = [:]
        isRefreshing = false
    }

    private func resolve(_ context: ReviewContext) async {
        guard self.context?.generation == context.generation else { return }
        do {
            let key = try await service.resolveRepository(directory: context.directory)
            guard self.context?.generation == context.generation else { return }
            guard let key else {
                snapshot = nil
                loadState = .noRepository
                isRefreshing = false
                return
            }
            if activeKey != key {
                if let activeKey {
                    presentationCache[activeKey] = presentation
                    watcher.stop(activeKey)
                }
                presentation = presentationCache[key] ?? ReviewPresentationState()
                activeKey = key
                diffs = [:]
                highlights = [:]
            }
            loadState = snapshot == nil ? .loading : loadState
            snapshotGeneration += 1
            let generation = snapshotGeneration
            let loaded = try await service.loadCatalog(for: key, generation: generation)
            guard self.context?.generation == context.generation else { return }
            if loaded.waitingOnIndexLock {
                if snapshot == nil {
                    loadState = .waitingForGit
                }
            } else {
                snapshot = loaded
                loadState = .ready
                diagnostic = loaded.diagnostic
                applyDefaultExpansion(loaded)
                for fileID in presentation.expandedFileIDs {
                    loadBodies(for: fileID)
                }
            }
            isRefreshing = false
            startWatching(key)
            startSafetyRefresh()
        } catch GitReviewServiceError.bareRepository {
            guard self.context?.generation == context.generation else { return }
            snapshot = nil
            loadState = .noWorkingTree
            isRefreshing = false
        } catch GitRunnerError.gitUnavailable(let message) {
            guard self.context?.generation == context.generation else { return }
            snapshot = nil
            loadState = .unavailable(message)
            isRefreshing = false
        } catch GitRunnerError.cancelled {
            return
        } catch is CancellationError {
            return
        } catch {
            guard self.context?.generation == context.generation else { return }
            if snapshot == nil {
                loadState = .error(error.localizedDescription)
            } else {
                diagnostic = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    private func loadBodies(for fileID: String, forceLarge: Bool = false) {
        guard let snapshot, let file = snapshot.files.first(where: { $0.id == fileID }) else { return }
        let key = snapshot.revision.key
        let generation = snapshot.revision.generation
        let contextGeneration = context?.generation
        Task { [weak self] in
            guard let self else { return }
            for comparison in file.comparisons {
                let diffKey = reviewDiffKey(fileID, comparison.kind)
                if self.diffs[diffKey] != nil, !forceLarge { continue }
                do {
                    let diff = try await self.service.loadComparison(
                        for: key,
                        file: file,
                        comparison: comparison,
                        generation: generation,
                        loadLarge: forceLarge || self.largeLoadIDs.contains("\(fileID):\(comparison.kind.rawValue)")
                    )
                    guard self.context?.generation == contextGeneration else { return }
                    self.diffs[diffKey] = diff
                    self.highlight(diff, key: diffKey)
                } catch is CancellationError {
                    return
                } catch GitRunnerError.cancelled {
                    return
                } catch GitReviewServiceError.sourceMismatch {
                    self.refresh(userInitiated: false)
                    return
                } catch {
                    self.diagnostic = error.localizedDescription
                }
            }
        }
    }

    private func highlight(_ diff: FileDiff, key: String) {
        let generation = appearanceGeneration
        Task { [weak self] in
            guard let self else { return }
            if let old = diff.oldSource {
                let highlighted = await self.highlighter.highlight(
                    snapshot: old,
                    path: diff.fileID,
                    dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                    appearanceGeneration: generation
                )
                guard self.appearanceGeneration == generation else { return }
                if let highlighted {
                    self.highlights["old:\(key)"] = highlighted
                }
            }
            if let new = diff.newSource {
                let highlighted = await self.highlighter.highlight(
                    snapshot: new,
                    path: diff.fileID,
                    dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                    appearanceGeneration: generation
                )
                guard self.appearanceGeneration == generation else { return }
                if let highlighted {
                    self.highlights["new:\(key)"] = highlighted
                }
            }
        }
    }

    private func startWatching(_ key: RepositoryKey) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            guard let self else { return }
            let events = self.watcher.events(for: key)
            for await event in events {
                guard !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: RepositoryInvalidation) async {
        switch event {
        case .indexLockChanged(let locked):
            if locked {
                scheduleRefresh(delay: 0.2)
            } else {
                refresh(userInitiated: false)
            }
        case .metadata, .rescan:
            scheduleRefresh(delay: 0.5)
        case .files:
            scheduleRefresh(delay: 0.5)
        }
    }

    private func scheduleRefresh(delay: TimeInterval) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard !Task.isCancelled else { return }
            self?.refresh(userInitiated: false)
        }
    }

    private func startSafetyRefresh() {
        safetyTask?.cancel()
        safetyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: ReviewBudgets.safetyRefreshNanoseconds)
                guard !Task.isCancelled else { return }
                guard NSApp.isActive else { continue }
                self?.refresh(userInitiated: false)
            }
        }
    }

    private func applyDefaultExpansion(_ snapshot: ReviewSnapshot) {
        for file in snapshot.files {
            if presentation.collapsedFileIDs.contains(file.id) || presentation.expandedFileIDs.contains(file.id) {
                continue
            }
            if expandByDefault, !shouldKeepCollapsed(file) {
                presentation.expandedFileIDs.insert(file.id)
            }
        }
    }

    private func shouldKeepCollapsed(_ file: ChangedFile) -> Bool {
        file.hasBinaryComparison || file.kind == .submodule || file.additions + file.deletions > ReviewBudgets.automaticChangedLines
    }

    private func trimPresentationCache() {
        while presentationCache.count > ReviewBudgets.presentationCacheCount,
              let key = presentationCache.keys.first {
            presentationCache.removeValue(forKey: key)
        }
    }
}

private extension ChangedFile {
    var isLossless: Bool { identityPath.isLossless && (oldPath?.isLossless ?? true) }
}
