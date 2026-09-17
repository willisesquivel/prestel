import AppKit
import SwiftUI

enum SplitAxis: String, Codable, Equatable {
    case horizontal
    case vertical
}

enum SplitSide: String, Codable, Equatable {
    case leading
    case trailing
    case top
    case bottom

    var axis: SplitAxis {
        switch self {
        case .leading, .trailing: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    var isPrimary: Bool {
        self == .leading || self == .top
    }

    var opposite: SplitSide {
        switch self {
        case .leading: return .trailing
        case .trailing: return .leading
        case .top: return .bottom
        case .bottom: return .top
        }
    }
}

struct SplitState: Equatable, Codable {
    var leadingID: UUID
    var trailingID: UUID
    var fraction: Double
    var axis: SplitAxis
    var focusedID: UUID

    init(
        leadingID: UUID,
        trailingID: UUID,
        fraction: Double,
        focusedID: UUID,
        axis: SplitAxis = .horizontal
    ) {
        self.leadingID = leadingID
        self.trailingID = trailingID
        self.fraction = fraction
        self.focusedID = focusedID
        self.axis = axis
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leadingID = try container.decode(UUID.self, forKey: .leadingID)
        trailingID = try container.decode(UUID.self, forKey: .trailingID)
        fraction = try container.decode(Double.self, forKey: .fraction)
        axis = try container.decode(SplitAxis.self, forKey: .axis)
        focusedID = try container.decodeIfPresent(UUID.self, forKey: .focusedID) ?? leadingID
    }

    private enum CodingKeys: String, CodingKey {
        case leadingID, trailingID, fraction, axis, focusedID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(leadingID, forKey: .leadingID)
        try container.encode(trailingID, forKey: .trailingID)
        try container.encode(fraction, forKey: .fraction)
        try container.encode(axis, forKey: .axis)
        try container.encode(focusedID, forKey: .focusedID)
    }

    func contains(_ id: UUID) -> Bool {
        leadingID == id || trailingID == id
    }

    func partner(of id: UUID) -> UUID? {
        if leadingID == id { return trailingID }
        if trailingID == id { return leadingID }
        return nil
    }

    func id(on side: SplitSide) -> UUID {
        side.isPrimary ? leadingID : trailingID
    }
}

struct TabSplitPreview: Equatable {
    let windowID: UUID
    let side: SplitSide
}

/// One sidebar row. A split pair collapses to a single capsule with two members.
struct SidebarTabItem: Identifiable, Equatable {
    let id: UUID
    let members: [UUID]

    var isPair: Bool { members.count == 2 }
}

enum SidebarTabLayout {
    static func items(from tabs: [TerminalSession], splits: [SplitState]) -> [SidebarTabItem] {
        guard !splits.isEmpty else {
            return tabs.map { SidebarTabItem(id: $0.id, members: [$0.id]) }
        }
        var emittedPairs = Set<UUID>()
        var items: [SidebarTabItem] = []
        for tab in tabs {
            if let split = splits.first(where: { $0.contains(tab.id) }) {
                if emittedPairs.contains(split.leadingID) { continue }
                emittedPairs.insert(split.leadingID)
                let members = [split.leadingID, split.trailingID].filter { id in tabs.contains { $0.id == id } }
                if members.count == 2, let primary = members.first {
                    items.append(SidebarTabItem(id: primary, members: members))
                } else {
                    // Filtered view (or stale split): only one member is visible.
                    // Emit the visible tab as a singleton so search never hides matches.
                    items.append(SidebarTabItem(id: tab.id, members: [tab.id]))
                }
            } else {
                items.append(SidebarTabItem(id: tab.id, members: [tab.id]))
            }
        }
        return items
    }
}

enum TabDragDestination: Equatable {
    case list(TabDragPin)
    case split(TabSplitPreview)
    case windowNoOp(UUID)
}

struct SplitCardLayout: Equatable {
    var primary: CGRect
    var secondary: CGRect

    func frame(for side: SplitSide) -> CGRect {
        side.isPrimary ? primary : secondary
    }

    static func cards(
        in size: CGSize,
        axis: SplitAxis,
        fraction: Double,
        gap: CGFloat
    ) -> SplitCardLayout {
        let f = CGFloat(min(max(fraction, 0), 1))
        switch axis {
        case .horizontal:
            let inner = max(0, size.width - gap)
            let primaryWidth = inner * f
            return SplitCardLayout(
                primary: CGRect(x: 0, y: 0, width: primaryWidth, height: size.height),
                secondary: CGRect(x: primaryWidth + gap, y: 0, width: inner - primaryWidth, height: size.height)
            )
        case .vertical:
            let inner = max(0, size.height - gap)
            let primaryHeight = inner * f
            return SplitCardLayout(
                primary: CGRect(x: 0, y: 0, width: size.width, height: primaryHeight),
                secondary: CGRect(x: 0, y: primaryHeight + gap, width: size.width, height: inner - primaryHeight)
            )
        }
    }
}

/// Pure geometry for a 2-pane detail split. Screen space uses AppKit's bottom-left origin.
enum TabSplitGeometry {
    static let overlayInset: CGFloat = 2
    static let overlayCornerRadius: CGFloat = 16
    static let overlayStrokeWidth: CGFloat = 1

    static func clampFraction(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0.5 }
        return min(max(raw, 0.2), 0.8)
    }

    static func clampFraction(_ raw: Double, along extent: CGFloat) -> Double {
        let preferred = clampFraction(raw)
        let minPane = ShellMetrics.minimumSplitPaneWidth
        guard extent.isFinite, extent > minPane * 2 else { return 0.5 }
        let minFraction = Double(minPane / extent)
        let upper = min(0.8, 1 - minFraction)
        let lower = max(0.2, minFraction)
        guard lower < upper else { return 0.5 }
        return min(max(preferred, lower), upper)
    }

    /// Closest edge when unsplit (so vertical and horizontal drops both work).
    /// When already split, the pointer chooses a pane along the current axis.
    static func side(at point: CGPoint, in detail: CGRect, split: SplitState?) -> SplitSide? {
        guard detail.contains(point), detail.width > 1, detail.height > 1 else { return nil }
        if let split {
            let fraction = CGFloat(clampFraction(split.fraction))
            switch split.axis {
            case .horizontal:
                let divider = detail.minX + detail.width * fraction
                return point.x < divider ? .leading : .trailing
            case .vertical:
                let topMinY = detail.maxY - detail.height * fraction
                return point.y >= topMinY ? .top : .bottom
            }
        }
        let distances: [(SplitSide, CGFloat)] = [
            (.leading, (point.x - detail.minX) / detail.width),
            (.trailing, (detail.maxX - point.x) / detail.width),
            (.top, (detail.maxY - point.y) / detail.height),
            (.bottom, (point.y - detail.minY) / detail.height)
        ]
        return distances.min { $0.1 < $1.1 }?.0
    }

    static func isNoOp(
        movingID: UUID,
        side: SplitSide,
        selectedID: UUID?,
        split: SplitState?
    ) -> Bool {
        if let split, selectedID.map(split.contains) == true {
            let effective = side.axis == split.axis ? side : (side.isPrimary ? split.axis.primary : split.axis.secondary)
            return split.id(on: effective) == movingID
        }
        return movingID == selectedID
    }
}

private extension SplitAxis {
    var primary: SplitSide { self == .horizontal ? .leading : .top }
    var secondary: SplitSide { self == .horizontal ? .trailing : .bottom }
}

struct SplitPaneHighlight: View {
    var showsFill = true

