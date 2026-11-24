import AppKit
import Combine
import Foundation
import SwiftUI

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
    private var stagingTask: Task<Void, Never>?
    private var stagingGeneration: UInt64 = 0
    private var pendingStagingCount = 0
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
    @Published var commitDraft: CommitDraft?
    private var commitGeneration = 0
    private var commitDraftTask: Task<Void, Never>?

    func bind(visible: Bool, windowID: UUID, session: TerminalSession?) {
        guard visible else {
            hide()
            return
        }
        guard let session, session.kind == .terminal else {
            clearWork()
            loadState = .noTerminal
            snapshot = nil
            if commitDraft?.isCommitting != true {
                commitDraftTask?.cancel()
                commitGeneration += 1
                commitDraft = nil
            }
            return
        }
        let directory = URL(fileURLWithPath: session.directory).standardizedFileURL.path
        guard !directory.isEmpty else { return }
        let sameContext = lastSessionID == session.id && lastDirectory == directory
        if sameContext {
            switch loadState {
            case .ready:
                return
            case .resolving, .loading, .waitingForGit:
                // A cancelled first-open load used to stay on .resolving forever
                // because later binds of the same tab returned here.
                if let loadTask, !loadTask.isCancelled { return }
            case .hidden, .noTerminal, .noRepository, .noWorkingTree, .unavailable, .error:
                break
            }
        }
        lastSessionID = session.id
        lastDirectory = directory
        if sameContext, snapshot != nil {
            publishWithoutAnimation { loadState = .ready }
            startLoad(
                ReviewContext(windowID: windowID, sessionID: session.id, directory: directory, generation: nextGeneration())
            )
            return
        }
        if !sameContext {
            diffs = [:]
            highlights = [:]
            diagnostic = nil
            watcher.stopAll()
            activeKey = nil
            if commitDraft?.isCommitting != true {
                commitDraftTask?.cancel()
                commitGeneration += 1
                commitDraft = nil
            }
        }
        publishWithoutAnimation { loadState = .resolving }
        watchTask?.cancel()
        startLoad(
            ReviewContext(windowID: windowID, sessionID: session.id, directory: directory, generation: nextGeneration())
        )
    }

    func refresh(userInitiated: Bool = true) {
        guard let context else { return }
        if userInitiated { isRefreshing = true }
        snapshotGeneration += 1
        startLoad(context)
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
        SafeFileOpener.open(URL(fileURLWithPath: root).appendingPathComponent(file.identityPath.display))
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

    var canStageAny: Bool {
        guard let snapshot, !snapshot.waitingOnIndexLock else { return false }
        return snapshot.files.contains(where: \.canStage)
    }

    var canUnstageAny: Bool {
        guard let snapshot, !snapshot.waitingOnIndexLock else { return false }
        return snapshot.files.contains(where: \.canUnstage)
    }

    func stageFile(_ file: ChangedFile) {
        guard file.canStage, let snapshot, !snapshot.waitingOnIndexLock else { return }
        let key = snapshot.revision.key
        let wasSingleLane = file.comparisons.count == 1
        let previousLane = file.comparisons.first?.kind
        applyOptimisticUpdate(for: [file.id: file.optimisticallyStaged()])
        if wasSingleLane, let previousLane {
            mirrorCachedDiff(fileID: file.id, from: previousLane, to: .staged)
        }
        enqueueIndexMutation(key: key, evictFileIDs: wasSingleLane ? [] : [file.id]) {
            try await self.service.stage(in: key, paths: [file.identityPath.display])
        }
    }

    func unstageFile(_ file: ChangedFile) {
        guard file.canUnstage, let snapshot, !snapshot.waitingOnIndexLock else { return }
        let key = snapshot.revision.key
        let isUnborn = snapshot.revision.isUnborn
        let wasSingleLane = file.comparisons.count == 1
        let next = file.optimisticallyUnstaged()
        applyOptimisticUpdate(for: [file.id: next])
        if wasSingleLane, let nextLane = next.comparisons.first?.kind {
            mirrorCachedDiff(fileID: file.id, from: .staged, to: nextLane)
        }
        enqueueIndexMutation(key: key, evictFileIDs: wasSingleLane ? [] : [file.id]) {
            try await self.service.unstage(in: key, paths: file.unstagePaths, isUnborn: isUnborn)
        }
    }

    func stageAll() {
        guard let snapshot, !snapshot.waitingOnIndexLock else { return }
        let targets = snapshot.files.filter(\.canStage)
        guard !targets.isEmpty else { return }
        let key = snapshot.revision.key
        let paths = targets.map(\.identityPath.display)
        var updates: [String: ChangedFile] = [:]
        var evictIDs: Set<String> = []
        for file in targets {
            updates[file.id] = file.optimisticallyStaged()
            if file.comparisons.count == 1, let prev = file.comparisons.first?.kind {
                mirrorCachedDiff(fileID: file.id, from: prev, to: .staged)
            } else {
                evictIDs.insert(file.id)
            }
        }
        applyOptimisticUpdate(for: updates)
        enqueueIndexMutation(key: key, evictFileIDs: evictIDs) {
            try await self.service.stage(in: key, paths: paths)
        }
    }

    func unstageAll() {
        guard let snapshot, !snapshot.waitingOnIndexLock else { return }
        let targets = snapshot.files.filter(\.canUnstage)
        guard !targets.isEmpty else { return }
        let key = snapshot.revision.key
        let paths = targets.flatMap(\.unstagePaths)
        let isUnborn = snapshot.revision.isUnborn
        var updates: [String: ChangedFile] = [:]
        var evictIDs: Set<String> = []
        for file in targets {
            let next = file.optimisticallyUnstaged()
            updates[file.id] = next
            if file.comparisons.count == 1, let nextLane = next.comparisons.first?.kind {
                mirrorCachedDiff(fileID: file.id, from: .staged, to: nextLane)
            } else {
                evictIDs.insert(file.id)
            }
        }
        applyOptimisticUpdate(for: updates)
        enqueueIndexMutation(key: key, evictFileIDs: evictIDs) {
            try await self.service.unstage(in: key, paths: paths, isUnborn: isUnborn)
        }
    }

    private func applyOptimisticUpdate(for updates: [String: ChangedFile]) {
        guard var current = snapshot, !updates.isEmpty else { return }
        current.files = current.files.map { updates[$0.id] ?? $0 }
        current.additions = current.files.reduce(0) { $0 + $1.additions }
        current.deletions = current.files.reduce(0) { $0 + $1.deletions }
        publishWithoutAnimation {
            snapshot = current
        }
    }

    /// Keeps an already-loaded expanded diff visible across a single-lane
    /// stage/unstage flip so the pane does not flash "Loading diff…".
    private func mirrorCachedDiff(fileID: String, from source: FileComparisonKind, to destination: FileComparisonKind) {
        let sourceKey = reviewDiffKey(fileID, source)
        let destKey = reviewDiffKey(fileID, destination)
        guard let diff = diffs[sourceKey] else { return }
        var copied = diff
        copied.comparison = destination
        diffs[destKey] = copied
        if let oldHL = highlights["old:\(sourceKey)"] {
            highlights["old:\(destKey)"] = oldHL
        }
        if let newHL = highlights["new:\(sourceKey)"] {
            highlights["new:\(destKey)"] = newHL
        }
    }

    /// Serializes git index mutations so rapid per-file clicks never race on
    /// `index.lock`, then reconciles once with a fast catalog reload.
    private func enqueueIndexMutation(
        key: RepositoryKey,
        evictFileIDs: Set<String>,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        diagnostic = nil
        pendingStagingCount += 1
        stagingGeneration += 1
        let generation = stagingGeneration
        loadTask?.cancel()
        debounceTask?.cancel()
        let previous = stagingTask
        stagingTask = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            defer {
                if self.stagingGeneration == generation {
                    self.stagingTask = nil
                }
            }
            var failedError: Error?
            do {
                try await operation()
            } catch {
                failedError = error
            }
            guard self.activeKey == key else {
                self.pendingStagingCount = max(0, self.pendingStagingCount - 1)
                return
            }
            self.evictCachedDiffs(for: evictFileIDs)
            if let failedError {
                self.diagnostic = Self.commitNotice(failedError)
                await self.reloadCatalog(for: key, expectedPending: self.pendingStagingCount)
            } else if self.pendingStagingCount == 1 {
                await self.reloadCatalog(for: key, expectedPending: 1)
            }
            self.pendingStagingCount = max(0, self.pendingStagingCount - 1)
        }
    }

    private func awaitPendingStaging() async {
        while let pending = stagingTask {
            let target = stagingGeneration
            await pending.value
            if stagingGeneration == target { break }
        }
    }

    private func reloadCatalog(for key: RepositoryKey, expectedPending: Int) async {
        let expectedContext = context?.generation
        snapshotGeneration += 1
        let generation = snapshotGeneration
        do {
            let loaded = try await service.loadCatalog(for: key, generation: generation)
            guard context?.generation == expectedContext,
                  activeKey == key,
                  pendingStagingCount == expectedPending else { return }
            if !loaded.waitingOnIndexLock {
                publishWithoutAnimation {
                    snapshot = loaded
                    loadState = .ready
                }
                diagnostic = loaded.diagnostic
                applyDefaultExpansion(loaded)
                for fileID in presentation.expandedFileIDs {
                    loadBodies(for: fileID)
                }
            }
        } catch is CancellationError {
            return
        } catch GitRunnerError.cancelled {
            return
        } catch {
            guard context?.generation == expectedContext, activeKey == key else { return }
            diagnostic = error.localizedDescription
        }
    }

    private func evictCachedDiffs(for fileIDs: Set<String>) {
        guard !fileIDs.isEmpty else { return }
        for fileID in fileIDs {
            for kind in FileComparisonKind.allCases {
                let key = reviewDiffKey(fileID, kind)
                diffs.removeValue(forKey: key)
                highlights.removeValue(forKey: "old:\(key)")
                highlights.removeValue(forKey: "new:\(key)")
            }
        }
    }

    var effectiveCommitStagedOnly: Bool {
        guard let draft = commitDraft, let snapshot else { return false }
        return draft.stagedOnly && snapshot.files.contains(where: \.isStaged)
    }

    func openCommitComposer() {
        guard commitDraft == nil else { return }
        guard case .ready = loadState, let snapshot, !snapshot.isClean, !snapshot.waitingOnIndexLock else { return }
        commitDraft = CommitDraft(stagedOnly: snapshot.files.contains(where: \.isStaged))
        CommitMessageGenerator.prewarm()
    }

    func closeCommitComposer() {
        guard commitDraft?.isCommitting != true else { return }
        commitDraftTask?.cancel()
        commitGeneration += 1
        commitDraft = nil
    }

    func updateCommitMessage(_ text: String) {
        commitDraft?.message = text
        commitDraft?.notice = nil
    }

    func updateCommitAction(_ action: CommitAction) {
        commitDraft?.action = action
        commitDraft?.notice = nil
    }

    func updateCommitStagedOnly(_ stagedOnly: Bool) {
        commitDraft?.stagedOnly = stagedOnly
        commitDraft?.notice = nil
    }

    var canSubmitCommit: Bool {
        guard let draft = commitDraft, let snapshot, !draft.isCommitting, !draft.isGenerating else { return false }
        return CommitPlanner.canSubmit(
            files: snapshot.files,
            message: draft.message,
            push: draft.push,
            detached: snapshot.revision.isDetached,
            indexLocked: snapshot.waitingOnIndexLock,
            catalogComplete: snapshot.isComplete,
            stagedOnly: effectiveCommitStagedOnly
        )
    }

    func draftCommitName() {
        guard var draft = commitDraft, !draft.isGenerating, !draft.isCommitting else { return }
        guard let snapshot else { return }
        let stagedOnly = effectiveCommitStagedOnly
        if stagingTask == nil {
            let selection = CommitPlanner.selection(from: snapshot.files, stagedOnly: stagedOnly)
            guard !selection.paths.isEmpty else {
                draft.notice = CommitPlanner.refusal(
                    files: snapshot.files,
                    push: draft.push,
                    detached: snapshot.revision.isDetached,
                    indexLocked: snapshot.waitingOnIndexLock,
                    catalogComplete: snapshot.isComplete,
                    stagedOnly: stagedOnly
                ) ?? "There is nothing to commit."
                commitDraft = draft
                return
            }
        }
        commitDraftTask?.cancel()
        commitGeneration += 1
        let token = commitGeneration
        let draftID = draft.id
        // The message streams into the box while drafting; a failure puts this back.
        let previousMessage = draft.message
        draft.isGenerating = true
        draft.notice = nil
        commitDraft = draft
        commitDraftTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.awaitPendingStaging()
                try Task.checkCancellation()
                guard self.commitGeneration == token,
                      self.commitDraft?.id == draftID,
                      let snapshot = self.snapshot else { return }
                let stagedOnly = self.effectiveCommitStagedOnly
                let selection = CommitPlanner.selection(from: snapshot.files, stagedOnly: stagedOnly)
                guard !selection.paths.isEmpty else {
                    let refusal = CommitPlanner.refusal(
                        files: snapshot.files,
                        push: self.commitDraft?.push ?? false,
                        detached: snapshot.revision.isDetached,
                        indexLocked: snapshot.waitingOnIndexLock,
                        catalogComplete: snapshot.isComplete,
                        stagedOnly: stagedOnly
                    ) ?? "There is nothing to commit."
                    self.commitDraft?.message = previousMessage
                    self.commitDraft?.isGenerating = false
                    self.commitDraft?.notice = refusal
                    return
                }
                let key = snapshot.revision.key
                let selected = snapshot.files.filter { selection.paths.contains($0.identityPath.display) }
                // Build output, lockfiles and the like are summarized, never read.
                let files = selected.filter { !CommitDigest.isNoise($0.identityPath.display) }
                let generated = selected.filter { CommitDigest.isNoise($0.identityPath.display) }
                let repository = key.basename
                let branch = snapshot.revision.isDetached ? "detached" : (snapshot.revision.branchName ?? "unknown")
                let untracked = selection.untrackedPaths.filter { !CommitDigest.isNoise($0) }
                var diffPaths: [String] = []
                var seenPaths = Set<String>()
                for path in selection.paths where !CommitDigest.isNoise(path) {
                    if seenPaths.insert(path).inserted {
                        diffPaths.append(path)
                    }
                }
                for file in files {
                    if let oldPath = file.oldPath,
                       oldPath.isLossless,
                       CommitPlanner.isSafeRelativePath(oldPath.display),
                       !CommitDigest.isNoise(oldPath.display),
                       seenPaths.insert(oldPath.display).inserted {
                        diffPaths.append(oldPath.display)
                    }
                }
                let material = try await self.service.commitMaterial(for: key, paths: diffPaths, untrackedPaths: untracked, stagedOnly: stagedOnly)
                let name = try await CommitMessageGenerator.subject(
                    repository: repository,
                    branch: branch,
                    files: files,
                    generated: generated,
                    diff: material.diff,
                    recentSubjects: material.recentSubjects,
                    stagedOnly: stagedOnly,
                    onPartial: { [weak self] partial in
                        guard let self, self.commitGeneration == token, self.commitDraft?.id == draftID else { return }
                        self.commitDraft?.message = partial
                    }
                )
                guard self.commitGeneration == token, self.commitDraft?.id == draftID else { return }
                self.commitDraft?.message = name
                self.commitDraft?.isGenerating = false
            } catch {
                guard self.commitGeneration == token, self.commitDraft?.id == draftID else { return }
                self.commitDraft?.message = previousMessage
                self.commitDraft?.isGenerating = false
                self.commitDraft?.notice = Self.commitNotice(error)
            }
        }
    }

    func commitFromComposer() {
        guard var draft = commitDraft, !draft.isCommitting, !draft.isGenerating, let snapshot else { return }
        let stagedOnly = effectiveCommitStagedOnly
        let message = CommitMessage.prepared(draft.message)
        if stagingTask == nil {
            guard CommitPlanner.canSubmit(
                files: snapshot.files,
                message: message,
                push: draft.push,
                detached: snapshot.revision.isDetached,
                indexLocked: snapshot.waitingOnIndexLock,
                catalogComplete: snapshot.isComplete,
                stagedOnly: stagedOnly
            ) else {
                draft.notice = CommitPlanner.refusal(
                    files: snapshot.files,
                    push: draft.push,
                    detached: snapshot.revision.isDetached,
                    indexLocked: snapshot.waitingOnIndexLock,
                    catalogComplete: snapshot.isComplete,
                    stagedOnly: stagedOnly
                )
                commitDraft = draft
                return
            }
        }
        commitDraftTask?.cancel()
        commitGeneration += 1
        let draftID = draft.id
        let push = draft.push
        let action = draft.action
        draft.isCommitting = true
        draft.notice = nil
        draft.message = message
        commitDraft = draft
        Task { [weak self] in
            guard let self else { return }
            await self.awaitPendingStaging()
            guard self.commitDraft?.id == draftID else { return }
            // A hidden review drops its snapshot but keeps the committing draft;
            // returning here would leave isCommitting true forever.
            guard let settled = self.snapshot else {
                self.commitDraft?.isCommitting = false
                self.commitDraft?.notice = "Nothing was committed. Try again."
                return
            }
            let settledStagedOnly = self.effectiveCommitStagedOnly
            let settledSelection = CommitPlanner.selection(from: settled.files, stagedOnly: settledStagedOnly)
            guard CommitPlanner.canSubmit(
                files: settled.files,
                message: message,
                push: push,
                detached: settled.revision.isDetached,
                indexLocked: settled.waitingOnIndexLock,
                catalogComplete: settled.isComplete,
                stagedOnly: settledStagedOnly
            ) else {
                self.commitDraft?.isCommitting = false
                self.commitDraft?.notice = CommitPlanner.refusal(
                    files: settled.files,
                    push: push,
                    detached: settled.revision.isDetached,
                    indexLocked: settled.waitingOnIndexLock,
                    catalogComplete: settled.isComplete,
                    stagedOnly: settledStagedOnly
                )
                return
            }
            let settledKey = settled.revision.key
            do {
                let outcome = try await self.service.commit(in: settledKey, paths: settledSelection.paths, message: message, push: push, stagedOnly: settledStagedOnly)
                if self.activeKey == settledKey {
                    self.evictCachedDiffs(for: Set(settledSelection.paths))
                    self.refresh(userInitiated: false)
                }
                var pullRequest: URL?
                if action == .pullRequest, outcome == .committed {
                    pullRequest = await self.service.pullRequestURL(for: settledKey)
                    if let pullRequest {
                        NSWorkspace.shared.open(pullRequest)
                    }
                }
                guard self.commitDraft?.id == draftID else { return }
                switch outcome {
                case .committed where action == .pullRequest && pullRequest == nil:
                    self.commitDraft?.isCommitting = false
                    self.commitDraft?.notice = "Committed and pushed. The remote has no known pull request page."
                case .committed:
                    self.commitDraft = nil
                case .committedPushFailed(let detail):
                    self.commitDraft?.isCommitting = false
                    self.commitDraft?.notice = detail
                }
            } catch {
                if self.activeKey == settledKey {
                    self.refresh(userInitiated: false)
                }
                guard self.commitDraft?.id == draftID else { return }
                self.commitDraft?.isCommitting = false
                self.commitDraft?.notice = Self.commitNotice(error)
            }
        }
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

    /// Drops the catalog, diffs, and highlight spans once the panel has finished
    /// sliding away. `hide()` leaves them in place so the slide can keep painting
    /// the last list; keeping them after that holds the file text until quit.
    func releaseHiddenContents() {
        guard loadState == .hidden else { return }
        snapshot = nil
        diffs = [:]
        highlights = [:]
        diagnostic = nil
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
        publishWithoutAnimation { loadState = .hidden }
        isRefreshing = false
        if commitDraft?.isCommitting != true {
            commitDraftTask?.cancel()
            commitGeneration += 1
            commitDraft = nil
        }
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
        if commitDraft?.isCommitting != true {
            commitDraftTask?.cancel()
            commitGeneration += 1
            commitDraft = nil
        }
    }

    private func resolve(_ context: ReviewContext) async {
        guard self.context?.generation == context.generation else { return }
        do {
            let key = try await service.resolveRepository(directory: context.directory)
            guard self.context?.generation == context.generation else { return }
            guard let key else {
                snapshot = nil
                if commitDraft?.isCommitting != true {
                    commitDraftTask?.cancel()
                    commitGeneration += 1
                    commitDraft = nil
                }
                publishWithoutAnimation { loadState = .noRepository }
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
                commitDraftTask?.cancel()
                commitGeneration += 1
                commitDraft = nil
            }
            publishWithoutAnimation { loadState = snapshot == nil ? .loading : loadState }
            snapshotGeneration += 1
            let generation = snapshotGeneration
            let loaded = try await service.loadCatalog(for: key, generation: generation)
            guard self.context?.generation == context.generation, pendingStagingCount == 0 else { return }
            if loaded.waitingOnIndexLock {
                if snapshot == nil {
                    publishWithoutAnimation { loadState = .waitingForGit }
                }
            } else {
                publishWithoutAnimation {
                    snapshot = loaded
                    loadState = .ready
                }
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
            if commitDraft?.isCommitting != true {
                commitDraftTask?.cancel()
                commitGeneration += 1
                commitDraft = nil
            }
            publishWithoutAnimation { loadState = .noWorkingTree }
            isRefreshing = false
        } catch GitRunnerError.gitUnavailable(let message) {
            guard self.context?.generation == context.generation else { return }
            snapshot = nil
            if commitDraft?.isCommitting != true {
                commitDraftTask?.cancel()
                commitGeneration += 1
                commitDraft = nil
            }
            publishWithoutAnimation { loadState = .unavailable(message) }
            isRefreshing = false
        } catch GitRunnerError.cancelled {
            return
        } catch is CancellationError {
            return
        } catch {
            guard self.context?.generation == context.generation else { return }
            if snapshot == nil {
                publishWithoutAnimation { loadState = .error(error.localizedDescription) }
            } else {
                diagnostic = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    private func nextGeneration() -> UInt64 {
        contextGeneration += 1
        return contextGeneration
    }

    private func startLoad(_ context: ReviewContext) {
        self.context = context
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            // Leave the reviewVisible withAnimation transaction before
            // publishing load-state, otherwise the first-open spinner is
            // captured as the animated end state until the next tab change.
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard let self, self.context?.generation == context.generation else { return }
            await self.resolve(context)
        }
    }

    private func publishWithoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
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
        guard pendingStagingCount == 0 else { return }
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

    private static func commitNotice(_ error: Error) -> String {
        switch error {
        case GitReviewServiceError.commitRejected(let message):
            return message
        case CommitNameError.unavailable(let message):
            return message
        case CommitNameError.empty:
            return "The model did not return a commit name."
        case CommitNameError.vague:
            return "The draft was too vague. Edit the name, or try again."
        case CommitNameError.tooLarge:
            return "This commit is too large for the on-device model. Write the message manually."
        case CommitNameError.declined:
            return "The on-device model declined this change. Write the message manually."
        case GitRunnerError.outputLimitExceeded:
            return "A changed file is too large for the commit draft. Write the message manually."
        case GitRunnerError.timeout:
            return "Git took too long."
        case GitRunnerError.failed(_, let stderr):
            return CommitDigest.failureLine(stderr, fallback: "Git could not finish.")
        default:
            return error.localizedDescription
        }
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
