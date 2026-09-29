import AppKit
import Combine
import SwiftUI

/// Host-side encoding for chords SwiftTerm cannot remap from Prestel
/// (`keyDown` is not overridable outside the SwiftTerm module).
///
/// Shell mode keeps readline/zsh bindings (ESC-b word jumps, Ctrl-A/E).
/// Application-keyboard mode (DECCKM or Kitty protocol) sends xterm/Kitty
/// modified-key sequences so TUIs see one Alt+Left, not ESC then `b`.
enum TerminalKeyIntercept {
    static func bytesToSend(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        applicationKeyboard: Bool
    ) -> [UInt8]? {
        let hasControl = flags.contains(.control)
        let hasOption = flags.contains(.option)
        let hasCommand = flags.contains(.command)
        let hasShift = flags.contains(.shift)
        let isArrow = keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126
        let isDelete = keyCode == 51 || keyCode == 117
        let isReturn = keyCode == 36 || keyCode == 76
        let isSpace = keyCode == 49

        if isArrow && hasCommand && !hasControl && !hasOption && !hasShift {
            switch keyCode {
            case 123: return [0x01]
            case 124: return [0x05]
            default: return nil
            }
        }

        if isArrow && !hasCommand && !hasShift && (hasOption != hasControl) {
            if applicationKeyboard {
                return modifiedArrow(keyCode, option: hasOption, control: hasControl)
            }
            switch keyCode {
            case 123: return [0x1b, 0x62]
            case 124: return [0x1b, 0x66]
            case 126: return [0x01]
            case 125: return [0x05]
            default: return nil
            }
        }

        if isDelete && hasCommand && !hasControl {
            return keyCode == 117 ? [0x0b] : [0x15]
        }
        if isDelete && hasOption && !hasCommand && !hasControl {
            return keyCode == 117 ? [0x1b, 0x64] : [0x1b, 0x7f]
        }

        // TUIs need the shift/alt modifier on Enter and Space. Without Kitty
        // encoding, AppKit delivers a plain CR or space and newline chords die.
        if applicationKeyboard, !hasCommand {
            if isReturn, hasShift, !hasOption, !hasControl {
                return Array("\u{1b}[13;2u".utf8)
            }
            if isReturn, hasOption, !hasShift, !hasControl {
                return Array("\u{1b}[13;3u".utf8)
            }
            if isReturn, hasControl, !hasShift, !hasOption {
                return Array("\u{1b}[13;5u".utf8)
            }
            if isSpace, hasShift, !hasOption, !hasControl {
                return Array("\u{1b}[32;2u".utf8)
            }
        }
        return nil
    }

    /// CSI 1;{1+alt*2+ctrl*4}{A,B,C,D} — xterm modified arrows.
    private static func modifiedArrow(_ keyCode: UInt16, option: Bool, control: Bool) -> [UInt8]? {
        let letter: UInt8
        switch keyCode {
        case 126: letter = 0x41
        case 125: letter = 0x42
        case 124: letter = 0x43
        case 123: letter = 0x44
        default: return nil
        }
        let modifier = 1 + (option ? 2 : 0) + (control ? 4 : 0)
        return [0x1b, 0x5b, 0x31, 0x3b, 0x30 + UInt8(modifier), letter]
    }
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: TerminalModel
    let review: CodeReviewModel
    private var hosting: NSHostingController<ShellView>!
    var onClose: ((UUID) -> Void)?
    private var updates: AnyCancellable?
    private var selectionUpdates: AnyCancellable?
    private var sidebarUpdates: AnyCancellable?
    private var reviewUpdates: AnyCancellable?
    private var directoryUpdates: AnyCancellable?
    private var pendingRefresh = false
    private var savedForQuit: WindowDescriptor?
    private var keyMonitor: Any?

