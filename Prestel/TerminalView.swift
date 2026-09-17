import AppKit
import QuartzCore
import SwiftTerm
import SwiftUI

/// Terminal text size only. Chrome (tabs, search, traffic lights, buttons)
/// stays at a fixed point size; the window resizes to preserve the PTY grid
/// so zooming never rewraps lines or shifts content. Instant, no animation.
@MainActor
enum TerminalFontSize {
    static let defaultsKey = "terminalFontSize"
    static let `default`: CGFloat = 13
    static let minimum: CGFloat = 9
    static let maximum: CGFloat = 32

    enum Shortcut {
        case increase, decrease, reset
    }

    static var current: CGFloat {
        let stored = UserDefaults.standard.double(forKey: defaultsKey)
        return clamp(stored == 0 ? `default` : CGFloat(stored))
    }

    static var canIncrease: Bool { current < maximum }
    static var canDecrease: Bool { current > minimum }
    static var isDefault: Bool { current == `default` }

    static func clamp(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite else { return `default` }
        return min(maximum, max(minimum, raw.rounded()))
    }

    static func font() -> NSFont {
        .monospacedSystemFont(ofSize: current, weight: .regular)
    }

    @discardableResult
    static func increase() -> CGFloat { set(current + 1) }

    @discardableResult
    static func decrease() -> CGFloat { set(current - 1) }

    @discardableResult
    static func reset() -> CGFloat { set(`default`) }

    @discardableResult
    static func set(_ value: CGFloat) -> CGFloat {
        withoutAnimations {
            let next = clamp(value)
            let previous = current
            UserDefaults.standard.set(Double(next), forKey: defaultsKey)
            if next != previous { applyToOpenTerminals() }
            return next
        }
    }

