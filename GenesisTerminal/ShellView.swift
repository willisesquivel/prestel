import AppKit
import SwiftUI

struct ShellView: View {
    @ObservedObject var model: TerminalModel
    @ObservedObject var review: CodeReviewModel
    var closeTab: (UUID) -> Void = { _ in }
    @State private var sidebarResizeStartWidth: CGFloat?
    @State private var reviewResizeStartWidth: CGFloat?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let layout = ShellLayout.resolve(
                .init(
                    windowWidth: size.width,
                    sidebarVisible: model.sidebarVisible,
                    reviewVisible: model.reviewVisible,
                    preferredSidebarWidth: model.sidebarWidth,
                    preferredReviewWidth: model.reviewWidth
                )
            )
            let animation = reduceMotion ? nil : Animation.smooth(duration: ShellMetrics.sidebarAnimationDuration)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(
                        colorScheme == .dark
                            ? Color.black.opacity(0.20)
                            : Color.white.opacity(0.08)
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                TerminalDetailSurface(model: model)
                    .frame(
                        width: max(0, layout.detailWidth),
                        height: max(0, size.height - ShellMetrics.detailInset * 2)
                    )
                    .offset(x: layout.detailOriginX, y: ShellMetrics.detailInset)

                SidebarView(model: model, width: layout.restingSidebarWidth, closeTab: closeTab)
                    .frame(width: layout.restingSidebarWidth, height: size.height)
                    .offset(x: layout.showsSidebar ? 0 : -layout.restingSidebarWidth)
                    .allowsHitTesting(layout.showsSidebar)
                    .accessibilityHidden(!layout.showsSidebar)

                CodeReviewPanel(model: review)
                    .frame(width: layout.restingReviewWidth, height: size.height)
                    .offset(x: layout.showsReview ? layout.restingReviewOriginX : size.width)
                    .allowsHitTesting(layout.showsReview)
                    .accessibilityHidden(!layout.showsReview)

                if layout.showsSidebar {
                    SidebarResizeHandle(
                        height: size.height
                    ) { translation in
                        if sidebarResizeStartWidth == nil {
                            sidebarResizeStartWidth = model.sidebarWidth
                        }
                        model.resizeSidebar(
                            to: (sidebarResizeStartWidth ?? model.sidebarWidth) + translation,
                            availableWidth: size.width
                        )
                    } onEnded: {
                        sidebarResizeStartWidth = nil
                    }
                    .frame(width: 10, height: size.height)
                    .offset(x: layout.restingSidebarWidth - 5)
                    .accessibilityHidden(true)
                }

                if layout.showsReview {
                    ReviewResizeHandle(
                        height: size.height,
                        onChanged: { translation in
                            if reviewResizeStartWidth == nil {
                                reviewResizeStartWidth = model.reviewWidth
                            }
                            model.resizeReview(
                                to: (reviewResizeStartWidth ?? model.reviewWidth) + translation,
                                availableWidth: size.width
                            )
                        },
                        onEnded: { reviewResizeStartWidth = nil },
                        onReset: { model.resetReviewWidth() },
                        onIncrement: { delta in
                            model.resizeReview(to: model.reviewWidth + delta, availableWidth: size.width)
                        }
                    )
                    .frame(width: 10, height: size.height)
                    .offset(x: layout.restingReviewOriginX - 5)
                }

                ManualTrafficLights(sidebarVisible: model.sidebarVisible)
            }
            .animation(animation, value: model.sidebarVisible)
            .animation(animation, value: model.reviewVisible)
        }
        .ignoresSafeArea()
        .background(Color.clear)
        .onAppear {
            review.bind(visible: model.reviewVisible, windowID: model.id, session: model.selectedTab)
        }
        .onChange(of: model.reviewVisible) { _, visible in
            review.bind(visible: visible, windowID: model.id, session: model.selectedTab)
        }
        .onChange(of: model.selectedID) { _, _ in
            review.bind(visible: model.reviewVisible, windowID: model.id, session: model.selectedTab)
        }
        .onChange(of: model.selectedTab?.directory) { _, _ in
            review.bind(visible: model.reviewVisible, windowID: model.id, session: model.selectedTab)
        }
    }
}

/// Genesis's original traffic lights and their original sidebar transition.
private struct ManualTrafficLights: View {
    let sidebarVisible: Bool
    @State private var isHoveringGroup = false

