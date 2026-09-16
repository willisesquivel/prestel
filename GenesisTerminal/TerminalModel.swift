import AppKit
import Combine

enum TabKind: String, Codable { case terminal, settings }

struct TabDescriptor: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: TabKind = .terminal
    var title = "Local"
    var directory: String = FileManager.default.homeDirectoryForCurrentUser.path
}

struct WindowDescriptor: Codable, Equatable {
    var id: UUID
    var tabs: [TabDescriptor]
    var selectedID: UUID?
    var sidebarVisible: Bool
    var sidebarWidth: Double
    var reviewVisible: Bool
    var reviewWidth: Double
    var splits: [SplitState]

    init(
        id: UUID,
        tabs: [TabDescriptor],
        selectedID: UUID?,
        sidebarVisible: Bool,
        sidebarWidth: Double,
        reviewVisible: Bool = false,
        reviewWidth: Double = 420,
        splits: [SplitState] = []
    ) {
        self.id = id
        self.tabs = tabs
        self.selectedID = selectedID
        self.sidebarVisible = sidebarVisible
        self.sidebarWidth = sidebarWidth
        self.reviewVisible = reviewVisible
        self.reviewWidth = Self.clampedReviewWidth(reviewWidth)
        self.splits = splits.map {
            SplitState(
                leadingID: $0.leadingID,
                trailingID: $0.trailingID,
                fraction: TabSplitGeometry.clampFraction($0.fraction),
                focusedID: $0.focusedID,
                axis: $0.axis
            )
        }
    }

    /// Legacy single-split keys kept for decoding older saved windows.
    var splitLeadingID: UUID? { splits.first?.leadingID }
    var splitTrailingID: UUID? { splits.first?.trailingID }
    var splitFraction: Double { splits.first?.fraction ?? 0.5 }
    var splitAxis: SplitAxis { splits.first?.axis ?? .horizontal }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tabs = try container.decode([TabDescriptor].self, forKey: .tabs)
        selectedID = try container.decodeIfPresent(UUID.self, forKey: .selectedID)
        sidebarVisible = try container.decode(Bool.self, forKey: .sidebarVisible)
        sidebarWidth = try container.decode(Double.self, forKey: .sidebarWidth)
        reviewVisible = try container.decodeIfPresent(Bool.self, forKey: .reviewVisible) ?? false
        let rawWidth = try container.decodeIfPresent(Double.self, forKey: .reviewWidth) ?? 420
        reviewWidth = Self.clampedReviewWidth(rawWidth)
        if let decoded = try container.decodeIfPresent([SplitState].self, forKey: .splits) {
            splits = decoded
        } else if let leading = try container.decodeIfPresent(UUID.self, forKey: .splitLeadingID),
                  let trailing = try container.decodeIfPresent(UUID.self, forKey: .splitTrailingID),
                  leading != trailing {
            let rawFraction = try container.decodeIfPresent(Double.self, forKey: .splitFraction) ?? 0.5
            let axis = try container.decodeIfPresent(SplitAxis.self, forKey: .splitAxis) ?? .horizontal
            splits = [
                SplitState(
                    leadingID: leading,
                    trailingID: trailing,
                    fraction: TabSplitGeometry.clampFraction(rawFraction),
                    focusedID: leading,
                    axis: axis
                )
            ]
        } else {
            splits = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(tabs, forKey: .tabs)
        try container.encodeIfPresent(selectedID, forKey: .selectedID)
        try container.encode(sidebarVisible, forKey: .sidebarVisible)
        try container.encode(sidebarWidth, forKey: .sidebarWidth)
        try container.encode(reviewVisible, forKey: .reviewVisible)
        try container.encode(reviewWidth, forKey: .reviewWidth)
        try container.encode(splits, forKey: .splits)
    }

    static func clampedReviewWidth(_ raw: Double) -> Double {
        guard raw.isFinite else { return 420 }
        return min(max(raw, 256), 720)
    }

    private enum CodingKeys: String, CodingKey {
        case id, tabs, selectedID, sidebarVisible, sidebarWidth, reviewVisible, reviewWidth
        case splits, splitLeadingID, splitTrailingID, splitFraction, splitAxis
    }
}

