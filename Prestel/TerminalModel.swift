import AppKit
import Combine

enum TabKind: String, Codable { case terminal, settings }

struct TabDescriptor: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: TabKind = .terminal
    var title = "Local"
    var directory: String = FileManager.default.homeDirectoryForCurrentUser.path
    /// User-facing sidebar name. Nil keeps the shell title.
    var customTitle: String? = nil
}

struct WindowDescriptor: Codable, Equatable {
    var id: UUID
    var tabs: [TabDescriptor]
    var archivedTabs: [TabDescriptor]
    var selectedID: UUID?
    var sidebarVisible: Bool
    var sidebarWidth: Double
    var reviewVisible: Bool
    var reviewWidth: Double
    var splits: [SplitState]
    var folders: [TabFolder]

    init(
        id: UUID,
        tabs: [TabDescriptor],
        selectedID: UUID?,
        sidebarVisible: Bool,
        sidebarWidth: Double,
        reviewVisible: Bool = false,
        reviewWidth: Double = 420,
        splits: [SplitState] = [],
        archivedTabs: [TabDescriptor] = [],
        folders: [TabFolder] = []
    ) {
        self.id = id
        self.tabs = tabs
        self.archivedTabs = archivedTabs
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
        self.folders = folders
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
        archivedTabs = try container.decodeIfPresent([TabDescriptor].self, forKey: .archivedTabs) ?? []
        selectedID = try container.decodeIfPresent(UUID.self, forKey: .selectedID)
        sidebarVisible = try container.decode(Bool.self, forKey: .sidebarVisible)
        sidebarWidth = try container.decode(Double.self, forKey: .sidebarWidth)
        reviewVisible = try container.decodeIfPresent(Bool.self, forKey: .reviewVisible) ?? false
        let rawWidth = try container.decodeIfPresent(Double.self, forKey: .reviewWidth) ?? 420
        reviewWidth = Self.clampedReviewWidth(rawWidth)
        if let decoded = try container.decodeIfPresent([SplitState].self, forKey: .splits) {
            splits = decoded.compactMap { split in
                guard split.leadingID != split.trailingID else { return nil }
                let focused = split.contains(split.focusedID) ? split.focusedID : split.leadingID
                return SplitState(
                    leadingID: split.leadingID,
                    trailingID: split.trailingID,
                    fraction: TabSplitGeometry.clampFraction(split.fraction),
                    focusedID: focused,
                    axis: split.axis
                )
            }
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
        let knownIDs = Set(tabs.map(\.id)).union(archivedTabs.map(\.id))
        folders = SidebarOutline.sanitized(
            try container.decodeIfPresent([TabFolder].self, forKey: .folders) ?? [],
            tabIDs: knownIDs
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(archivedTabs, forKey: .archivedTabs)
        try container.encodeIfPresent(selectedID, forKey: .selectedID)
        try container.encode(sidebarVisible, forKey: .sidebarVisible)
        try container.encode(sidebarWidth, forKey: .sidebarWidth)
        try container.encode(reviewVisible, forKey: .reviewVisible)
        try container.encode(reviewWidth, forKey: .reviewWidth)
        try container.encode(splits, forKey: .splits)
        try container.encode(folders, forKey: .folders)
    }

    static func clampedReviewWidth(_ raw: Double) -> Double {
        guard raw.isFinite else { return 420 }
        return min(max(raw, 256), 720)
    }

    private enum CodingKeys: String, CodingKey {
        case id, tabs, archivedTabs, selectedID, sidebarVisible, sidebarWidth, reviewVisible, reviewWidth
        case splits, splitLeadingID, splitTrailingID, splitFraction, splitAxis, folders
    }
}

/// A window owns its tabs. Filtering and view attachment never own process lifetime.
@MainActor
final class TerminalModel: ObservableObject {
    private static var opensSidebarInNewWindows: Bool {
        UserDefaults.standard.object(forKey: "openSidebarInNewWindows") == nil
            || UserDefaults.standard.bool(forKey: "openSidebarInNewWindows")
    }

    let id: UUID
    @Published private(set) var tabs: [TerminalSession] = []
    @Published private(set) var archived: [TerminalSession] = []
    @Published var showingArchive = false
    @Published private(set) var selectedID: UUID?
    /// Tabs participating in sidebar selection. `selectedID` remains the tab
    /// whose terminal is on screen; this set owns multi-tab reorder intent.
    @Published private(set) var selectedTabIDs: Set<UUID> = []
    @Published private(set) var splits: [SplitState] = []
    @Published private(set) var folders: [TabFolder] = []
    @Published var searchText = ""
    /// Find-in-terminal bar state for this window's selected terminal.
    let find = TerminalFind()
    @Published var sidebarVisible = true
    @Published var sidebarWidth: Double = 172
    @Published var reviewVisible = false
    @Published var reviewWidth: Double = 420
    @Published private(set) var recentlyClosed: [TabDescriptor] = []
    private var history: [UUID] = []
    private var historyIndex = -1
    private var selectionAnchorID: UUID?
    private var subscriptions: [UUID: AnyCancellable] = [:]

    init(directory: String = ShellConfiguration.defaultDirectory, restoration: WindowDescriptor? = nil) {
        id = restoration?.id ?? UUID()
        if restoration == nil { sidebarVisible = Self.opensSidebarInNewWindows }
        if let restoration, !restoration.tabs.isEmpty {
            sidebarVisible = restoration.sidebarVisible
            sidebarWidth = min(300, max(150, restoration.sidebarWidth))
            reviewVisible = restoration.reviewVisible
            reviewWidth = WindowDescriptor.clampedReviewWidth(restoration.reviewWidth)
            var seen = Set<UUID>()
            for descriptor in restoration.tabs where seen.insert(descriptor.id).inserted { append(descriptor) }
            for descriptor in restoration.archivedTabs where seen.insert(descriptor.id).inserted {
                let tab = TerminalSession(descriptor: descriptor)
                archived.append(tab)
                observe(tab)
            }
            select(restoration.selectedID ?? tabs[0].id)
            if selectedID == nil { select(tabs[0].id) }
            restoreSplit(from: restoration)
            folders = SidebarOutline.sanitized(
                restoration.folders,
                tabIDs: Set(tabs.map(\.id)).union(archived.map(\.id))
            )
        } else {
            append(TabDescriptor(directory: directory))
            select(tabs[0].id)
        }
    }

    /// Owns an existing live session. Does not spawn a replacement shell.
    init(adopting tab: TerminalSession) {
        self.id = UUID()
        sidebarVisible = Self.opensSidebarInNewWindows
        tabs = [tab]
        subscriptions[tab.id] = tab.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        selectedID = tab.id
        selectedTabIDs = [tab.id]
        selectionAnchorID = tab.id
        history = [tab.id]
        historyIndex = 0
    }

    /// Owns existing live sessions without replacing their PTYs.
    init(adopting adoptedTabs: [TerminalSession], selectedID preferredID: UUID?) {
        id = UUID()
        sidebarVisible = Self.opensSidebarInNewWindows
        tabs = adoptedTabs
        for tab in adoptedTabs {
            subscriptions[tab.id] = tab.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        }
        let activeID = preferredID.flatMap { id in adoptedTabs.contains(where: { $0.id == id }) ? id : nil }
            ?? adoptedTabs.first?.id
        selectedID = activeID
        selectedTabIDs = Set(adoptedTabs.map(\.id))
        selectionAnchorID = activeID
        history = activeID.map { [$0] } ?? []
        historyIndex = 0
    }

    var selectedTab: TerminalSession? {
        tabs.first { $0.id == selectedID } ?? archived.first { $0.id == selectedID }
    }
    var allSessions: [TerminalSession] { tabs + archived }
    /// The split currently on screen. Nil when the selected tab is not in a pair.
    var visibleSplit: SplitState? {
        guard let selectedID else { return nil }
        return split(containing: selectedID)
    }
    func split(containing id: UUID) -> SplitState? {
        splits.first { $0.contains(id) }
    }
    var filteredTabs: [TerminalSession] {
        filtered(tabs)
    }
    var filteredArchived: [TerminalSession] {
        filtered(archived)
    }
    var sidebarItems: [SidebarTabItem] {
        SidebarTabLayout.items(from: filteredTabs, splits: splits)
    }
    var sidebarSections: [SidebarSection] {
        SidebarOutline.sections(
            tabs: tabs,
            splits: splits,
            folders: folders,
            selectedID: selectedID,
            query: searchText
        )
    }
    var sidebarVisualIDs: [UUID] {
        SidebarOutline.visualIDs(in: sidebarSections)
    }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }

    @discardableResult
    func newTab(directory: String? = nil) -> TerminalSession {
        let joinedFolder = selectedID.flatMap { folderContaining($0)?.id }
        let afterID = selectedID
        let descriptor = TabDescriptor(directory: directory ?? (selectedTab?.kind == .terminal ? selectedTab?.currentDirectory : nil) ?? ShellConfiguration.defaultDirectory)
        let tab = append(descriptor)
        if let joinedFolder, let afterID, let index = tabs.firstIndex(where: { $0.id == afterID }) {
            moveTab(tab.id, to: index + 1)
            setFolderMembership(tab.id, folderID: joinedFolder)
        }
        searchText = ""
        showingArchive = false
        select(tab.id)
        return tab
    }

    func showSettings() {
        showingArchive = false
        if let existing = tabs.first(where: { $0.kind == .settings }) { select(existing.id) }
        else { select(append(TabDescriptor(kind: .settings, title: "Settings")).id) }
        searchText = ""
    }

    @discardableResult
    private func append(_ descriptor: TabDescriptor) -> TerminalSession {
        let tab = TerminalSession(descriptor: descriptor)
        tabs.append(tab)
        observe(tab)
        return tab
    }

    private func observe(_ tab: TerminalSession) {
        subscriptions[tab.id] = tab.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    private func filtered(_ sessions: [TerminalSession]) -> [TerminalSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? sessions : sessions.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
                || $0.directory.localizedCaseInsensitiveContains(query)
        }
    }

    func select(_ id: UUID) {
        select(id, shift: false, command: false)
    }

    /// Lume-style ordered selection: plain click replaces, Shift selects the
    /// inclusive range from the last plain-click anchor, and Command toggles.
    func select(_ id: UUID, shift: Bool, command: Bool) {
        let open = tabs.first { $0.id == id }
        let archivedSession = archived.first { $0.id == id }
        guard let session = open ?? archivedSession else { return }
        if command {
            if selectedTabIDs.contains(id) {
                selectedTabIDs.remove(id)
            } else {
                selectedTabIDs.insert(id)
            }
            selectionAnchorID = id
        } else if shift,
                  open != nil,
                  let selectionAnchorID,
                  let anchorIndex = tabs.firstIndex(where: { $0.id == selectionAnchorID }),
                  let clickedIndex = tabs.firstIndex(where: { $0.id == id }) {
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            selectedTabIDs = Set(range.map { tabs[$0].id })
        } else {
            selectedTabIDs = [id]
            selectionAnchorID = id
        }
        activate(id, session: session, isArchived: archivedSession != nil)
    }

    private func activate(_ id: UUID, session: TerminalSession, isArchived: Bool) {
        showingArchive = isArchived
        if !isArchived {
            reconcileSplit(selecting: id)
        }
        guard id != selectedID else { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(id)
        if history.count > 100 { history.removeFirst() }
        historyIndex = history.count - 1
        selectedID = id
        // Show fresh cwd immediately when switching tabs instead of waiting
        // for the next poll or output.
        session.refreshDirectoryFromProcess()
    }

    /// Dragging an already-selected tab keeps the full set. Crossing the drag
    /// threshold on an unselected tab collapses the selection to that tab.
    func prepareSelectionForDrag(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }), !selectedTabIDs.contains(id) else { return }
        selectedTabIDs = [id]
        selectionAnchorID = id
    }