    init(model: TerminalModel) {
        self.model = model
        self.review = CodeReviewModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 650),
                              styleMask: [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        hosting = NSHostingController(rootView: ShellView(
            model: model,
            review: review,
            closeTab: { [weak self] id in self?.requestCloseTab(id) },
            closeArchivedTab: { [weak self] id in self?.requestCloseArchivedTab(id) }
        ))
        // Put the entire SwiftUI hierarchy in the glass view's documented
        // content slot. Keeping the glass as a sibling backdrop lets AppKit
        // choose its z-order relative to transparent SwiftUI descendants,
        // which can expose a sharp strip of the window behind at the edge of
        // the titlebar on newer macOS releases.
        let root = WindowRootView(frame: .zero)
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let glass = ThemedGlassView(frame: root.bounds)
        glass.autoresizingMask = [.width, .height]
        root.addSubview(glass)
        hosting.view.frame = glass.bounds
        hosting.view.autoresizingMask = [.width, .height]
        glass.contentView = hosting.view
        glass.refreshTint()
        window.setContentSize(NSSize(width: 960, height: 650))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.minSize = NSSize(width: 760, height: 540)
        window.title = "Prestel"
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // Prestel draws its original fixed traffic lights in the SwiftUI shell.
        // Keep AppKit's duplicate controls out of the hit-test tree so there
        // is one stable, unambiguous control surface.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.identifier = .init("Prestel.\(model.id.uuidString)")
        window.isRestorable = true
        window.restorationClass = PrestelWindowRestoration.self
        updates = model.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }
        selectionUpdates = model.$selectedID.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
                self?.focusTerminal()
                self?.bindReviewDirectory()
                self?.syncReview(preserveFocus: true)
            }
        }
        sidebarUpdates = model.$sidebarVisible.dropFirst().sink { [weak self] visible in
            guard !visible, let self, let window = self.window,
                  window.firstResponder is SearchEditorTextView else { return }
            window.makeFirstResponder(self.model.selectedTab?.surface)
        }
        review.onRestoreTerminalFocus = { [weak self] in self?.focusTerminal() }
        bindReviewDirectory()
        syncReview(preserveFocus: true)
        // SwiftTerm's view methods are not overridable from here, so intercept the
        // requested Cmd/Ctrl/Option navigation combos before dispatch. The terminal
        // view itself stays first responder, keeping the focused caret visible.
        //
        // Return the interceptor result as-is. `self?.intercept(...) ?? event`
        // re-dispatches consumed keys: a nil "I handled this" result coalesces
        // back to the original event, so SwiftTerm also encodes it. TUIs then
        // see two movements (ESC-b plus Alt+Left, for example).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.interceptTerminalKeyDown(event)
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
        model.selectedTab?.start()
        let tab = model.selectedTab
        window?.title = "\(tab?.displayTitle ?? "Terminal") — Prestel"
        window?.invalidateRestorableState()
        AppDelegate.current?.commandRevision &+= 1
    }
    func focusTerminal() {
        focusTerminal(retries: 10)
    }

    /// Focuses the selected terminal, retrying briefly while the window is still
    /// becoming key or SwiftUI is still attaching the surface (app launch).
    /// Never steals focus from an active text field (sidebar search, Settings).
    private func focusTerminal(retries: Int) {
        guard let window, let surface = model.selectedTab?.surface else { return }
        // An NSText field editor means the user is typing in search/Settings.
        if window.firstResponder is NSText { return }
        if ReviewFocus.isProtected(window.firstResponder) { return }
        if window.isKeyWindow, surface.window === window {
            window.makeFirstResponder(surface)
            return
        }
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.focusTerminal(retries: retries - 1)
        }
    }

    /// Terminal zoom (Cmd+= / Cmd+-) is handled for this key window regardless
    /// of first responder so the chords never reach the shell. The window
    /// resizes to preserve the grid; chrome never scales. Navigation and
    /// deletion combos still require the terminal itself to be focused, so
    /// sidebar search and Settings fields keep their normal behavior.
    /// Returns nil when the event was handled (so AppKit does not also dispatch it).
    private func interceptTerminalKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.isKeyWindow else { return event }
        // Scale the terminal grid, never the window chrome. Handle this before
        // the first-responder check so Cmd+= / Cmd+- work from search too,
        // and so SwiftTerm never sees those chords as input.
        if let shortcut = TerminalFontSize.shortcut(for: event) {
            TerminalFontSize.perform(shortcut)
            return nil
        }
        guard let surface = model.selectedTab?.surface,
              window.firstResponder === surface else { return event }
        let flags = event.modifierFlags
        let hasControl = flags.contains(.control)
        let hasOption = flags.contains(.option)
        let hasCommand = flags.contains(.command)
        let hasShift = flags.contains(.shift)
        let code = event.keyCode
        let isArrow = code == 123 || code == 124 || code == 125 || code == 126

        // Cmd+Up/Down: scroll the history when there is scrollback. Alternate
        // screen TUIs have no thumb, so the event is left for SwiftTerm.
        if isArrow && hasCommand && !hasControl && !hasOption && !hasShift {
            switch code {
            case 126:
                if surface.scrollThumbsize != 0 {
                    surface.scroll(toPosition: 0)
                    return nil
                }
                return event
            case 125:
                if surface.scrollThumbsize != 0 {
                    surface.scroll(toPosition: 1)
                    return nil
                }
                return event
            default:
                break
            }
        }

        if let bytes = TerminalKeyIntercept.bytesToSend(
            keyCode: code,
            flags: flags,
            applicationKeyboard: surface.usesApplicationKeyboard
        ) {
            surface.send(bytes)
            return nil
        }
        return event
    }
    @objc func newTab(_ sender: Any?) { model.newTab() }
    @objc func closeTab(_ sender: Any?) { if let id = model.selectedID { requestCloseTab(id) } }
    func requestCloseTab(_ id: UUID) {
        if model.archived.contains(where: { $0.id == id }) {
            requestCloseArchivedTab(id)
            return
        }
        guard let tab = model.tabs.first(where: { $0.id == id }) else { return }
        if model.tabs.count == 1 { window?.performClose(nil); return }
        guard CloseConfirmation.confirm(tabs: tab.hasActiveJobs ? [tab] : [], action: "Close Tab") else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.closeTab(id)
        }
    }
    func requestCloseArchivedTab(_ id: UUID) {
        guard let tab = model.archived.first(where: { $0.id == id }) else { return }
        guard CloseConfirmation.confirm(tabs: tab.hasActiveJobs ? [tab] : [], action: "Close Tab") else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.closeArchivedTab(id)
        }
    }
    @objc func closeTerminalWindow(_ sender: Any?) { window?.performClose(sender) }
    @objc func nextTab(_ sender: Any?) { model.cycle(1) }
    @objc func previousTab(_ sender: Any?) { model.cycle(-1) }
    @objc func reopenClosedTab(_ sender: Any?) { model.reopenClosedTab() }
    @objc func clearScrollback(_ sender: Any?) { model.selectedTab?.surface?.clearScrollback() }
    @objc func showFind(_ sender: Any?) {
        guard model.selectedTab?.kind == .terminal else { return }
        model.find.show(on: model.selectedTab?.surface)
    }
    @objc func findNext(_ sender: Any?) { stepFind(forward: true) }
    @objc func findPrevious(_ sender: Any?) { stepFind(forward: false) }
    private func stepFind(forward: Bool) {
        guard model.selectedTab?.kind == .terminal else { return }
        guard model.find.isVisible else { return showFind(nil) }
        if forward { model.find.next() } else { model.find.previous() }
    }
    @objc func toggleSidebar(_ sender: Any?) {
        ShellPanelAnimation.run { model.sidebarVisible.toggle() }
    }
    @objc func toggleCodeReview(_ sender: Any?) {
        let opening = !model.reviewVisible
        ShellPanelAnimation.run { model.reviewVisible.toggle() }
        if !opening {
            syncReview(preserveFocus: true)
        }
        if opening, sender is NSMenuItem {
            review.onFocusReview?()
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(reopenClosedTab(_:)): return !model.recentlyClosed.isEmpty
        case #selector(nextTab(_:)), #selector(previousTab(_:)): return model.tabs.count > 1
        case #selector(clearScrollback(_:)), #selector(closeTab(_:)): return model.selectedTab != nil
        case #selector(toggleCodeReview(_:)):
            if model.reviewVisible { return true }
            return window != nil
        default: return true
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        CloseConfirmation.confirm(tabs: model.allSessions.filter(\.hasActiveJobs), action: "Close Window")
    }
    func windowWillClose(_ notification: Notification) {
        updates = nil
        selectionUpdates = nil
        sidebarUpdates = nil
        reviewUpdates = nil
        directoryUpdates = nil
        review.shutdown()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.closeAll()
        onClose?(model.id)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        AppDelegate.current?.commandRevision &+= 1
        focusTerminal()
    }
    func windowDidResignKey(_ notification: Notification) { AppDelegate.current?.commandRevision &+= 1 }
    func windowDidResize(_ notification: Notification) {
        window?.invalidateRestorableState()
    }
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let descriptor = savedForQuit ?? model.descriptor
        if let data = try? JSONEncoder().encode(descriptor) { state.encode(data as NSData, forKey: "Prestel.window") }
    }
    func preserveForQuit() { savedForQuit = model.descriptor }
    func windowDidMiniaturize(_ notification: Notification) {
        review.bind(visible: false, windowID: model.id, session: nil)
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        syncReview(preserveFocus: true)
    }
    private func bindReviewDirectory() {
        directoryUpdates = model.selectedTab?.$directory.removeDuplicates().sink { [weak self] _ in
            self?.syncReview(preserveFocus: true)
        }
    }
    private func syncReview(preserveFocus: Bool) {
        // Bind on the next turn so load-state publishes are not captured by
        // ShellPanelAnimation's withAnimation transaction. That freeze left
        // the first tab on "Loading repository changes…" until a later tab
        // change rebuilt the panel.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.review.bind(visible: self.model.reviewVisible, windowID: self.model.id, session: self.model.selectedTab)
            if !self.model.reviewVisible, !preserveFocus {
                self.focusTerminal()
            }
        }
    }
}