/// A window owns its tabs. Filtering and view attachment never own process lifetime.
@MainActor
final class TerminalModel: ObservableObject {
    let id: UUID
    @Published private(set) var tabs: [TerminalSession] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var splits: [SplitState] = []
    @Published var searchText = ""
    @Published var sidebarVisible = true
    @Published var sidebarWidth: Double = 172
    @Published var reviewVisible = false
    @Published var reviewWidth: Double = 420
    @Published private(set) var recentlyClosed: [TabDescriptor] = []
    private var history: [UUID] = []
    private var historyIndex = -1
    private var subscriptions: [UUID: AnyCancellable] = [:]

    init(directory: String = ShellConfiguration.defaultDirectory, restoration: WindowDescriptor? = nil) {
        id = restoration?.id ?? UUID()
        if let restoration, !restoration.tabs.isEmpty {
            sidebarVisible = restoration.sidebarVisible
            sidebarWidth = min(300, max(150, restoration.sidebarWidth))
            reviewVisible = restoration.reviewVisible
            reviewWidth = WindowDescriptor.clampedReviewWidth(restoration.reviewWidth)
            var seen = Set<UUID>()
            for descriptor in restoration.tabs where seen.insert(descriptor.id).inserted { append(descriptor) }
            select(restoration.selectedID ?? tabs[0].id)
            if selectedID == nil { select(tabs[0].id) }
            restoreSplit(from: restoration)
        } else {
            append(TabDescriptor(directory: directory))
            select(tabs[0].id)
        }
    }

    /// Owns an existing live session. Does not spawn a replacement shell.
    init(adopting tab: TerminalSession) {
        id = UUID()
        tabs = [tab]
        subscriptions[tab.id] = tab.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        selectedID = tab.id
        history = [tab.id]
        historyIndex = 0
    }

