import AppKit
import SwiftTerm
import SwiftUI

@MainActor
final class GenesisTerminalView: SwiftTerm.TerminalView {
    let scrollState = TerminalScrollState()
    func applyPreferences() {
        let stored = UserDefaults.standard.double(forKey: "terminalFontSize")
        font = .monospacedSystemFont(ofSize: stored == 0 ? 13 : min(32, max(9, stored)), weight: .regular)
        optionAsMetaKey = UserDefaults.standard.bool(forKey: "optionAsMeta")
        refreshColorsForCurrentAppearance()
        scrollerStyle = NSScroller.preferredScrollerStyle
        notifyUpdateChanges = true
        registerForDraggedTypes([.fileURL, .string])
    }
    /// Re-resolves dynamic system colors for the current effective appearance.
    ///
    /// `NSColor.textColor.withAlphaComponent(_)` (and `textBackgroundColor`
    /// with alpha) freezes to a static color resolved in whatever appearance
    /// was current at call time — verified: a 0.5-alpha textBackgroundColor
    /// stays white in DarkAqua, and textColor with alpha 1 stays black in
    /// DarkAqua. SwiftTerm's `backgroundOpacity` setter works exactly that
    /// way, so the frozen `terminal.foregroundColor/backgroundColor` RGBs and
    /// color caches must be refreshed every time the appearance changes.
    /// Without this the SwiftUI chrome (driven by `colorScheme`, which *does*
    /// update — the detail surface in your screenshot did flip to light)
    /// diverges from the terminal, leaving e.g. white dark-mode text on a
    /// light detail surface until relaunch.
    func refreshColorsForCurrentAppearance() {
        configureNativeColors()
        backgroundOpacity = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColorsForCurrentAppearance()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scrollerStyle = NSScroller.preferredScrollerStyle
        // Background tabs are detached (no window), so they never receive
        // viewDidChangeEffectiveAppearance. Refresh on re-attach so a tab
        // created in dark mode shows correct colors when selected in light.
        if window != nil {
            refreshColorsForCurrentAppearance()
        }
    }
    override func copy(_ sender: Any) {
        guard selectionActive else { return }
        super.copy(sender)
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        // The shell receives quoted input, with no trailing Return or command execution.
        let text = urls.map { ShellConfiguration.escapedPath($0.path) }.joined(separator: " ") + " "
        pasteText(text)
        window?.makeFirstResponder(self)
        return true
    }
}

@MainActor
final class TerminalScrollState: ObservableObject {
    @Published var scrollbackRows = 0
    @Published var fraction = 1.0
    func sync(_ surface: SwiftTerm.TerminalView) {
        let snapshot = surface.terminalStateSnapshot()
        let position = surface.scrollPosition
        let thumb = surface.scrollThumbsize
        let count: Int
        if thumb == 0 { count = 0 }
        else if position > 0 { count = Int((Double(snapshot.viewportRow) / position).rounded()) }
        else { count = max(scrollbackRows, Int(CGFloat(snapshot.dimensions.rows) / max(thumb, 0.001)) - snapshot.dimensions.rows) }
        if scrollbackRows != count { scrollbackRows = count }
        let normalized = count == 0 ? 1 : position
        if abs(fraction - normalized) > 0.0001 { fraction = normalized }
    }
}

struct TerminalSurface: View {
    @ObservedObject var model: TerminalModel
    var body: some View {
        if let surface = model.selectedTab?.surface {
            TerminalDirectHost(surface: surface)
                .id(model.selectedID)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }
}

/// The SwiftTerm view owns scrolling natively through its own NSScroller.
/// There is deliberately no SwiftUI ScrollView wrapper and no scroll-edge
/// effect here: wrapping the terminal in a second scroll container fought
/// the terminal's scroller and broke scrolling.
private struct TerminalDirectHost: NSViewRepresentable {
    let surface: GenesisTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        pin(surface, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if surface.superview !== container {
            pin(surface, in: container)
        }
        if let window = container.window, window.isKeyWindow {
            window.makeFirstResponder(surface)
        }
    }

    private func pin(_ surface: GenesisTerminalView, in container: NSView) {
        surface.removeFromSuperview()
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