    private var left: CGFloat {
        sidebarVisible
            ? ShellMetrics.trafficExpandedLeft
            : ShellMetrics.trafficCollapsedLeft
    }

    private var top: CGFloat {
        sidebarVisible
            ? ShellMetrics.trafficExpandedTop
            : ShellMetrics.trafficCollapsedTop
    }

    var body: some View {
        HStack(spacing: ShellMetrics.trafficLightSpacing) {
            TrafficLightButton(
                color: Color(red: 1.00, green: 0.37, blue: 0.34),
                symbol: "xmark",
                label: "Close",
                showsSymbol: isHoveringGroup
            ) {
                NSApp.keyWindow?.performClose(nil)
            }

            TrafficLightButton(
                color: Color(red: 1.00, green: 0.74, blue: 0.18),
                symbol: "minus",
                label: "Minimize",
                showsSymbol: isHoveringGroup
            ) {
                NSApp.keyWindow?.miniaturize(nil)
            }

            TrafficLightButton(
                color: Color(red: 0.16, green: 0.78, blue: 0.31),
                symbol: "plus",
                label: "Zoom",
                showsSymbol: isHoveringGroup
            ) {
                NSApp.keyWindow?.zoom(nil)
            }
        }
        .onHover { isHoveringGroup = $0 }
        .offset(x: left, y: top)
        .animation(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil
                : .smooth(duration: ShellMetrics.sidebarAnimationDuration),
            value: sidebarVisible
        )
    }
}

private struct TrafficLightButton: View {
    let color: Color
    let symbol: String
    let label: String
    let showsSymbol: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay {
                    Circle()
                        .strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5)
                }
                .overlay {
                    if showsSymbol {
                        Image(systemName: symbol)
                            .font(.system(size: 7.5, weight: .heavy))
                            .foregroundStyle(Color.black.opacity(0.5))
                    }
                }
                .frame(
                    width: ShellMetrics.trafficLightDiameter,
                    height: ShellMetrics.trafficLightDiameter
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(label)
    }
}

private struct SidebarResizeHandle: NSViewRepresentable {
    let height: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> SidebarResizeNSView {
        SidebarResizeNSView()
    }

    func updateNSView(_ nsView: SidebarResizeNSView, context: Context) {
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SidebarResizeNSView,
        context: Context
    ) -> CGSize? {
        CGSize(width: 10, height: height)
    }
}

private final class SidebarResizeNSView: NSView {
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?
    private var dragStartX: CGFloat?

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        onChanged?(event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        onEnded?()
    }
}

private struct TerminalDetailSurface: View {
    @ObservedObject var model: TerminalModel
    @ObservedObject private var dragCoordinator = TabDragCoordinator.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var splitResizeStartFraction: Double?