    var body: some View {
        RoundedRectangle(cornerRadius: TabSplitGeometry.overlayCornerRadius, style: .continuous)
            .fill(showsFill ? Color.accentColor.opacity(0.16) : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: TabSplitGeometry.overlayCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.72), lineWidth: TabSplitGeometry.overlayStrokeWidth)
            }
            .padding(TabSplitGeometry.overlayInset)
    }
}

struct TabSplitDropOverlay: View {
    let side: SplitSide
    var fraction: Double = 0.5
    var axis: SplitAxis = .horizontal
    var gap: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let layout = SplitCardLayout.cards(
                in: proxy.size,
                axis: axis,
                fraction: fraction,
                gap: gap
            )
            let frame = layout.frame(for: side)
            SplitPaneHighlight()
                .frame(width: max(0, frame.width), height: max(0, frame.height), alignment: .center)
                .offset(x: frame.minX, y: frame.minY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct TabDetailDropZone: NSViewRepresentable {
    let windowID: UUID

    func makeNSView(context: Context) -> TabDetailDropZoneNSView {
        TabDetailDropZoneNSView(windowID: windowID)
    }

    func updateNSView(_ nsView: TabDetailDropZoneNSView, context: Context) {
        nsView.windowID = windowID
        TabDragCoordinator.shared.registerDetail(nsView)
    }
}

final class TabDetailDropZoneNSView: NSView {
    var windowID: UUID

    init(windowID: UUID) {
        self.windowID = windowID
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            TabDragCoordinator.shared.registerDetail(self)
        } else {
            TabDragCoordinator.shared.unregisterDetail(self)
        }
    }

    var detailScreenFrame: CGRect {
        guard let window, window.isVisible, !window.isMiniaturized, bounds.width > 1, bounds.height > 1 else {
            return .null
        }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}
