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

    init(
        id: UUID,
        tabs: [TabDescriptor],
        selectedID: UUID?,
        sidebarVisible: Bool,
        sidebarWidth: Double,
        reviewVisible: Bool = false,
        reviewWidth: Double = 420
    ) {
        self.id = id
        self.tabs = tabs
        self.selectedID = selectedID
        self.sidebarVisible = sidebarVisible
        self.sidebarWidth = sidebarWidth
        self.reviewVisible = reviewVisible
        self.reviewWidth = Self.clampedReviewWidth(reviewWidth)
    }

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
    }

    static func clampedReviewWidth(_ raw: Double) -> Double {
        guard raw.isFinite else { return 420 }
        return min(max(raw, 256), 720)
    }

    private enum CodingKeys: String, CodingKey {
        case id, tabs, selectedID, sidebarVisible, sidebarWidth, reviewVisible, reviewWidth
    }
}

/// A window owns its tabs. Filtering and view attachment never own process lifetime.
@MainActor
final class TerminalModel: ObservableObject {
    let id: UUID
    @Published private(set) var tabs: [TerminalSession] = []
    @Published private(set) var selectedID: UUID?
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
    var filteredTabs: [TerminalSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? tabs : tabs.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.directory.localizedCaseInsensitiveContains(query)
        }
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
        guard id != selectedID, tabs.contains(where: { $0.id == id }) else { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(id)
        if history.count > 100 { history.removeFirst() }
        historyIndex = history.count - 1
        selectedID = id
        // Show fresh cwd immediately when switching tabs instead of waiting
        // for the next poll or output.
        tabs.first { $0.id == id }?.refreshDirectoryFromProcess()
    }

    func cycle(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selectedID } ?? 0
        select(tabs[(index + offset % tabs.count + tabs.count) % tabs.count].id)
    }

    func navigate(_ offset: Int) {
        let target = historyIndex + offset
        guard history.indices.contains(target) else { return }
        historyIndex = target
        selectedID = history[target]
        selectedTab?.refreshDirectoryFromProcess()
    }

    /// Reorder by stable tab identity. `insertionIndex` is a canonical index in
    /// `tabs` (0...count) measured *before* the moving tab is removed. Moving
    /// downward therefore has to account for the hole left by the removal.
    func moveTab(_ id: UUID, to insertionIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        var destination = min(max(insertionIndex, 0), tabs.count)
        if destination == from || destination == from + 1 { return }
        let tab = tabs.remove(at: from)
        if from < destination { destination -= 1 }
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
    }

    /// Remove a tab from this window without terminating its process or recording recently-closed.
    @discardableResult
    func detachTab(_ id: UUID) -> TerminalSession? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        subscriptions.removeValue(forKey: id)
        let removedThroughCursor = history.prefix(historyIndex + 1).filter { $0 == id }.count
        history.removeAll { $0 == id }
        historyIndex -= removedThroughCursor
        if selectedID == id {
            selectedID = nil
            if !tabs.isEmpty { select(tabs[min(index, tabs.count - 1)].id) }
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
        recentlyClosed.append(tabs[index].descriptor)
        recentlyClosed = Array(recentlyClosed.suffix(20))
        tabs[index].close()
        tabs.remove(at: index)
        subscriptions.removeValue(forKey: id)
        // Preserve the cursor's position when entries before it disappear.
        let removedThroughCursor = history.prefix(historyIndex + 1).filter { $0 == id }.count
        history.removeAll { $0 == id }
        historyIndex -= removedThroughCursor
        if selectedID == id {
            selectedID = nil
            if !tabs.isEmpty { select(tabs[min(index, tabs.count - 1)].id) }
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
            reviewWidth: reviewWidth
        )
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
