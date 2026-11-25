import AppKit
import Combine
import SwiftUI

enum TabKind: String, Codable { case terminal, settings }

struct TabDescriptor: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: TabKind = .terminal
    var title = "Local"
    var directory: String = FileManager.default.homeDirectoryForCurrentUser.path
    /// User-facing sidebar name. Nil keeps the shell title.
    var customTitle: String? = nil
}

/// A space that is not on screen. The window's top-level tab fields hold the active one.
struct SpaceDescriptor: Codable, Equatable {
    var id: UUID
    var name: String
    var tabs: [TabDescriptor]
    var selectedID: UUID?
    var splits: [SplitState] = []
    var folders: [TabFolder] = []
    var settledTabs: [TabDescriptor] = []

    init(id: UUID, name: String, tabs: [TabDescriptor], selectedID: UUID?, splits: [SplitState] = [], folders: [TabFolder] = [], settledTabs: [TabDescriptor] = []) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.selectedID = selectedID
        self.splits = splits
        self.folders = folders
        self.settledTabs = settledTabs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tabs = try container.decode([TabDescriptor].self, forKey: .tabs)
        selectedID = try container.decodeIfPresent(UUID.self, forKey: .selectedID)
        splits = try container.decodeIfPresent([SplitState].self, forKey: .splits) ?? []
        folders = try container.decodeIfPresent([TabFolder].self, forKey: .folders) ?? []
        settledTabs = try container.decodeIfPresent([TabDescriptor].self, forKey: .settledTabs) ?? []
    }
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
    var activeSpaceID: UUID?
    var activeSpaceName: String?
    var activeSpaceIndex: Int
    var otherSpaces: [SpaceDescriptor]

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
        folders: [TabFolder] = [],
        activeSpaceID: UUID? = nil,
        activeSpaceName: String? = nil,
        activeSpaceIndex: Int = 0,
        otherSpaces: [SpaceDescriptor] = []
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
        self.activeSpaceID = activeSpaceID
        self.activeSpaceName = activeSpaceName
        self.activeSpaceIndex = activeSpaceIndex
        self.otherSpaces = otherSpaces
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
        activeSpaceID = try container.decodeIfPresent(UUID.self, forKey: .activeSpaceID)
        activeSpaceName = try container.decodeIfPresent(String.self, forKey: .activeSpaceName)
        activeSpaceIndex = try container.decodeIfPresent(Int.self, forKey: .activeSpaceIndex) ?? 0
        otherSpaces = try container.decodeIfPresent([SpaceDescriptor].self, forKey: .otherSpaces) ?? []
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
        try container.encodeIfPresent(activeSpaceID, forKey: .activeSpaceID)
        try container.encodeIfPresent(activeSpaceName, forKey: .activeSpaceName)
        try container.encode(activeSpaceIndex, forKey: .activeSpaceIndex)
        try container.encode(otherSpaces, forKey: .otherSpaces)
    }

    static func clampedReviewWidth(_ raw: Double) -> Double {
        guard raw.isFinite else { return 420 }
        return min(max(raw, 256), 720)
    }

    private enum CodingKeys: String, CodingKey {
        case id, tabs, archivedTabs, selectedID, sidebarVisible, sidebarWidth, reviewVisible, reviewWidth
        case splits, splitLeadingID, splitTrailingID, splitFraction, splitAxis, folders
        case activeSpaceID, activeSpaceName, activeSpaceIndex, otherSpaces
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
    @Published private(set) var settled: [TerminalSession] = []
    /// Every space in this window, in pill order. `tabs`, `splits`, `folders`
    /// and the selection belong to `activeSpaceID`; the rest wait in `parked`.
    @Published private(set) var spaces: [SpaceSummary] = []
    @Published private(set) var activeSpaceID = UUID()
    private var parked: [UUID: ParkedSpace] = [:]
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
        spaces = [SpaceSummary(id: activeSpaceID, name: Self.spaceName(number: 1))]
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
                settled.append(tab)
                observe(tab)
            }
            if let preferred = restoration.selectedID, settled.contains(where: { $0.id == preferred }) {
                openSettledTab(preferred)
            } else {
                select(restoration.selectedID ?? tabs[0].id)
                if selectedID == nil { select(tabs[0].id) }
            }
            restoreSplit(from: restoration)
            folders = SidebarOutline.sanitized(
                restoration.folders,
                tabIDs: Set(tabs.map(\.id)).union(settled.map(\.id))
            )
            restoreSpaces(from: restoration, seen: &seen)
        } else {
            append(TabDescriptor(directory: directory))
            select(tabs[0].id)
        }
    }

    /// Owns an existing live session. Does not spawn a replacement shell.
    init(adopting tab: TerminalSession) {
        self.id = UUID()
        spaces = [SpaceSummary(id: activeSpaceID, name: Self.spaceName(number: 1))]
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
        spaces = [SpaceSummary(id: activeSpaceID, name: Self.spaceName(number: 1))]
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
        tabs.first { $0.id == selectedID } ?? settled.first { $0.id == selectedID }
    }
    /// Every live session this window owns: the active space, parked spaces and the archive.
    var allSessions: [TerminalSession] {
        spaces.flatMap { sessions(inSpace: $0.id) }
    }
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
    var filteredSettled: [TerminalSession] {
        filtered(settled)
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
        guard let session = tabs.first(where: { $0.id == id }) else { return }
        if command {
            if selectedTabIDs.contains(id) {
                var remaining = selectedTabIDs
                remaining.remove(id)
                // Never empty the selection: something must stay highlighted.
                guard !remaining.isEmpty else { return }
                selectedTabIDs = remaining
                selectionAnchorID = id
                // Deselecting a tab that isn't on screen must not switch to it.
                // Deselecting the on-screen tab hands off to the nearest one
                // still selected so the terminal and highlight agree.
                guard id == selectedID else { return }
                let from = tabs.firstIndex { $0.id == id } ?? 0
                let next = tabs.enumerated()
                    .filter { remaining.contains($0.element.id) }
                    .min { abs($0.offset - from) < abs($1.offset - from) }?.element
                guard let next else { return }
                activate(next.id, session: next)
                return
            } else {
                selectedTabIDs.insert(id)
            }
            selectionAnchorID = id
        } else if shift,
                  let selectionAnchorID {
            // Range over the rows actually on screen, in display order, so
            // collapsed-folder and search-hidden tabs are never swept in.
            let visible = SidebarOutline.visibleTabOrder(in: sidebarSections)
            if let anchorIndex = visible.firstIndex(of: selectionAnchorID),
               let clickedIndex = visible.firstIndex(of: id) {
                selectedTabIDs = Set(visible[min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)])
            } else {
                selectedTabIDs = [id]
                self.selectionAnchorID = id
            }
        } else {
            selectedTabIDs = [id]
            selectionAnchorID = id
        }
        activate(id, session: session)
    }

    func openSettledTab(_ id: UUID) {
        guard let session = settled.first(where: { $0.id == id }) else { return }
        selectedTabIDs = [id]
        selectionAnchorID = id
        activate(id, session: session)
    }

    private func activate(_ id: UUID, session: TerminalSession) {
        reconcileSplit(selecting: id)
        session.clearAttention()
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
        guard let current = selectedID, current != tabID, tabs.contains(where: { $0.id == current }) else { return }
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
        tabs.first { $0.id == id } ?? settled.first { $0.id == id }
    }

    func cycle(_ offset: Int) {
        let order = SidebarOutline.tabOrder(in: sidebarSections)
        guard !order.isEmpty else { return }
        let index = order.firstIndex { $0 == selectedID } ?? 0
        let next = ((index + offset) % order.count + order.count) % order.count
        select(order[next])
    }

    /// Browser shortcuts use the full open-tab order, even during a search.
    func selectTab(number: Int) {
        guard (1...9).contains(number) else { return }
        let sections = SidebarOutline.sections(
            tabs: tabs, splits: splits, folders: folders, selectedID: selectedID, query: ""
        )
        let order = SidebarOutline.tabOrder(in: sections)
        let index = number == 9 ? order.count - 1 : number - 1
        guard order.indices.contains(index) else { return }
        select(order[index])
    }

    func navigate(_ offset: Int) {
        let target = historyIndex + offset
        guard history.indices.contains(target) else { return }
        historyIndex = target
        let id = history[target]
        reconcileSplit(selecting: id)
        selectedID = id
        selectedTabIDs = [id]
        selectionAnchorID = id
        selectedTab?.clearAttention()
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
        // A folder emptied by this move stays where it was, in front of the tab
        // that followed it, instead of following the tabs that left.
        var stayingPut: [(folder: UUID, successor: UUID?)] = []
        if assignsFolder {
            for folder in folders where !folder.tabIDs.isEmpty && folder.tabIDs.allSatisfy(movingIDs.contains) {
                let first = folder.tabIDs.compactMap { id in tabs.firstIndex(where: { $0.id == id }) }.min() ?? 0
                stayingPut.append((folder.id, tabs[first...].first { !movingIDs.contains($0.id) }?.id))
            }
        }
        Self.animateSidebar {
            tabs.removeAll { movingIDs.contains($0.id) }
            destination = min(max(destination, 0), tabs.count)
            tabs.insert(contentsOf: movingTabs, at: destination)
            if assignsFolder {
                setFolderMembership(Array(movingIDs), folderID: folderID)
                for stay in stayingPut {
                    guard let index = folders.firstIndex(where: { $0.id == stay.folder }),
                          folders[index].tabIDs.isEmpty else { continue }
                    folders[index].anchor = stay.successor.flatMap { id in tabs.firstIndex { $0.id == id } } ?? tabs.count
                }
            }
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
        closeEmptyActiveSpace()
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
        closeEmptyActiveSpace()
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
                activate(activeID, session: active)
            }
        }
    }

    /// Hide a live session from the sidebar without terminating its process.
    func settleTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if tabs.count == 1 { newTab() }
        guard let tab = detachTab(id) else { return }
        settled.append(tab)
        observe(tab)
    }

    func reopenTab(_ id: UUID) {
        guard let index = settled.firstIndex(where: { $0.id == id }) else { return }
        let tab = settled.remove(at: index)
        subscriptions.removeValue(forKey: id)
        adopt(tab, at: 0, selecting: true)
    }

    func reopenTabInAnySpace(_ id: UUID) {
        if settled.contains(where: { $0.id == id }) {
            reopenTab(id)
            return
        }
        guard let space = spaces.first(where: { self.parked[$0.id]?.settled.contains { $0.id == id } == true }) else { return }
        switchSpace(to: space.id)
        reopenTab(id)
    }

    func settledSession(id: UUID) -> TerminalSession? {
        settled.first { $0.id == id } ?? spaces.lazy.compactMap { self.parked[$0.id]?.settled.first { $0.id == id } }.first
    }

    func settleTabInAnySpace(_ id: UUID) {
        if tabs.contains(where: { $0.id == id }) {
            settleTab(id)
            return
        }
        guard let spaceID = spaces.first(where: { self.parked[$0.id]?.tabs.contains { $0.id == id } == true })?.id,
              var space = parked[spaceID],
              let index = space.tabs.firstIndex(where: { $0.id == id }),
              space.tabs.count > 1 else { return }
        objectWillChange.send()
        let tab = space.tabs.remove(at: index)
        space.settled.append(tab)
        space.splits.removeAll { $0.contains(id) }
        for folder in space.folders.indices {
            space.folders[folder].tabIDs.removeAll { $0 == id }
        }
        space.selectedTabIDs.remove(id)
        if space.selectedID == id {
            let replacement = space.tabs[min(index, space.tabs.count - 1)].id
            space.selectedID = replacement
            space.selectedTabIDs = [replacement]
        } else if space.selectedTabIDs.isEmpty, let selected = space.selectedID {
            space.selectedTabIDs = [selected]
        }
        parked[spaceID] = space
    }

    func closeSettledTab(_ id: UUID) {
        if let index = settled.firstIndex(where: { $0.id == id }) {
            let tab = settled[index]
            recentlyClosed.append(tab.descriptor)
            recentlyClosed = Array(recentlyClosed.suffix(20))
            tab.close()
            settled.remove(at: index)
            subscriptions.removeValue(forKey: id)
            selectedTabIDs.remove(id)
            if selectionAnchorID == id { selectionAnchorID = nil }
            let removedThroughCursor = history.prefix(historyIndex + 1).filter { $0 == id }.count
            history.removeAll { $0 == id }
            historyIndex -= removedThroughCursor
            if selectedID == id {
                selectedID = nil
                if let next = settled.indices.contains(index) ? settled[index] : settled.last {
                    openSettledTab(next.id)
                } else if let first = tabs.first {
                    select(first.id)
                }
            }
            return
        }
        guard let spaceID = spaces.first(where: { self.parked[$0.id]?.settled.contains { $0.id == id } == true })?.id,
              var space = parked[spaceID],
              let index = space.settled.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        let tab = space.settled.remove(at: index)
        recentlyClosed.append(tab.descriptor)
        recentlyClosed = Array(recentlyClosed.suffix(20))
        subscriptions.removeValue(forKey: id)
        tab.close()
        space.selectedTabIDs.remove(id)
        if space.selectedID == id {
            if let next = space.settled.indices.contains(index) ? space.settled[index] : space.settled.last {
                space.selectedID = next.id
                space.selectedTabIDs = [next.id]
            } else if let first = space.tabs.first {
                space.selectedID = first.id
                space.selectedTabIDs = [first.id]
            } else {
                space.selectedID = nil
            }
        }
        parked[spaceID] = space
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
        closeEmptyActiveSpace()
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
            splits: splits,
            archivedTabs: settled.map(\.descriptor),
            folders: normalizedFolders(),
            activeSpaceID: activeSpaceID,
            activeSpaceName: activeSpace.name,
            activeSpaceIndex: spaces.firstIndex { $0.id == activeSpaceID } ?? 0,
            otherSpaces: spaces.compactMap { space in
                parked[space.id].map { parkedSpace in
                    SpaceDescriptor(
                        id: space.id,
                        name: space.name,
                        tabs: parkedSpace.tabs.map(\.descriptor),
                        selectedID: parkedSpace.selectedID,
                        splits: parkedSpace.splits,
                        folders: parkedSpace.folders,
                        settledTabs: parkedSpace.settled.map(\.descriptor)
                    )
                }
            }
        )
    }

    private func restoreSplit(from restoration: WindowDescriptor) {
        splits = Self.validSplits(restoration.splits, tabIDs: Set(tabs.map(\.id)), selectedID: selectedID)
    }

    private static func validSplits(_ proposed: [SplitState], tabIDs: Set<UUID>, selectedID: UUID?) -> [SplitState] {
        var seen = Set<UUID>()
        return proposed.compactMap { split in
            guard split.leadingID != split.trailingID,
                  tabIDs.contains(split.leadingID),
                  tabIDs.contains(split.trailingID),
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
            probe: probe,
            splitPairs: splitPairMembersByRow()
        )
    }

    /// Sidebar double-click. Selects the tab and, when it is in a split, leaves only that tab on screen.
    func focusTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        select(id)
        if split(containing: id) != nil {
            unsplit(tabID: id)
        }
    }

    /// On-screen split rows, keyed by the row id (the leading tab).
    private func splitPairMembersByRow() -> [UUID: [UUID]] {
        var pairs: [UUID: [UUID]] = [:]
        for section in sidebarSections {
            switch section {
            case .loose(let item):
                if item.isPair { pairs[item.id] = item.members }
            case .folder(let group):
                for item in group.children where item.isPair {
                    pairs[item.id] = item.members
                }
            }
        }
        return pairs
    }

    func folderMoveTarget(visibleInsertion: Int) -> FolderMoveTarget {
        SidebarOutline.folderMoveTarget(visibleInsertion: visibleInsertion, sections: sidebarSections)
    }

    /// Top-level sidebar blocks in display order: loose items and whole folders.
    /// Ignores the search filter so a reorder never drops hidden tabs.
    private struct SidebarBlock {
        var id: UUID
        var tabIDs: [UUID]
        var isFolder: Bool
    }

    private func sidebarBlocks() -> [SidebarBlock] {
        let order = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })
        func ordered(_ ids: [UUID]) -> [UUID] {
            ids.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
        }
        let sections = SidebarOutline.sections(tabs: tabs, splits: splits, folders: folders, selectedID: nil, query: "")
        return sections.map { section in
            switch section {
            case .loose(let item):
                return SidebarBlock(id: item.id, tabIDs: ordered(item.members), isFolder: false)
            case .folder(let group):
                return SidebarBlock(id: group.id, tabIDs: group.children.flatMap { ordered($0.members) }, isFolder: true)
            }
        }
    }

    /// The blocks after lifting `folderID` and reinserting it in front of `unitID`
    /// (a loose item, one of its members, or a folder). Nil `unitID` moves it last.
    private func reordering(_ blocks: [SidebarBlock], moving folderID: UUID, before unitID: UUID?) -> [SidebarBlock]? {
        guard let from = blocks.firstIndex(where: { $0.id == folderID && $0.isFolder }) else { return nil }
        if let unitID, blocks[from].id == unitID || blocks[from].tabIDs.contains(unitID) { return blocks }
        var result = blocks
        let moving = result.remove(at: from)
        let destination = unitID.flatMap { id in
            result.firstIndex { $0.id == id || $0.tabIDs.contains(id) }
        } ?? result.count
        result.insert(moving, at: destination)
        return result
    }

    func folderMoveWouldChange(_ folderID: UUID, before unitID: UUID?) -> Bool {
        let current = sidebarBlocks()
        guard let moved = reordering(current, moving: folderID, before: unitID) else { return false }
        return moved.map(\.id) != current.map(\.id)
    }

    /// Reorders a folder, with all its tabs, as one block in front of `unitID`.
    /// The tab array is rewritten in display order so the block stays contiguous and
    /// split pairs stay adjacent; empty folders get anchors that keep their place.
    func moveFolder(_ folderID: UUID, before unitID: UUID?) {
        let current = sidebarBlocks()
        guard let moved = reordering(current, moving: folderID, before: unitID),
              moved.map(\.id) != current.map(\.id) else { return }
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var reordered: [TerminalSession] = []
        var anchors: [UUID: Int] = [:]
        var placed = Set<UUID>()
        for block in moved {
            if block.isFolder { anchors[block.id] = reordered.count }
            for id in block.tabIDs where placed.insert(id).inserted {
                if let tab = byID[id] { reordered.append(tab) }
            }
        }
        reordered.append(contentsOf: tabs.filter { !placed.contains($0.id) })
        let folderOrder = moved.filter(\.isFolder).map(\.id)
        Self.animateSidebar {
            tabs = reordered
            for index in folders.indices where folders[index].tabIDs.isEmpty {
                if let anchor = anchors[folders[index].id] { folders[index].anchor = anchor }
            }
            let rank = Dictionary(uniqueKeysWithValues: folderOrder.enumerated().map { ($1, $0) })
            folders.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        }
    }

    @discardableResult
    func makeFolder(containing tabID: UUID) -> TabFolder? {
        guard tabs.contains(where: { $0.id == tabID }) else { return nil }
        // A right-clicked tab inside a multi-selection brings the whole
        // selection (and split partners) along, in tab order.
        let members = orderedDraggedTabIDs(grabbed: tabID)
        let name = nextFolderName()
        let anchor = members.compactMap { id in tabs.firstIndex(where: { $0.id == id }) }.min() ?? tabs.count
        let folder = TabFolder(name: name, collapsed: false, tabIDs: members, anchor: anchor)
        Self.animateSidebar {
            detachFromFolders(members)
            folders.append(folder)
        }
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
        Self.animateSidebar { folders[index].collapsed.toggle() }
    }

    /// One curve for every sidebar structure change (folder toggle, moving
    /// tabs in or out of folders) so rows, siblings and backgrounds move together.
    static func animateSidebar(_ body: () -> Void) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduce ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.25), body)
    }

    func renameFolder(_ id: UUID, to proposed: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folders[index].name = String(trimmed.prefix(256))
    }

    func deleteFolder(_ id: UUID) {
        Self.animateRemoval { folders.removeAll { $0.id == id } }
    }

    /// A removed row goes at once and the rows after it close the gap on a spring.
    static func animateRemoval(_ body: () -> Void) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduce ? .easeOut(duration: 0.18) : .spring(response: 0.32, dampingFraction: 0.9), body)
    }

    /// Removes the folder, and with `closingTabs` also closes every tab in it. Call only
    /// after the window controller has resolved close confirmation.
    func closeFolder(_ id: UUID, closingTabs: Bool) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        deleteFolder(id)
        guard closingTabs else { return }
        let members = Set(folder.tabIDs)
        if tabs.allSatisfy({ members.contains($0.id) }) { newTab() }
        for member in folder.tabIDs { closeTab(member) }
    }

    func renameTab(_ id: UUID, to proposed: String) {
        allSessions.first { $0.id == id }?.setDisplayTitle(proposed)
    }

    func setFolderMembership(_ tabID: UUID, folderID: UUID?) {
        setFolderMembership([tabID], folderID: folderID)
    }

    func setFolderMembership(_ tabIDs: [UUID], folderID: UUID?) {
        let ids = expandedMoveIDs(tabIDs)
        Self.animateSidebar {
            detachFromFolders(Array(ids))
            guard let folderID, let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
            for tab in tabs where ids.contains(tab.id) && !folders[index].tabIDs.contains(tab.id) {
                folders[index].tabIDs.append(tab.id)
            }
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

    // MARK: Spaces

    private struct ParkedSpace {
        var tabs: [TerminalSession]
        var settled: [TerminalSession] = []
        var splits: [SplitState]
        var folders: [TabFolder]
        var selectedID: UUID?
        var selectedTabIDs: Set<UUID>
    }

    var activeSpace: SpaceSummary {
        spaces.first { $0.id == activeSpaceID } ?? SpaceSummary(id: activeSpaceID, name: Self.spaceName(number: 1))
    }

    static func spaceName(number: Int) -> String { "Space \(number)" }

    /// Open and settled sessions of one space.
    func sessions(inSpace id: UUID) -> [TerminalSession] {
        if id == activeSpaceID { return tabs + settled }
        guard let space = parked[id] else { return [] }
        return space.tabs + space.settled
    }

    private func restoreSpaces(from restoration: WindowDescriptor, seen: inout Set<UUID>) {
        if let restoredID = restoration.activeSpaceID { activeSpaceID = restoredID }
        let activeName = restoration.activeSpaceName.flatMap(Self.cleanedSpaceName) ?? Self.spaceName(number: 1)
        var order: [SpaceSummary] = []
        var knownSpaces = Set([activeSpaceID])
        for space in restoration.otherSpaces where knownSpaces.insert(space.id).inserted {
            let sessions = space.tabs.filter { seen.insert($0.id).inserted }.map(TerminalSession.init(descriptor:))
            guard !sessions.isEmpty else { continue }
            sessions.forEach(observe)
            let settledSessions = space.settledTabs.filter { seen.insert($0.id).inserted }.map(TerminalSession.init(descriptor:))
            settledSessions.forEach(observe)
            let openIDs = Set(sessions.map(\.id))
            let allIDs = openIDs.union(settledSessions.map(\.id))
            let selected = space.selectedID.flatMap { allIDs.contains($0) ? $0 : nil } ?? sessions[0].id
            parked[space.id] = ParkedSpace(
                tabs: sessions,
                settled: settledSessions,
                splits: Self.validSplits(space.splits, tabIDs: openIDs, selectedID: selected),
                folders: SidebarOutline.sanitized(space.folders, tabIDs: openIDs),
                selectedID: selected,
                selectedTabIDs: [selected]
            )
            order.append(SpaceSummary(id: space.id, name: Self.cleanedSpaceName(space.name) ?? Self.spaceName(number: order.count + 2)))
        }
        order.insert(SpaceSummary(id: activeSpaceID, name: activeName), at: min(max(restoration.activeSpaceIndex, 0), order.count))
        spaces = order
    }

    func switchSpace(to id: UUID) {
        guard id != activeSpaceID, let target = parked.removeValue(forKey: id) else { return }
        parked[activeSpaceID] = park()
        load(target, as: id)
    }

    func cycleSpace(_ offset: Int) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == activeSpaceID }) else { return }
        switchSpace(to: spaces[((index + offset) % spaces.count + spaces.count) % spaces.count].id)
    }

    /// Opens a space with one fresh tab, right after the current one, and shows it.
    @discardableResult
    func newSpace() -> UUID {
        let id = UUID()
        let index = (spaces.firstIndex { $0.id == activeSpaceID } ?? spaces.count - 1) + 1
        let used = Set(spaces.map(\.name))
        let number = (1...).first { !used.contains(Self.spaceName(number: $0)) } ?? spaces.count + 1
        parked[activeSpaceID] = park()
        spaces.insert(SpaceSummary(id: id, name: Self.spaceName(number: number)), at: index)
        let tab = TerminalSession(descriptor: TabDescriptor(directory: ShellConfiguration.defaultDirectory))
        observe(tab)
        load(ParkedSpace(tabs: [tab], splits: [], folders: [], selectedID: tab.id, selectedTabIDs: [tab.id]), as: id)
        return id
    }

    func renameSpace(_ id: UUID, to proposed: String) {
        guard let name = Self.cleanedSpaceName(proposed),
              let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = name
    }

    /// Call only after the window controller has resolved close confirmation.
    /// The last space never closes; closing it is closing the window.
    func closeSpace(_ id: UUID) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let closing: [TerminalSession]
        if id == activeSpaceID {
            let neighbor = spaces[index + 1 < spaces.count ? index + 1 : index - 1].id
            guard let target = parked.removeValue(forKey: neighbor) else { return }
            closing = tabs + settled
            load(target, as: neighbor)
        } else {
            closing = parked.removeValue(forKey: id).map { $0.tabs + $0.settled } ?? []
        }
        spaces.removeAll { $0.id == id }
        for session in closing {
            recentlyClosed.append(session.descriptor)
            subscriptions.removeValue(forKey: session.id)
            session.close()
        }
        recentlyClosed = Array(recentlyClosed.suffix(20))
    }

    /// Closes an open tab in whichever space holds it. Call only after the window
    /// controller has resolved close confirmation.
    func closeTabInAnySpace(_ id: UUID) {
        if tabs.contains(where: { $0.id == id }) {
            closeTab(id)
            return
        }
        guard let spaceID = spaces.first(where: { self.parked[$0.id]?.tabs.contains { $0.id == id } == true })?.id,
              var space = parked[spaceID],
              let index = space.tabs.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        let tab = space.tabs.remove(at: index)
        recentlyClosed.append(tab.descriptor)
        recentlyClosed = Array(recentlyClosed.suffix(20))
        subscriptions.removeValue(forKey: id)
        tab.close()
        space.splits.removeAll { $0.contains(id) }
        space.folders = SidebarOutline.sanitized(space.folders, tabIDs: Set(space.tabs.map(\.id)))
        space.selectedTabIDs.remove(id)
        if space.tabs.isEmpty, let newest = space.settled.popLast() {
            space.tabs = [newest]
        }
        guard !space.tabs.isEmpty else {
            parked[spaceID] = space
            closeSpace(spaceID)
            return
        }
        let remainingIDs = Set(space.tabs.map(\.id)).union(space.settled.map(\.id))
        if space.selectedID == id || space.selectedID.map({ !remainingIDs.contains($0) }) == true {
            space.selectedID = space.tabs[min(index, space.tabs.count - 1)].id
        }
        if space.selectedTabIDs.isEmpty, let selected = space.selectedID { space.selectedTabIDs = [selected] }
        parked[spaceID] = space
    }

    /// A space always holds an open tab. When its last one leaves, the newest settled
    /// tab reopens; with none settled, the space goes too.
    private func closeEmptyActiveSpace() {
        guard tabs.isEmpty else { return }
        if let newest = settled.last {
            reopenTab(newest.id)
        } else if spaces.count > 1 {
            closeSpace(activeSpaceID)
        }
    }

    private func park() -> ParkedSpace {
        ParkedSpace(tabs: tabs, settled: settled, splits: splits, folders: normalizedFolders(), selectedID: selectedID, selectedTabIDs: selectedTabIDs)
    }

    private func load(_ space: ParkedSpace, as id: UUID) {
        let ids = Set(space.tabs.map(\.id)).union(space.settled.map(\.id))
        let selected = space.selectedID.flatMap { ids.contains($0) ? $0 : nil } ?? space.tabs.first?.id
        activeSpaceID = id
        searchText = ""
        tabs = space.tabs
        settled = space.settled
        splits = space.splits
        folders = space.folders
        let kept = space.selectedTabIDs.intersection(ids)
        selectedTabIDs = kept.isEmpty ? Set(selected.map { [$0] } ?? []) : kept
        selectionAnchorID = selected
        history = selected.map { [$0] } ?? []
        historyIndex = history.isEmpty ? -1 : 0
        selectedID = selected
        if let session = selectedTab {
            reconcileSplit(selecting: session.id)
            session.clearAttention()
            session.refreshDirectoryFromProcess()
        }
    }

    private static func cleanedSpaceName(_ proposed: String) -> String? {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(64))
    }

    // MARK: Activity

    /// Sessions that want the user, newest first, across every space and the archive.
    var activity: [ActivityItem] {
        var spaceByTab: [UUID: SpaceSummary] = [:]
        if spaces.count > 1 {
            for space in spaces {
                for session in sessions(inSpace: space.id) { spaceByTab[session.id] = space }
            }
        }
        return allSessions.compactMap { session in
            session.attention.map { ActivityItem(session: session, attention: $0, space: spaceByTab[session.id]) }
        }
        .sorted { $0.attention.date > $1.attention.date }
    }

    func clearActivity() {
        allSessions.forEach { $0.clearAttention() }
    }

    /// The window came forward: whatever is on screen has now been seen.
    func acknowledgeVisibleTabs() {
        selectedTab?.clearAttention()
        if let selectedID, let partner = visibleSplit?.partner(of: selectedID) {
            tab(id: partner)?.clearAttention()
        }
    }

    func owns(_ id: UUID) -> Bool {
        allSessions.contains { $0.id == id }
    }

    /// Brings a tab on screen wherever it lives: another space or the archive.
    func reveal(_ id: UUID) {
        if let space = spaces.first(where: { space in
            space.id != activeSpaceID && sessions(inSpace: space.id).contains { $0.id == id }
        }) {
            switchSpace(to: space.id)
        }
        if settled.contains(where: { $0.id == id }) {
            openSettledTab(id)
        } else {
            select(id)
        }
    }

    /// Settled tabs of every space, newest settled first within each space.
    var settledBySpace: [(space: SpaceSummary, tabs: [TerminalSession])] {
        spaces.compactMap { space in
            let list = space.id == activeSpaceID ? settled : parked[space.id]?.settled ?? []
            return list.isEmpty ? nil : (space, list.reversed())
        }
    }

    /// Open tabs of every space, in sidebar order for the active one.
    var openTabsBySpace: [(space: SpaceSummary, tabs: [TerminalSession])] {
        spaces.compactMap { space in
            let list = space.id == activeSpaceID
                ? SidebarOutline.tabOrder(in: SidebarOutline.sections(tabs: tabs, splits: splits, folders: folders, selectedID: selectedID, query: "")).compactMap { id in tabs.first { $0.id == id } }
                : parked[space.id]?.tabs ?? []
            return list.isEmpty ? nil : (space, list)
        }
    }
}

struct SpaceSummary: Identifiable, Equatable {
    let id: UUID
    var name: String
}

struct ActivityItem: Identifiable {
    let session: TerminalSession
    let attention: SessionAttention
    /// Nil while the window has a single space.
    let space: SpaceSummary?
    var id: UUID { session.id }
}