    static func applyToOpenTerminals() {
        withoutAnimations {
            for window in NSApp.windows {
                guard let controller = window.windowController as? TerminalWindowController else { continue }
                // Record the visible grid BEFORE changing the font. Split panes
                // only preserve the selected pane; the secondary may drift a
                // column (far better than reflowing both).
                let target = controller.model.selectedTab?.surface
                let oldCols = target.map { $0.terminalDimensions.cols }
                let oldRows = target.map { $0.terminalDimensions.rows }
                let oldFrame = window.frame
                let isSplit = controller.model.visibleSplit != nil
                controller.model.tabs.forEach { $0.surface?.applyPreferences() }
                // Grow/shrink the window so the same cols/rows fit at the new
                // cell size. No rewrap, no scroll jump, no movement. Instant:
                // animate:false inside the disabled transaction above.
                if !isSplit,
                   let surface = target, surface.window === window,
                   let cols = oldCols, let rows = oldRows, cols > 0, rows > 0,
                   let newCell = cellSize(of: surface) {
                    let reserve = scrollerReserve(for: surface)
                    // +1pt lands mid-interval so floor() can't slip a column
                    // on floating-point boundaries.
                    let wantSurfaceW = CGFloat(cols) * newCell.width + reserve + 1
                    let wantSurfaceH = CGFloat(rows) * newCell.height + 1
                    let dW = wantSurfaceW - surface.frame.width
                    let dH = wantSurfaceH - surface.frame.height
                    if abs(dW) >= 0.5 || abs(dH) >= 0.5 {
                        var frame = oldFrame
                        frame.size.width += dW
                        frame.size.height += dH
                        // Keep top-left anchored (grow right/down).
                        frame.origin.y -= dH
                        // Respect min size and screen.
                        frame.size.width = max(frame.size.width, window.minSize.width)
                        frame.size.height = max(frame.size.height, window.minSize.height)
                        if let screen = window.screen?.visibleFrame {
                            frame.size.width = min(frame.size.width, screen.width)
                            frame.size.height = min(frame.size.height, screen.height)
                            frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.size.width)
                            frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.size.height)
                        }
                        window.setFrame(frame, display: true, animate: false)
                    }
                }
            }
            AppDelegate.current?.commandRevision &+= 1
        }
    }

    /// Exact SwiftTerm cell size via reflection (public API exposes only
    /// cols/rows, not pixels). Falls back to nil → caller keeps fixed-window
    /// behavior rather than resizing wrong. String-based but safe: any
    /// SwiftTerm rename just disables window preservation, never crashes.
    private static func cellSize(of surface: PrestelView) -> CGSize? {
        var mirror: Mirror? = Mirror(reflecting: surface)
        while let m = mirror {
            if let child = m.children.first(where: { $0.label == "cellDimension" }) {
                // cellDimension is CellDimension! (aka Optional<CGSize>).
                // Unwrap optionals before reading width/height.
                var value: Any = child.value
                var vm = Mirror(reflecting: value)
                while vm.displayStyle == .optional {
                    guard let first = vm.children.first else { return nil }
                    value = first.value
                    vm = Mirror(reflecting: value)
                }
                var w: CGFloat?
                var h: CGFloat?
                for c in vm.children {
                    if c.label == "width" {
                        if let v = c.value as? CGFloat { w = v }
                        else if let v = c.value as? Double { w = CGFloat(v) }
                    }
                    if c.label == "height" {
                        if let v = c.value as? CGFloat { h = v }
                        else if let v = c.value as? Double { h = CGFloat(v) }
                    }
                }
                if let w, let h, w > 0, h > 0 { return CGSize(width: w, height: h) }
                return nil
            }
            mirror = m.superclassMirror
        }
        return nil
    }

    /// Width reserved for a legacy (non-overlay) scroller, which doesn't count
    /// toward columns. Overlay (the default) reserves nothing.
    private static func scrollerReserve(for surface: PrestelView) -> CGFloat {
        guard surface.scrollerStyle == .legacy else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    /// Font changes resize the caret and Metal layer. SwiftUI/AppKit will
    /// interpolate those frames unless both animation systems are frozen,
    /// which looks like a broken scale of the terminal contents.
    static func withoutAnimations<T>(_ body: () -> T) -> T {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        transaction.animation = nil
        return withTransaction(transaction) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setAnimationDuration(0)
            defer {
                CATransaction.commit()
                NSAnimationContext.endGrouping()
            }
            return body()
        }
    }

    /// Cmd+= / Cmd++ grow, Cmd+- shrinks, Cmd+0 restores the default.
    /// Numpad equivalents count too. Option/Control chords are left alone.
    static func shortcut(for event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option) else { return nil }
        switch event.keyCode {
        case 69: return .increase // keypad +
        case 78: return .decrease // keypad -
        case 82: return .reset    // keypad 0
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "=", "+": return .increase
        case "-", "_": return .decrease
        case "0": return .reset
        default: return nil
        }
    }

    static func perform(_ shortcut: Shortcut) {
        switch shortcut {
        case .increase: increase()
        case .decrease: decrease()
        case .reset: reset()
        }
    }
}

@MainActor
final class PrestelView: SwiftTerm.TerminalView {
    var onFocus: (() -> Void)?
    /// Unfocused split panes stay attached but must not steal first responder.
    var claimsFocus = true

    /// Permanently opt the terminal surface out of AppKit implicit animations.
    /// `withoutAnimations` freezes the transaction for the synchronous font
    /// change, but SwiftTerm's FrameDriver ticks mutate caret/Metal layers on
    /// later display-link turns, outside that scope. Returning nil here keeps
    /// any `animator()`-driven geometry on this view instant.
    override func animation(forKey key: NSAnimatablePropertyKey) -> Any? { nil }

    func applyPreferences() {
        TerminalFontSize.withoutAnimations {
            font = TerminalFontSize.font()
            optionAsMetaKey = UserDefaults.standard.bool(forKey: "optionAsMeta")
            refreshColorsForCurrentAppearance()
            scrollerStyle = NSScroller.preferredScrollerStyle
            registerForDraggedTypes([.fileURL, .string])
            let notifications = NSWorkspace.shared.notificationCenter
            notifications.removeObserver(self, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            notifications.addObserver(self, selector: #selector(accessibilityDisplayOptionsChanged),
                                      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
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

    /// Font zoom must snap, never glide. Pinning/attaching this container
    /// must stay instant even if a sidebar slide animation is in flight.
    override func animation(forKey key: NSAnimatablePropertyKey) -> Any? { nil }

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