    var body: some View {
        Group {
            if let split = model.visibleSplit,
               let leading = model.tab(id: split.leadingID),
               let trailing = model.tab(id: split.trailingID) {
                splitCards(split: split, leading: leading, trailing: trailing)
            } else {
                DetailCard {
                    if model.selectedTab?.kind == .settings {
                        GenesisSettingsView().safeAreaBar(edge: .top, spacing: 0) { TerminalToolbar(model: model) }
                    } else {
                        VStack(spacing: 0) {
                            TerminalToolbar(model: model)
                            TerminalSurface(model: model)
                        }
                    }
                }
            }
        }
        .overlay {
            if let preview = dragCoordinator.splitPreview, preview.windowID == model.id, model.visibleSplit == nil {
                TabSplitDropOverlay(side: preview.side, axis: preview.side.axis)
                    .clipShape(RoundedRectangle(cornerRadius: ShellMetrics.detailCornerRadius, style: .continuous))
            }
        }
        .background {
            TabDetailDropZone(windowID: model.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel("\(model.selectedTab?.title ?? "Local") terminal")
    }

    @ViewBuilder
    private func splitCards(split: SplitState, leading: TerminalSession, trailing: TerminalSession) -> some View {
        GeometryReader { proxy in
            let extent = split.axis == .horizontal ? proxy.size.width : proxy.size.height
            let fraction = TabSplitGeometry.clampFraction(split.fraction, along: extent)
            let layout = SplitCardLayout.cards(
                in: proxy.size,
                axis: split.axis,
                fraction: fraction,
                gap: ShellMetrics.splitCardGap
            )
            ZStack(alignment: .topLeading) {
                paneCard(session: leading, isFocused: model.selectedID == leading.id, frame: layout.primary, split: split, isPrimary: true)
                paneCard(session: trailing, isFocused: model.selectedID == trailing.id, frame: layout.secondary, split: split, isPrimary: false)

                SplitResizeHandle(
                    axis: split.axis,
                    length: split.axis == .horizontal ? proxy.size.height : proxy.size.width,
                    onChanged: { translation in
                        if splitResizeStartFraction == nil {
                            splitResizeStartFraction = split.fraction
                        }
                        let span = split.axis == .horizontal ? proxy.size.width : proxy.size.height
                        model.resizeSplit(
                            to: (splitResizeStartFraction ?? split.fraction) + Double(translation / span),
                            along: span
                        )
                    },
                    onEnded: { splitResizeStartFraction = nil },
                    onReset: {
                        model.resizeSplit(to: 0.5, along: split.axis == .horizontal ? proxy.size.width : proxy.size.height)
                    }
                )
                .frame(
                    width: split.axis == .horizontal ? ShellMetrics.splitCardGap : proxy.size.width,
                    height: split.axis == .horizontal ? proxy.size.height : ShellMetrics.splitCardGap
                )
                .offset(
                    x: split.axis == .horizontal ? layout.primary.maxX : 0,
                    y: split.axis == .vertical ? layout.primary.maxY : 0
                )

                if let preview = dragCoordinator.splitPreview, preview.windowID == model.id {
                    TabSplitDropOverlay(
                        side: preview.side,
                        fraction: fraction,
                        axis: split.axis,
                        gap: ShellMetrics.splitCardGap
                    )
                }
            }
        }
    }

    private func paneCard(session: TerminalSession, isFocused: Bool, frame: CGRect, split: SplitState, isPrimary: Bool) -> some View {
        DetailCard(isFocused: isFocused) {
            VStack(spacing: 0) {
                TerminalToolbar(
                    model: model,
                    session: session,
                    showsNavigation: isPrimary,
                    showsReviewToggle: split.axis == .horizontal ? !isPrimary : isPrimary
                )
                TerminalPane(session: session, isFocused: isFocused) {
                    model.select(session.id)
                }
            }
        }
        .frame(width: max(0, frame.width), height: max(0, frame.height))
        .offset(x: frame.minX, y: frame.minY)
    }
}

private struct DetailCard<Content: View>: View {
    var isFocused = false
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ShellMetrics.detailCornerRadius, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.black.opacity(0.38)
                        : Color.white.opacity(0.16)
                )

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.025 : 0.06),
                    Color.white.opacity(colorScheme == .dark ? 0.008 : 0.022)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: ShellMetrics.detailCornerRadius, style: .continuous))

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: ShellMetrics.detailCornerRadius, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: ShellMetrics.detailCornerRadius, style: .continuous)
                .strokeBorder(
                    isFocused
                        ? Color.white.opacity(colorScheme == .dark ? 0.12 : 0.18)
                        : Color.white.opacity(colorScheme == .dark ? 0.045 : 0.10),
                    lineWidth: 0.5
                )
        }
    }
}

private struct SplitResizeHandle: NSViewRepresentable {
    let axis: SplitAxis
    let length: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> SplitResizeNSView {
        SplitResizeNSView()
    }

    func updateNSView(_ nsView: SplitResizeNSView, context: Context) {
        nsView.axis = axis
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
        nsView.onReset = onReset
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SplitResizeNSView,
        context: Context
    ) -> CGSize? {
        axis == .horizontal
            ? CGSize(width: ShellMetrics.splitCardGap, height: length)
            : CGSize(width: length, height: ShellMetrics.splitCardGap)
    }
}

private final class SplitResizeNSView: NSView {
    var axis: SplitAxis = .horizontal
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?
    var onReset: (() -> Void)?
    private var dragStart: CGFloat?

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            dragStart = nil
            return
        }
        dragStart = axis == .horizontal ? event.locationInWindow.x : event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        if axis == .horizontal {
            onChanged?(event.locationInWindow.x - dragStart)
        } else {
            onChanged?(dragStart - event.locationInWindow.y)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        onEnded?()
    }
}