/// A flipped root gives the glass-hosted SwiftUI hierarchy the same top-left
/// origin that SwiftUI uses for its layout.
private final class WindowRootView: NSView {
    override var isFlipped: Bool { true }
    /// Terminal font zoom must snap, never glide. Keep hosting hierarchy
    /// geometry instant even if another animation context is in flight.
    override func animation(forKey key: NSAnimatablePropertyKey) -> Any? { nil }
}

@MainActor
final class PrestelWindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder, completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        guard let data = state.decodeObject(of: NSData.self, forKey: "Prestel.window") as Data?,
              let descriptor = try? JSONDecoder().decode(WindowDescriptor.self, from: data),
              let app = AppDelegate.current else { completionHandler(nil, nil); return }
        let controller = app.createWindow(restoration: descriptor, show: false)
        completionHandler(controller.window, nil)
    }
}


/// Window glass whose tint follows the view's own effective appearance.
/// Driving the tint from `effectiveAppearance` keeps AppKit glass in sync
/// with the SwiftUI chrome even if appearance invalidations race.
final class ThemedGlassView: NSGlassEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureGlass()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureGlass()
    }

    /// Terminal content (hosted inside this glass) must snap on font zoom,
    /// never scale/glide. Opt out of AppKit implicit animations permanently.
    override func animation(forKey key: NSAnimatablePropertyKey) -> Any? { nil }

    private func configureGlass() {
        style = .regular
        cornerRadius = 0
    }

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