    var selectedTab: TerminalSession? { tabs.first { $0.id == selectedID } }
    /// The split currently on screen. Nil when the selected tab is not in a pair.
    var visibleSplit: SplitState? {
        guard let selectedID else { return nil }
        return split(containing: selectedID)
    }
    func split(containing id: UUID) -> SplitState? {
        splits.first { $0.contains(id) }
    }
    var filteredTabs: [TerminalSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? tabs : tabs.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.directory.localizedCaseInsensitiveContains(query)
        }
    }
    var sidebarItems: [SidebarTabItem] {
        SidebarTabLayout.items(from: filteredTabs, splits: splits)
    }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }

    @discardableResult
    func newTab(directory: String? = nil) -> TerminalSession {
        let descriptor = TabDescriptor(directory: directory ?? (selectedTab?.kind == .terminal ? selectedTab?.currentDirectory : nil) ?? ShellConfiguration.defaultDirectory)
        let tab = append(descriptor)
        searchText = ""
        select(tab.id)
        return tab
    }

    func showSettings() {
        if let existing = tabs.first(where: { $0.kind == .settings }) { select(existing.id) }
        else { select(append(TabDescriptor(kind: .settings, title: "Settings")).id) }
        searchText = ""
    }

    @discardableResult
    private func append(_ descriptor: TabDescriptor) -> TerminalSession {
        let tab = TerminalSession(descriptor: descriptor)
        tabs.append(tab)
        subscriptions[tab.id] = tab.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        return tab
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        reconcileSplit(selecting: id)
        guard id != selectedID else { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(id)
        if history.count > 100 { history.removeFirst() }
        historyIndex = history.count - 1
        selectedID = id
        // Show fresh cwd immediately when switching tabs instead of waiting
        // for the next poll or output.
        tabs.first { $0.id == id }?.refreshDirectoryFromProcess()
    }

    func split(with tabID: UUID, on side: SplitSide) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        if TabSplitGeometry.isNoOp(movingID: tabID, side: side, selectedID: selectedID, split: visibleSplit) {
            select(tabID)
            return
        }
        if let existing = visibleSplit, selectedID.map(existing.contains) == true,
           let index = splits.firstIndex(where: { $0.leadingID == existing.leadingID && $0.trailingID == existing.trailingID }) {
            let effectiveSide = side.axis == existing.axis
                ? side
                : (side.isPrimary ? (existing.axis == .horizontal ? .leading : .top) : (existing.axis == .horizontal ? .trailing : .bottom))
            let occupying = existing.id(on: effectiveSide)
            let opposite = existing.id(on: effectiveSide.opposite)
            let leading: UUID
            let trailing: UUID
            if tabID == opposite {
                leading = effectiveSide.isPrimary ? tabID : occupying
                trailing = effectiveSide.isPrimary ? occupying : tabID
            } else {
                leading = effectiveSide.isPrimary ? tabID : opposite
                trailing = effectiveSide.isPrimary ? opposite : tabID
            }
            splits[index] = SplitState(
                leadingID: leading,
                trailingID: trailing,
                fraction: existing.fraction,
                focusedID: tabID,
                axis: side.axis == existing.axis ? existing.axis : side.axis
            )
            select(tabID)
            return
        }
        guard let current = selectedID, current != tabID else { return }
        dissolvePairs(containing: [current, tabID])
        splits.append(
            SplitState(
                leadingID: side.isPrimary ? tabID : current,
                trailingID: side.isPrimary ? current : tabID,
                fraction: 0.5,
                focusedID: tabID,
                axis: side.axis
            )
        )
        select(tabID)
    }

    func unsplit(tabID: UUID? = nil) {
        guard let id = tabID ?? selectedID else { return }
        splits.removeAll { $0.contains(id) }
    }

    func resizeSplit(to proposedFraction: Double, along extent: CGFloat) {
        guard let selectedID,
              let index = splits.firstIndex(where: { $0.contains(selectedID) }) else { return }
        splits[index].fraction = TabSplitGeometry.clampFraction(proposedFraction, along: extent)
    }

    func tab(id: UUID) -> TerminalSession? {
        tabs.first { $0.id == id }
    }

    func cycle(_ offset: Int) {
        let order = sidebarItems.flatMap(\.members)
        guard !order.isEmpty else { return }
        let index = order.firstIndex { $0 == selectedID } ?? 0
        let next = (index + offset % order.count + order.count) % order.count
        select(order[next])
    }

    func navigate(_ offset: Int) {
        let target = historyIndex + offset
        guard history.indices.contains(target) else { return }
        historyIndex = target
        let id = history[target]
        reconcileSplit(selecting: id)
        selectedID = id
        selectedTab?.refreshDirectoryFromProcess()
    }

    /// Reorder by stable tab identity. `insertionIndex` is a canonical index in
    /// `tabs` (0...count) measured *before* the moving tab is removed. Moving
    /// downward therefore has to account for the hole left by the removal.
    func moveTab(_ id: UUID, to insertionIndex: Int) {
        if let pair = split(containing: id) {
            movePair(pair, to: insertionIndex)
            return
        }
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        var destination = min(max(insertionIndex, 0), tabs.count)
        if destination == from || destination == from + 1 { return }
        let tab = tabs.remove(at: from)
        if from < destination { destination -= 1 }
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
    }

    private func movePair(_ pair: SplitState, to insertionIndex: Int) {
        guard let firstIndex = tabs.firstIndex(where: { $0.id == pair.leadingID }),
              let secondIndex = tabs.firstIndex(where: { $0.id == pair.trailingID }) else { return }
        let lower = min(firstIndex, secondIndex)
        let upper = max(firstIndex, secondIndex)
        var destination = min(max(insertionIndex, 0), tabs.count)
        if destination >= lower && destination <= upper + 1 { return }

        let first = tabs[lower]
        let second = tabs[upper]
        tabs.remove(at: upper)
        tabs.remove(at: lower)
        if lower < destination { destination -= 2 }
        tabs.insert(first, at: destination)
        tabs.insert(second, at: destination + 1)
    }

    /// Remove a tab from this window without terminating its process or recording recently-closed.
    @discardableResult
    func detachTab(_ id: UUID) -> TerminalSession? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let partner = split(containing: id)?.partner(of: id)
        let tab = tabs.remove(at: index)
        subscriptions.removeValue(forKey: id)
        let removedThroughCursor = history.prefix(historyIndex + 1).filter { $0 == id }.count
        history.removeAll { $0 == id }
        historyIndex -= removedThroughCursor
        collapseSplit(removing: id)
        if selectedID == id {
            selectedID = nil
            selectNeighbor(at: index, preferred: partner)
        }
        return tab
    }

    /// Take ownership of a live session already detached from another window.
    func adopt(_ tab: TerminalSession, at insertionIndex: Int, selecting: Bool) {
        guard !tabs.contains(where: { $0.id == tab.id }) else { return }
        let index = min(max(insertionIndex, 0), tabs.count)
        tabs.insert(tab, at: index)
        subscriptions[tab.id] = tab.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        searchText = ""
        if selecting { select(tab.id) }
    }

    /// Call only after the window controller has resolved close confirmation.
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let partner = split(containing: id)?.partner(of: id)
        recentlyClosed.append(tabs[index].descriptor)
        recentlyClosed = Array(recentlyClosed.suffix(20))
        tabs[index].close()
        tabs.remove(at: index)
        subscriptions.removeValue(forKey: id)
        // Preserve the cursor's position when entries before it disappear.
        let removedThroughCursor = history.prefix(historyIndex + 1).filter { $0 == id }.count
        history.removeAll { $0 == id }
        historyIndex -= removedThroughCursor
        collapseSplit(removing: id)
        if selectedID == id {
            selectedID = nil
            selectNeighbor(at: index, preferred: partner)
        }
    }

    func reopenClosedTab() {
        guard var descriptor = recentlyClosed.popLast() else { return }
        descriptor.id = UUID() // Replacement session, never a resurrected process.
        let tab = append(descriptor)
        searchText = ""
        select(tab.id)
    }

    var descriptor: WindowDescriptor {
        WindowDescriptor(
            id: id,
            tabs: tabs.map(\.descriptor),
            selectedID: selectedID,
            sidebarVisible: sidebarVisible,
            sidebarWidth: sidebarWidth,
            reviewVisible: reviewVisible,
            reviewWidth: reviewWidth,
            splits: splits
        )
    }

    private func restoreSplit(from restoration: WindowDescriptor) {
        splits = restoration.splits.compactMap { split in
            guard split.leadingID != split.trailingID,
                  tabs.contains(where: { $0.id == split.leadingID }),
                  tabs.contains(where: { $0.id == split.trailingID }) else { return nil }
            let focusedID: UUID
            if let selectedID, split.contains(selectedID) {
                focusedID = selectedID
            } else {
                focusedID = split.focusedID
            }
            return SplitState(
                leadingID: split.leadingID,
                trailingID: split.trailingID,
                fraction: split.fraction,
                focusedID: focusedID,
                axis: split.axis
            )
        }
    }

    /// Selecting a pane focuses it.
    private func reconcileSplit(selecting id: UUID) {
        guard let index = splits.firstIndex(where: { $0.contains(id) }),
              splits[index].focusedID != id else { return }
        splits[index].focusedID = id
    }

    private func collapseSplit(removing id: UUID) {
        splits.removeAll { $0.contains(id) }
    }

    private func dissolvePairs(containing ids: [UUID]) {
        for id in ids {
            splits.removeAll { $0.contains(id) }
        }
    }

    private func selectNeighbor(at index: Int, preferred: UUID?) {
        if let preferred, tabs.contains(where: { $0.id == preferred }) {
            select(preferred)
        } else if !tabs.isEmpty {
            select(tabs[min(index, tabs.count - 1)].id)
        }
    }
    func resizeSidebar(to proposedWidth: CGFloat, availableWidth: CGFloat) {
        sidebarWidth = ShellLayout.clampSidebarPreference(
            proposedWidth,
            windowWidth: availableWidth,
            reviewVisible: reviewVisible
        )
    }
    func resizeReview(to proposedWidth: CGFloat, availableWidth: CGFloat) {
        reviewWidth = ShellLayout.clampReviewPreference(
            proposedWidth,
            windowWidth: availableWidth,
            sidebarVisible: sidebarVisible,
            preferredSidebarWidth: sidebarWidth
        )
    }
    func resetReviewWidth() {
        reviewWidth = 420
    }
    func closeAll() { tabs.forEach { $0.close() } }
}
