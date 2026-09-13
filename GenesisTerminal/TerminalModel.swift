import SwiftUI

// MARK: - Session kinds (one icon per TUI + default terminal + settings)

/// Every TUI gets its own sidebar icon. Normal shells (not in any TUI) share
/// the default terminal icon.
enum SessionKind: String, CaseIterable, Hashable, Codable {
    case terminal
    case codex
    case claude
    case opencode
    case settings

    var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .codex: "codex"
        case .claude: "Claude"
        case .opencode: "OpenCode"
        case .settings: "Settings"
        }
    }

    /// Circle fill for the 32pt sidebar icon.
    var iconFill: Color {
        switch self {
        case .terminal: Color(white: 0.90)
        case .codex: Color(white: 0.08)
        case .claude: Color(red: 0.91, green: 0.52, blue: 0.16)
        case .opencode: Color(white: 0.55)
        case .settings: Color(white: 0.90)
        }
    }

    var iconFillDark: Color {
        switch self {
        case .terminal: Color(white: 0.22)
        case .codex: Color(white: 0.95)
        case .claude: Color(red: 0.91, green: 0.52, blue: 0.16)
        case .opencode: Color(white: 0.45)
        case .settings: Color(white: 0.22)
        }
    }
}

// MARK: - Session value (sidebar row = one session)

struct TerminalSession: Identifiable, Hashable {
    let id: UUID
    var kind: SessionKind
    var title: String
    var cwd: String
    var gitRef: String?

    init(id: UUID = UUID(), kind: SessionKind, title: String, cwd: String, gitRef: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.gitRef = gitRef
    }
}

// MARK: - Sidebar selection (sessions + pinned settings)

enum SidebarSelection: Hashable {
    case session(UUID)
    case settings
}

// MARK: - Model (dynamic sessions, starts with exactly 1 tab)

@MainActor
final class TerminalModel: ObservableObject {
    @Published var isSidebarVisible = true
    @Published var sidebarWidth = ShellMetrics.sidebarDefaultWidth
    @Published var sessions: [TerminalSession]
    @Published var buffers: [UUID: MockTerminalSession]
    @Published var selection: SidebarSelection
    @Published var searchText = ""

    private var history: [SidebarSelection]
    private var historyIndex = 0

    init() {
        let first = TerminalSession(
            kind: .terminal,
            title: "Local",
            cwd: "~/Lume",
            gitRef: "6ed58ac4"
        )
        self.sessions = [first]
        self.buffers = [first.id: MockTerminalSession(session: first)]
        self.selection = .session(first.id)
        self.history = [.session(first.id)]
    }

    // MARK: Derived

    var selectedSession: TerminalSession? {
        guard case .session(let id) = selection else { return nil }
        return sessions.first(where: { $0.id == id })
    }

    var isShowingSettings: Bool {
        selection == .settings
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }

    func buffer(for id: UUID) -> MockTerminalSession? {
        buffers[id]
    }

    var selectedBuffer: MockTerminalSession? {
        guard let session = selectedSession else { return nil }
        return buffers[session.id]
    }

    // MARK: Sidebar sizing (keeps at least 320pt for the detail area)

    func resizeSidebar(to proposedWidth: CGFloat, availableWidth: CGFloat) {
        let widthThatPreservesDetail = availableWidth - ShellMetrics.minimumDetailWidth
        let maximumWidth = min(
            ShellMetrics.sidebarMaximumWidth,
            max(ShellMetrics.sidebarMinimumWidth, widthThatPreservesDetail)
        )
        sidebarWidth = min(max(proposedWidth, ShellMetrics.sidebarMinimumWidth), maximumWidth)
    }

    // MARK: Selection + history

    func select(_ item: SidebarSelection) {
        guard item != selection else { return }
        // Guard against stale session ids.
        if case .session(let id) = item, !sessions.contains(where: { $0.id == id }) {
            return
        }
        if historyIndex + 1 < history.count {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        history.append(item)
        historyIndex = history.count - 1
        selection = item
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        selection = history[historyIndex]
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        selection = history[historyIndex]
    }

    // MARK: Sessions (mock phase)

    /// Adds a session. No UI button calls this yet (top-right button removed);
    /// used by tests and later by ⌘T / menu / PTY spawner.
    @discardableResult
    func addSession(kind: SessionKind, title: String, cwd: String, gitRef: String? = nil) -> TerminalSession {
        let session = TerminalSession(kind: kind, title: title, cwd: cwd, gitRef: gitRef)
        sessions.append(session)
        buffers[session.id] = MockTerminalSession(session: session)
        return session
    }

    func submit(command: String) {
        guard let session = selectedSession else { return }
        guard let current = sessions.first(where: { $0.id == session.id }),
              let buf = buffers[session.id] else { return }
        buf.submit(command, prompt: promptPrefix(for: current))
    }

    func clearCurrent() {
        selectedBuffer?.clear()
    }

    func promptPrefix(for session: TerminalSession) -> String {
        "ian@genesis \(session.cwd) % "
    }

    // MARK: Search (title + cwd + branch + kind)

    func filteredSessions() -> [TerminalSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.cwd.localizedCaseInsensitiveContains(query)
                || ($0.gitRef?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.kind.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    var isSettingsVisibleInFilter: Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return "settings".localizedCaseInsensitiveContains(query)
    }
}