// MARK: - Shell metrics
//
// Prestel chrome: glass backdrop, search capsule, sidebar rows, native window
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
    static let minimumSplitPaneWidth: CGFloat = 160
    static let detailInset: CGFloat = 10
    static let detailCornerRadius: CGFloat = 20
    static let splitCardGap: CGFloat = 8

    static let searchHeight: CGFloat = 30
    static let searchCornerRadius: CGFloat = 15
    static let searchTop: CGFloat = 42
    static let trafficExpandedTop: CGFloat = 16
    static let trafficExpandedLeft: CGFloat = 18
    static let trafficCollapsedTop: CGFloat = 31.5
    static let trafficCollapsedLeft: CGFloat = 24
    static let trafficLightDiameter: CGFloat = 12
    static let trafficLightSpacing: CGFloat = 8
    static let sidebarRowHeight: CGFloat = 28
    static let sidebarRowSpacing: CGFloat = 1
    static let sidebarGroupSpacing: CGFloat = 12
    static let sidebarInset: CGFloat = 12

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

    static let sidebarAnimationDuration: TimeInterval = 0.30

    static let reviewPreferredWidth: CGFloat = 420
    static let reviewMinimumWidth: CGFloat = 256
    static let reviewMaximumWidth: CGFloat = 720
    static let reviewDividerWidth: CGFloat = 1
    static let reviewToggleWidth: CGFloat = 40
}

struct TerminalToolbarHeader: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        HStack(spacing: 8) {
            SidebarTile(symbol: session.kind == .settings ? "gearshape.fill" : "terminal", size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
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
        guard session.kind != .settings else { return "Preferences" }
        let shell = URL(fileURLWithPath: ShellConfiguration.loginShell).lastPathComponent
        return "\(shell) — \(ShellConfiguration.displayDirectory(session.directory))"
    }
}

struct TerminalToolbar: View {
    @ObservedObject var model: TerminalModel
    var session: TerminalSession?
    var showsNavigation = true
    var showsReviewToggle = true

    var body: some View {
        HStack(spacing: 12) {
            if showsNavigation {
                NavigationCapsule(model: model)
            }
            if let headerSession = session ?? model.selectedTab {
                TerminalToolbarHeader(session: headerSession)
            }
            Spacer(minLength: 0)
            if showsReviewToggle {
                CodeReviewToggle(model: model)
            }
        }
        // Same horizontal inset as the terminal text below (12pt). When the
        // sidebar is collapsed the detail surface slides under the traffic
        // lights (24…76pt window), so the header shifts right to sit beside
        // them: mirror the 14pt gap between the surface edge and the lights,
        // starting the header at 80pt detail-relative.
        .padding(.leading, showsNavigation && !model.sidebarVisible ? 80 : 12)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal toolbar")
    }
}
