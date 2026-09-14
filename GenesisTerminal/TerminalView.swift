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
        let didAttach = surface.superview !== container
        if didAttach {
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