    /// Canonical tab order carried by a drag. Split partners expand together,
    /// matching the existing single-tab reorder rule.
    func orderedDraggedTabIDs(grabbed id: UUID) -> [UUID] {
        guard tabs.contains(where: { $0.id == id }) else { return [] }
        var moving = selectedTabIDs.contains(id) ? selectedTabIDs : Set([id])
        for selectedID in Array(moving) {
            if let partner = split(containing: selectedID)?.partner(of: selectedID) {
                moving.insert(partner)
            }
        }
        return tabs.map(\.id).filter(moving.contains)
    }

    func split(with tabID: UUID, on side: SplitSide) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        if TabSplitGeometry.isNoOp(movingID: tabID, side: side, selectedID: selectedID, split: visibleSplit) {
            select(tabID)
            return
        }
        if let existing = visibleSplit, selectedID.map(existing.contains) == true,
           splits.contains(where: { $0.leadingID == existing.leadingID && $0.trailingID == existing.trailingID }) {
            // A tab can only live in one pair. Dissolve any other pair containing
            // the dragged tab so it doesn't end up in two splits at once.
            splits.removeAll { $0.contains(tabID) && !($0.leadingID == existing.leadingID && $0.trailingID == existing.trailingID) }
            guard let index = splits.firstIndex(where: { $0.leadingID == existing.leadingID && $0.trailingID == existing.trailingID }) else { return }
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
        keepSplitPairInOneFolder(current, tabID)
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
        tabs.first { $0.id == id } ?? archived.first { $0.id == id }
    }

