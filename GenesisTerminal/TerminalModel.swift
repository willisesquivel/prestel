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
    @Published private(set) var recentlyClosed: [TabDescriptor] = []
    private var history: [UUID] = []
    private var historyIndex = -1
    private var subscriptions: [UUID: AnyCancellable] = [:]

    init(directory: String = ShellConfiguration.defaultDirectory, restoration: WindowDescriptor? = nil) {
        id = restoration?.id ?? UUID()
        if let restoration, !restoration.tabs.isEmpty {
            sidebarVisible = restoration.sidebarVisible
            sidebarWidth = min(300, max(150, restoration.sidebarWidth))
            var seen = Set<UUID>()
            for descriptor in restoration.tabs where seen.insert(descriptor.id).inserted { append(descriptor) }
            select(restoration.selectedID ?? tabs[0].id)
            if selectedID == nil { select(tabs[0].id) }
        } else {
            append(TabDescriptor(directory: directory))
            select(tabs[0].id)
        }
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
    }

    /// Call only after the window controller has resolved close confirmation.
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        recentlyClosed.append(tabs[index].descriptor)
        recentlyClosed = Array(recentlyClosed.suffix(20))
        tabs[index].close()
        tabs.remove(at: index)
        subscriptions.removeValue(forKey: id)
        history.removeAll { $0 == id }
        historyIndex = min(historyIndex, history.count - 1)
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
        WindowDescriptor(id: id, tabs: tabs.map(\.descriptor), selectedID: selectedID,
                         sidebarVisible: sidebarVisible, sidebarWidth: sidebarWidth)
    }
    func resizeSidebar(to proposedWidth: CGFloat, availableWidth: CGFloat) {
        sidebarWidth = min(max(proposedWidth, 150), min(300, max(150, availableWidth - 320)))
    }
    func closeAll() { tabs.forEach { $0.close() } }
}
