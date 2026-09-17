import AppKit
import SwiftTerm
import SwiftUI

@MainActor
final class PrestelView: SwiftTerm.TerminalView {
    var onFocus: (() -> Void)?
    /// Unfocused split panes stay attached but must not steal first responder.
    var claimsFocus = true

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
                // Remember the focused terminal as the window's default focus
                // target so AppKit focuses it when the window first becomes key.
                // Unfocused split panes stay attached without stealing responder.
                if claimsFocus {
                    window.initialFirstResponder = self
                    if window.isKeyWindow,
                       !(window.firstResponder is NSText),
                       !ReviewFocus.isProtected(window.firstResponder) {
                        window.makeFirstResponder(self)
                    }
                }
            }
        }
    }
    override func copy(_ sender: Any) {
        guard selectionActive else { return }
        super.copy(sender)
    }
    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
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
            TerminalDirectHost(surface: surface, isFocused: true) {
                if let id = model.selectedID { model.select(id) }
            }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }
}

struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    var isFocused: Bool
    var onFocus: () -> Void

    var body: some View {
        Group {
            if session.kind == .settings {
                PrestelSettingsView()
                    .simultaneousGesture(TapGesture().onEnded { onFocus() })
            } else if let surface = session.surface {
                TerminalDirectHost(surface: surface, isFocused: isFocused, onFocus: onFocus)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("\(session.title) terminal")
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }
}

/// The SwiftTerm view owns scrolling natively through its own NSScroller.
/// There is deliberately no SwiftUI ScrollView wrapper and no scroll-edge
/// effect here: wrapping the terminal in a second scroll container fought
/// the terminal's scroller and broke scrolling.
private struct TerminalDirectHost: NSViewRepresentable {
    let surface: PrestelView
    var isFocused: Bool
    var onFocus: () -> Void

    func makeNSView(context: Context) -> TerminalHostContainer {
        // Never attach here: SwiftUI creates speculative hosts it may discard
        // without inserting. Stealing the shared live surface into one of them
        // orphans it and blanks the terminal. Pinning happens only once the
        // container is in a real window.
        TerminalHostContainer()
    }

    func updateNSView(_ container: TerminalHostContainer, context: Context) {
        container.isFocused = isFocused
        container.onFocus = onFocus
        container.pin(surface)
    }
}

/// Hosts one `PrestelView`. Attachment waits until the container has a
/// window so speculative SwiftUI hosts cannot steal a live surface (GEN-46).
private final class TerminalHostContainer: NSView {
    var isFocused = true
    var onFocus: (() -> Void)?
    private var pending: PrestelView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    func pin(_ surface: PrestelView) {
        pending = surface
        surface.onFocus = onFocus
        surface.claimsFocus = isFocused
        attachIfNeeded()
    }

    private func attachIfNeeded() {
        guard window != nil, let surface = pending else { return }
        let alreadyHere = surface.superview === self
        if !alreadyHere {
            for subview in subviews where subview !== surface {
                subview.removeFromSuperview()
            }
            for constraint in constraints where constraint.firstItem is PrestelView || constraint.secondItem is PrestelView {
                constraint.isActive = false
            }
            surface.removeFromSuperview()
            surface.translatesAutoresizingMaskIntoConstraints = false
            addSubview(surface)
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: trailingAnchor),
                surface.topAnchor.constraint(equalTo: topAnchor),
                surface.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        applyFocus(to: surface, didAttach: !alreadyHere)
    }

    private func applyFocus(to surface: PrestelView, didAttach: Bool) {
        guard isFocused, let window else { return }
        window.initialFirstResponder = surface
        if window.isKeyWindow,
           (didAttach || window.firstResponder === window),
           !(window.firstResponder is NSText),
           !ReviewFocus.isProtected(window.firstResponder) {
            window.makeFirstResponder(surface)
        }
    }
}
