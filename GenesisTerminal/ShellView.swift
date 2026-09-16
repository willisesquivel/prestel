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
    @Environment(\.colorScheme) private var colorScheme

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

            Group {
                if model.selectedTab?.kind == .settings {
                    GenesisSettingsView().safeAreaBar(edge: .top, spacing: 0) { TerminalToolbar(model: model) }
                } else {
                    VStack(spacing: 0) {
                        TerminalToolbar(model: model)
                        TerminalSurface(model: model)
                    }
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: ShellMetrics.detailCornerRadius, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: ShellMetrics.detailCornerRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.045 : 0.10),
                    lineWidth: 0.5
                )
        }
        .accessibilityLabel("\(model.selectedTab?.title ?? "Local") terminal")
    }
}