    func cycle(_ offset: Int) {
        let order = SidebarOutline.tabOrder(in: sidebarSections)
        guard !order.isEmpty else { return }
        let index = order.firstIndex { $0 == selectedID } ?? 0
        let next = ((index + offset) % order.count + order.count) % order.count
        select(order[next])
    }

    func navigate(_ offset: Int) {
        let target = historyIndex + offset
        guard history.indices.contains(target) else { return }
        historyIndex = target
        let id = history[target]
        showingArchive = archived.contains { $0.id == id }
        if !showingArchive {
            reconcileSplit(selecting: id)
        }
        selectedID = id
        selectedTabIDs = [id]
        selectionAnchorID = id
        selectedTab?.refreshDirectoryFromProcess()
    }

    /// Reorder by stable tab identity. `insertionIndex` is a canonical index in
    /// `tabs` (0...count) measured *before* the moving tab is removed. Moving
    /// downward therefore has to account for the hole left by the removal.
    func moveTab(_ id: UUID, to insertionIndex: Int, folderID: UUID? = nil, assignsFolder: Bool = false) {
        moveTabs([id], to: insertionIndex, folderID: folderID, assignsFolder: assignsFolder)
    }

    /// Moves every supplied tab as one rigid block while preserving canonical
    /// order. `insertionIndex` is measured before the block is removed.
    func moveTabs(_ ids: [UUID], to insertionIndex: Int, folderID: UUID? = nil, assignsFolder: Bool = false) {
        let movingIDs = expandedMoveIDs(ids)
        guard !movingIDs.isEmpty else { return }
        let movingTabs = tabs.filter { movingIDs.contains($0.id) }
        let removedBeforeDestination = tabs.prefix(min(max(insertionIndex, 0), tabs.count))
            .filter { movingIDs.contains($0.id) }.count
        var destination = min(max(insertionIndex, 0), tabs.count)
        destination -= removedBeforeDestination
        tabs.removeAll { movingIDs.contains($0.id) }
        destination = min(max(destination, 0), tabs.count)
        tabs.insert(contentsOf: movingTabs, at: destination)
        if assignsFolder {
            setFolderMembership(Array(movingIDs), folderID: folderID)
        }
    }

