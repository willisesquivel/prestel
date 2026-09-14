import AppKit
import SwiftTerm
import SwiftUI

@MainActor
final class GenesisTerminalView: SwiftTerm.TerminalView {
    func applyPreferences() {
        let stored = UserDefaults.standard.double(forKey: "terminalFontSize")
        font = .monospacedSystemFont(ofSize: stored == 0 ? 13 : min(32, max(9, stored)), weight: .regular)
        optionAsMetaKey = UserDefaults.standard.bool(forKey: "optionAsMeta")
        refreshColorsForCurrentAppearance()
        scrollerStyle = NSScroller.preferredScrollerStyle
        registerForDraggedTypes([.fileURL, .string])
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.removeObserver(self, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        notifications.addObserver(self, selector: #selector(accessibilityDisplayOptionsChanged),
                                  name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    isolated deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    /// Resolve colors in this view's appearance before SwiftTerm freezes their RGB
    /// values for rendering and terminal color queries (including background tabs).
    func refreshColorsForCurrentAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeForegroundColor = NSColor.textColor.usingColorSpace(.deviceRGB) ?? .textColor
            nativeBackgroundColor = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB) ?? .textBackgroundColor
            backgroundOpacity = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0
        }
    }
    @objc private func accessibilityDisplayOptionsChanged() { refreshColorsForCurrentAppearance() }
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
            if let window {
                // Remember the terminal as the window's default focus target so
                // AppKit focuses it when the window first becomes key. The
                // explicit makeFirstResponder below covers tab switches, when
                // the window is already key.
                window.initialFirstResponder = self
                if window.isKeyWindow {
                    window.makeFirstResponder(self)
                }
            }
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

struct TerminalSurface: View {
    @ObservedObject var model: TerminalModel
    var body: some View {
        if let surface = model.selectedTab?.surface {
            // No .id() here on purpose: the container must persist per window
            // so tab switches and cross-window MOVEs only swap which live
            // surface is pinned into it. Recreating the host per selection
            // lets speculative containers steal the shared surface and strand
            // it when SwiftUI discards them, blanking the terminal.
            TerminalDirectHost(surface: surface)
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
        // Never attach here: SwiftUI creates speculative hosts it may discard
        // without inserting. Stealing the shared live surface into one of them
        // orphans it and blanks the terminal. updateNSView always follows and
        // is the only place that may attach.
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        let didAttach = surface.superview !== container
        if didAttach, shouldAttach(to: container) {
            pin(surface, in: container)
        }
        // Only focus when the selected surface is newly attached (or nothing else
        // has focus). Focusing on every model update would pull focus out of the
        // sidebar search field.
        if let window = container.window {
            window.initialFirstResponder = surface
            if window.isKeyWindow,
               (didAttach || window.firstResponder === window) {
                window.makeFirstResponder(surface)
            }
        }
    }

    /// A windowless container may be speculative (never inserted). Pulling a
    /// live-in-window surface into one strands it when SwiftUI discards the
    /// container, leaving a blank terminal. Windowed containers always win;
    /// homeless surfaces, or ones stuck in a windowless container, attach anywhere.
    private func shouldAttach(to container: NSView) -> Bool {
        if container.window != nil { return true }
        return surface.superview?.window == nil
    }

    private func pin(_ surface: GenesisTerminalView, in container: NSView) {
        // The container persists across tab switches now (no .id()), so evict
        // the previously hosted surface. Otherwise every selected tab piles
        // on top and switching appears to do nothing.
        for subview in container.subviews where subview !== surface {
            subview.removeFromSuperview()
        }
        // The container is dedicated to the terminal surface, so drop only our
        // own stale edge constraints instead of accumulating a new set on
        // every switch. Anything SwiftUI owns is left alone.
        for constraint in container.constraints where constraint.firstItem is GenesisTerminalView || constraint.secondItem is GenesisTerminalView {
            constraint.isActive = false
        }
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
