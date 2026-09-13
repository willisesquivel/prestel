import AppKit
import Combine
import SwiftUI

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: TerminalModel
    private var hosting: NSHostingController<ShellView>!
    var onClose: ((UUID) -> Void)?
    private var updates: AnyCancellable?
    private var selectionUpdates: AnyCancellable?
    private var pendingRefresh = false
    private var savedForQuit: WindowDescriptor?

    init(model: TerminalModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 650),
                              styleMask: [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        hosting = NSHostingController(rootView: ShellView(model: model, closeTab: { [weak self] id in self?.requestCloseTab(id) }))
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 960, height: 650))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.minSize = NSSize(width: 760, height: 540)
        window.title = "Genesis"
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.identifier = .init("Genesis.\(model.id.uuidString)")
        window.isRestorable = true
        window.restorationClass = GenesisWindowRestoration.self
        // Handmade 12pt traffic lights are drawn in the shell; hide the native set.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        updates = model.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }
        selectionUpdates = model.$selectedID.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh(); self?.focusTerminal() }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }
    private func scheduleRefresh() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRefresh = false
            self.refresh()
        }
    }
    func refresh() {
        for tab in model.tabs { tab.start() }
        let tab = model.selectedTab
        window?.title = "\(tab?.title ?? "Terminal") — Genesis"
        window?.invalidateRestorableState()
        AppDelegate.current?.commandRevision &+= 1
    }
    func focusTerminal() {
        guard window?.isKeyWindow == true, let surface = model.selectedTab?.surface else { return }
        window?.makeFirstResponder(surface)
    }
    @objc func newTab(_ sender: Any?) { model.newTab() }
    @objc func closeTab(_ sender: Any?) { if let id = model.selectedID { requestCloseTab(id) } }
    func requestCloseTab(_ id: UUID) {
        guard let tab = model.tabs.first(where: { $0.id == id }) else { return }
        if model.tabs.count == 1 { window?.performClose(nil); return }
        guard CloseConfirmation.confirm(tabs: tab.hasActiveJobs ? [tab] : [], action: "Close Tab") else { return }
        model.closeTab(id)
    }
    @objc func closeTerminalWindow(_ sender: Any?) { window?.performClose(sender) }
    @objc func nextTab(_ sender: Any?) { model.cycle(1) }
    @objc func previousTab(_ sender: Any?) { model.cycle(-1) }
    @objc func reopenClosedTab(_ sender: Any?) { model.reopenClosedTab() }
    @objc func clearScrollback(_ sender: Any?) { model.selectedTab?.surface?.clearScrollback() }
    @objc func toggleSidebar(_ sender: Any?) { model.sidebarVisible.toggle() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(reopenClosedTab(_:)): return !model.recentlyClosed.isEmpty
        case #selector(nextTab(_:)), #selector(previousTab(_:)): return model.tabs.count > 1
        case #selector(clearScrollback(_:)), #selector(closeTab(_:)): return model.selectedTab != nil
        default: return true
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        CloseConfirmation.confirm(tabs: model.tabs.filter(\.hasActiveJobs), action: "Close Window")
    }
    func windowWillClose(_ notification: Notification) {
        updates = nil
        selectionUpdates = nil
        model.closeAll()
        onClose?(model.id)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        AppDelegate.current?.commandRevision &+= 1
        if window?.firstResponder === window { focusTerminal() }
    }
    func windowDidResignKey(_ notification: Notification) { AppDelegate.current?.commandRevision &+= 1 }
    func windowDidResize(_ notification: Notification) {
        window?.invalidateRestorableState()
    }
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let descriptor = savedForQuit ?? model.descriptor
        if let data = try? JSONEncoder().encode(descriptor) { state.encode(data as NSData, forKey: "Genesis.window") }
    }
    func preserveForQuit() { savedForQuit = model.descriptor }


}

@MainActor
final class GenesisWindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder, completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        guard let data = state.decodeObject(of: NSData.self, forKey: "Genesis.window") as Data?,
              let descriptor = try? JSONDecoder().decode(WindowDescriptor.self, from: data),
              let app = AppDelegate.current else { completionHandler(nil, nil); return }
        let controller = app.createWindow(restoration: descriptor, show: false)
        completionHandler(controller.window, nil)
    }
}


