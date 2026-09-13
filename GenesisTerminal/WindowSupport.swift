import AppKit
import SwiftUI

struct WindowGlassBackdrop: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = 0
        updateTint(of: view)
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.cornerRadius = 0
        updateTint(of: nsView)
    }

    private func updateTint(of view: NSGlassEffectView) {
        view.tintColor = colorScheme == .dark
            ? NSColor.black.withAlphaComponent(0.18)
            : NSColor.white.withAlphaComponent(0.12)
    }
}

// MARK: - Shell metrics
//
// Genesis chrome: glass backdrop, search capsule, sidebar rows, navigation
// capsule, traffic lights, inset detail surface. The baseline window is sized
// so a terminal fits while keeping at least 320pt for the detail area.

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