    func tabMoveWouldChange(_ ids: [UUID], to insertionIndex: Int, folderID: UUID?) -> Bool {
        let movingIDs = expandedMoveIDs(ids)
        guard !movingIDs.isEmpty else { return false }
        let currentOrder = tabs.map(\.id)
        let movingOrder = currentOrder.filter(movingIDs.contains)
        let clamped = min(max(insertionIndex, 0), currentOrder.count)
        let removedBefore = currentOrder.prefix(clamped).filter(movingIDs.contains).count
        var rest = currentOrder.filter { !movingIDs.contains($0) }
        rest.insert(contentsOf: movingOrder, at: min(max(clamped - removedBefore, 0), rest.count))
        if rest != currentOrder { return true }
        return movingIDs.contains { folderContaining($0)?.id != folderID }
    }

    private func expandedMoveIDs(_ ids: [UUID]) -> Set<UUID> {
        var result = Set(ids.filter { id in tabs.contains(where: { $0.id == id }) })
        for id in Array(result) {
            if let partner = split(containing: id)?.partner(of: id) {
                result.insert(partner)
            }
        }
        return result
    }

    /// Remove a tab from this window without terminating its process or recording recently-closed.
    @discardableResult
    func detachTab(_ id: UUID) -> TerminalSession? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let partner = split(containing: id)?.partner(of: id)
        detachFromFolders(id)
        let tab = tabs.remove(at: index)
        selectedTabIDs.remove(id)
        if selectionAnchorID == id { selectionAnchorID = nil }
        subscriptions.removeValue(forKey: id)
        let removedThroughCursor = history.prefix(historyIndex + 1).filter { $0 == id }.count
        history.removeAll { $0 == id }
        historyIndex -= removedThroughCursor
        collapseSplit(removing: id)
        if selectedID == id {
            selectedID = nil
            selectNeighbor(at: index, preferred: partner)
        } else if selectedTabIDs.isEmpty, let selectedID {
            selectedTabIDs = [selectedID]
            selectionAnchorID = selectedID
        }
        return tab
    }

    /// Batch counterpart used by cross-window and detached-window drags.
    /// Sessions remain live and are returned in their original tab order.
    func detachTabs(_ ids: [UUID]) -> [TerminalSession] {
        let movingIDs = expandedMoveIDs(ids)
        guard !movingIDs.isEmpty else { return [] }
        let originalTabs = tabs
        let moving = originalTabs.filter { movingIDs.contains($0.id) }
        let firstRemovedIndex = originalTabs.firstIndex { movingIDs.contains($0.id) } ?? 0
        detachFromFolders(Array(movingIDs))
        tabs.removeAll { movingIDs.contains($0.id) }
        for id in movingIDs { subscriptions.removeValue(forKey: id) }
        let removedThroughCursor = history.prefix(historyIndex + 1).filter(movingIDs.contains).count
        history.removeAll { movingIDs.contains($0) }
        historyIndex -= removedThroughCursor
        splits.removeAll { movingIDs.contains($0.leadingID) || movingIDs.contains($0.trailingID) }
        selectedTabIDs.subtract(movingIDs)
        if let selectionAnchorID, movingIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = nil
        }
        if let selectedID, movingIDs.contains(selectedID) {
            self.selectedID = nil
            if !tabs.isEmpty {
                let neighbor = tabs[min(firstRemovedIndex, tabs.count - 1)]
                select(neighbor.id)
            }
        } else if selectedTabIDs.isEmpty, let selectedID {
            selectedTabIDs = [selectedID]
            selectionAnchorID = selectedID
        }
        return moving
    }

    /// Take ownership of a live session already detached from another window.
    func adopt(_ tab: TerminalSession, at insertionIndex: Int, selecting: Bool) {
        adopt([tab], at: insertionIndex, selecting: selecting ? tab.id : nil)
    }

    /// Batch adoption preserves the source block's order and selection.
    func adopt(_ adoptedTabs: [TerminalSession], at insertionIndex: Int, selecting activeID: UUID?) {
        let adoptedTabs = adoptedTabs.filter { incoming in
            !tabs.contains(where: { $0.id == incoming.id })
        }
        guard !adoptedTabs.isEmpty else { return }
        let index = min(max(insertionIndex, 0), tabs.count)
        tabs.insert(contentsOf: adoptedTabs, at: index)
        adoptedTabs.forEach(observe)
        searchText = ""
        if let activeID, adoptedTabs.contains(where: { $0.id == activeID }) {
            selectedTabIDs = Set(adoptedTabs.map(\.id))
            selectionAnchorID = activeID
            if let active = tab(id: activeID) {
                activate(activeID, session: active, isArchived: false)
            }
        }
    }

    /// Hide a live session from the sidebar without terminating its process.
    func archiveTab(_ id: UUID) {
        let wasLast = tabs.count == 1
        guard let tab = detachTab(id) else { return }
        archived.append(tab)
        observe(tab)
        if wasLast { newTab() }
    }

    func unarchiveTab(_ id: UUID) {
        guard let index = archived.firstIndex(where: { $0.id == id }) else { return }
        let tab = archived.remove(at: index)
        subscriptions.removeValue(forKey: id)
        showingArchive = false
        adopt(tab, at: tabs.count, selecting: true)
    }

    func closeArchivedTab(_ id: UUID) {
        guard let index = archived.firstIndex(where: { $0.id == id }) else { return }
        recentlyClosed.append(archived[index].descriptor)
        recentlyClosed = Array(recentlyClosed.suffix(20))
        archived[index].close()
        archived.remove(at: index)
        subscriptions.removeValue(forKey: id)
        selectedTabIDs.remove(id)
        if selectionAnchorID == id { selectionAnchorID = nil }
        if selectedID == id {
            if archived.isEmpty {
                if let first = tabs.first { select(first.id) }
            } else {
                select(archived[min(index, archived.count - 1)].id)
            }
        }
    }

    /// Call only after the window controller has resolved close confirmation.
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let partner = split(containing: id)?.partner(of: id)
        detachFromFolders(id)
        recentlyClosed.append(tabs[index].descriptor)
        recentlyClosed = Array(recentlyClosed.suffix(20))
        tabs[index].close()
        tabs.remove(at: index)
        selectedTabIDs.remove(id)
        if selectionAnchorID == id { selectionAnchorID = nil }
        subscriptions.removeValue(forKey: id)
        // Preserve the cursor's position when entries before it disappear.
        let removedThroughCursor = history.prefix(historyIndex + 1).filter { $0 == id }.count
        history.removeAll { $0 == id }
        historyIndex -= removedThroughCursor
        collapseSplit(removing: id)
        if selectedID == id {
            selectedID = nil
            selectNeighbor(at: index, preferred: partner)
        } else if selectedTabIDs.isEmpty, let selectedID {
            selectedTabIDs = [selectedID]
            selectionAnchorID = selectedID
        }
    }

    func reopenClosedTab() {
        guard var descriptor = recentlyClosed.popLast() else { return }
        descriptor.id = UUID() // Replacement session, never a resurrected process.
        let tab = append(descriptor)
        searchText = ""
        showingArchive = false
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
            splits: splits,
            archivedTabs: archived.map(\.descriptor),
            folders: normalizedFolders()
        )
    }

    private func restoreSplit(from restoration: WindowDescriptor) {
        var seen = Set<UUID>()
        splits = restoration.splits.compactMap { split in
            guard split.leadingID != split.trailingID,
                  tabs.contains(where: { $0.id == split.leadingID }),
                  tabs.contains(where: { $0.id == split.trailingID }),
                  !seen.contains(split.leadingID),
                  !seen.contains(split.trailingID) else { return nil }
            let focusedID: UUID
            if let selectedID, split.contains(selectedID) {
                focusedID = selectedID
            } else if split.contains(split.focusedID) {
                focusedID = split.focusedID
            } else {
                focusedID = split.leadingID
            }
            seen.insert(split.leadingID)
            seen.insert(split.trailingID)
            return SplitState(
                leadingID: split.leadingID,
                trailingID: split.trailingID,
                fraction: TabSplitGeometry.clampFraction(split.fraction),
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

    func folderContaining(_ tabID: UUID) -> TabFolder? {
        folders.first { $0.tabIDs.contains(tabID) }
    }

    func dropTarget(visibleInsertion: Int, visibleIDs: [UUID], probe: FolderDropProbe? = nil) -> SidebarDropTarget {
        SidebarOutline.dropTarget(
            visibleInsertion: visibleInsertion,
            visibleIDs: visibleIDs,
            tabIDs: tabs.map(\.id),
            folders: folders,
            probe: probe
        )
    }

    @discardableResult
    func makeFolder(containing tabID: UUID) -> TabFolder? {
        guard tabs.contains(where: { $0.id == tabID }) else { return nil }
        var members = [tabID]
        if let partner = split(containing: tabID)?.partner(of: tabID) {
            members.append(partner)
        }
        let name = nextFolderName()
        let anchor = tabs.firstIndex(where: { $0.id == tabID }) ?? tabs.count
        detachFromFolders(members)
        let folder = TabFolder(name: name, collapsed: false, tabIDs: members, anchor: anchor)
        folders.append(folder)
        return folder
    }

    func add(_ tabID: UUID, to folderID: UUID) {
        guard folders.contains(where: { $0.id == folderID }) else { return }
        setFolderMembership(tabID, folderID: folderID)
    }

    func removeFromFolder(_ tabID: UUID) {
        setFolderMembership(tabID, folderID: nil)
    }

    func toggleFolder(_ id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].collapsed.toggle()
    }

    func renameFolder(_ id: UUID, to proposed: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folders[index].name = String(trimmed.prefix(256))
    }

    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
    }

    func renameTab(_ id: UUID, to proposed: String) {
        tab(id: id)?.setDisplayTitle(proposed)
    }

    func setFolderMembership(_ tabID: UUID, folderID: UUID?) {
        setFolderMembership([tabID], folderID: folderID)
    }

    func setFolderMembership(_ tabIDs: [UUID], folderID: UUID?) {
        let ids = expandedMoveIDs(tabIDs)
        detachFromFolders(Array(ids))
        guard let folderID, let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        for tab in tabs where ids.contains(tab.id) && !folders[index].tabIDs.contains(tab.id) {
            folders[index].tabIDs.append(tab.id)
        }
    }

    private func keepSplitPairInOneFolder(_ first: UUID, _ second: UUID) {
        if let folder = folderContaining(first) ?? folderContaining(second) {
            setFolderMembership(first, folderID: folder.id)
        }
    }

    private func nextFolderName() -> String {
        let existing = Set(folders.map(\.name))
        if !existing.contains("Folder") { return "Folder" }
        var number = 2
        while existing.contains("Folder \(number)") { number += 1 }
        return "Folder \(number)"
    }

    private func normalizedFolders() -> [TabFolder] {
        let order = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })
        return folders.map { folder in
            var copy = folder
            copy.tabIDs.sort { (order[$0] ?? .max) < (order[$1] ?? .max) }
            return copy
        }
    }

    private func detachFromFolders(_ id: UUID) {
        detachFromFolders([id])
    }

    private func detachFromFolders(_ ids: [UUID]) {
        let removing = Set(ids)
        guard !removing.isEmpty else { return }
        for index in folders.indices {
            let removed = folders[index].tabIDs.filter { removing.contains($0) }
            guard !removed.isEmpty else { continue }
            folders[index].tabIDs.removeAll { removing.contains($0) }
            if folders[index].tabIDs.isEmpty {
                let anchors = removed.compactMap { id in tabs.firstIndex(where: { $0.id == id }) }
                if let anchor = anchors.min() {
                    folders[index].anchor = anchor
                }
            }
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
    func closeAll() { allSessions.forEach { $0.close() } }
}