/// Backdrop glass whose tint follows the view's own effective appearance,
/// not just the SwiftUI `colorScheme` environment. Both paths set the same
/// values: SwiftUI calls `updateNSView` on environment changes, AppKit calls
/// `viewDidChangeEffectiveAppearance` on the view itself. Driving the tint
/// from `effectiveAppearance` keeps the AppKit glass in sync with the
/// SwiftUI chrome even if the two invalidations race.
final class ThemedGlassView: NSGlassEffectView {
    func refreshTint() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tintColor = isDark
            ? NSColor.black.withAlphaComponent(0.18)
            : NSColor.white.withAlphaComponent(0.12)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTint()
    }
}

struct WindowGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> ThemedGlassView {
        let view = ThemedGlassView()
        view.style = .regular
        view.cornerRadius = 0
        view.refreshTint()
        return view
    }

    func updateNSView(_ nsView: ThemedGlassView, context: Context) {
        nsView.cornerRadius = 0
        nsView.refreshTint()
    }
}

// MARK: - Shell metrics
//
// Genesis chrome: glass backdrop, search capsule, sidebar rows, native window
// controls, inset detail surface. The baseline window is sized so a terminal
// fits while keeping at least 320pt for the detail area.

enum ShellMetrics {
    static let baselineWidth: CGFloat = 960
    static let baselineHeight: CGFloat = 650
    static let minimumWindowWidth: CGFloat = 760
    static let minimumWindowHeight: CGFloat = 540
    static let sidebarDefaultWidth: CGFloat = 172
    static let sidebarMinimumWidth: CGFloat = 150
    static let sidebarMaximumWidth: CGFloat = 300
    static let minimumDetailWidth: CGFloat = 320
    static let detailInset: CGFloat = 10
    static let detailCornerRadius: CGFloat = 20

    static let searchHeight: CGFloat = 30
    static let searchCornerRadius: CGFloat = 15
    static let sidebarRowHeight: CGFloat = 28
    static let sidebarRowSpacing: CGFloat = 1
    static let sidebarGroupSpacing: CGFloat = 12
    static let sidebarHorizontalInset: CGFloat = 10

    // Larger session-row metrics (reserved; sidebar rows currently use the
    // single-line row height above so every tab stays the same height).
    static let sessionRowHeight: CGFloat = 62
    static let sessionIconSize: CGFloat = 32
    static let sessionRowCornerRadius: CGFloat = 10
    static let sessionRowSpacing: CGFloat = 2

    static let navigationWidth: CGFloat = 92
    static let navigationHeight: CGFloat = 32
    static let chromeTop: CGFloat = 21.5
    static let chromeTrailing: CGFloat = 24
    static let chromeGap: CGFloat = 8
    static let syncWidth: CGFloat = 122

    static let trafficExpandedTop: CGFloat = 16
    static let trafficExpandedLeft: CGFloat = 18
    static let trafficCollapsedTop: CGFloat = 31.5
    static let trafficCollapsedLeft: CGFloat = 24
    static let trafficLightDiameter: CGFloat = 12
    static let trafficLightSpacing: CGFloat = 8

    static let sidebarAnimationDuration: TimeInterval = 0.30
}

struct TerminalToolbarHeader: View {
    @ObservedObject var model: TerminalModel
    var body: some View {
        HStack(spacing: 8) {
            SidebarTile(symbol: model.selectedTab?.kind == .settings ? "gearshape.fill" : "terminal", size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.selectedTab?.title ?? "Local")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Flexible width: takes all space up to the navigation capsule instead
        // of truncating at a fixed 185pt. fixedSize(vertical:) keeps the two
        // lines from being vertically clipped.
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var subtitle: String {
        guard model.selectedTab?.kind != .settings else { return "Preferences" }
        let shell = URL(fileURLWithPath: ShellConfiguration.loginShell).lastPathComponent
        let directory = model.selectedTab.map { ShellConfiguration.displayDirectory($0.directory) } ?? ""
        return "\(shell) — \(directory)"
    }
}

struct TerminalToolbar: View {
    @ObservedObject var model: TerminalModel
    var body: some View {
        HStack(spacing: 12) {
            TerminalToolbarHeader(model: model)
            Spacer(minLength: 0)
            NavigationCapsule(model: model)
        }
        // Same horizontal inset as the terminal text below (12pt). When the
        // sidebar is collapsed the detail surface slides under the traffic
        // lights (24…76pt window), so the header shifts right to sit beside
        // them: mirror the 14pt gap between the surface edge and the lights,
        // starting the header at 80pt detail-relative.
        .padding(.leading, model.sidebarVisible ? 12 : 80)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .animation(.smooth(duration: ShellMetrics.sidebarAnimationDuration), value: model.sidebarVisible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal toolbar")
    }
}
