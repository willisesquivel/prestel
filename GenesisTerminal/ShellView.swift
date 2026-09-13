import AppKit
import SwiftUI

struct ShellView: View {
    @StateObject private var model = TerminalModel()
    @State private var sidebarResizeStartWidth: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let detailX = model.isSidebarVisible
                ? model.sidebarWidth
                : ShellMetrics.detailInset
            let detailWidth = size.width - detailX - ShellMetrics.detailInset
            let navCenterX = model.isSidebarVisible
                ? model.sidebarWidth + 14 + ShellMetrics.navigationWidth / 2
                : size.width - ShellMetrics.chromeTrailing - ShellMetrics.navigationWidth / 2

            ZStack(alignment: .topLeading) {
                WindowGlassBackdrop()
                    .ignoresSafeArea()

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
                        width: max(0, detailWidth),
                        height: max(0, size.height - ShellMetrics.detailInset * 2)
                    )
                    .offset(x: detailX, y: ShellMetrics.detailInset)
                    .animation(
                        .smooth(duration: ShellMetrics.sidebarAnimationDuration),
                        value: model.isSidebarVisible
                    )

                SidebarView(model: model, width: model.sidebarWidth)
                    .frame(height: size.height)
                    .offset(x: model.isSidebarVisible ? 0 : -model.sidebarWidth)
                    .allowsHitTesting(model.isSidebarVisible)
                    .accessibilityHidden(!model.isSidebarVisible)
                    .animation(
                        .smooth(duration: ShellMetrics.sidebarAnimationDuration),
                        value: model.isSidebarVisible
                    )

                if model.isSidebarVisible {
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
                    .offset(x: model.sidebarWidth - 5)
                    .accessibilityHidden(true)
                }

                ManualTrafficLights(sidebarVisible: model.isSidebarVisible)

                GlassEffectContainer(spacing: ShellMetrics.chromeGap) {
                    NavigationCapsule(model: model)
                        .position(
                            x: navCenterX,
                            y: ShellMetrics.chromeTop + ShellMetrics.navigationHeight / 2
                        )
                        .animation(
                            .smooth(duration: ShellMetrics.sidebarAnimationDuration),
                            value: model.isSidebarVisible
                        )
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.clear)
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
            .smooth(duration: ShellMetrics.sidebarAnimationDuration),
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
                        .strokeBorder(Color.black.opacity(0.13), lineWidth: 0.5)
                }
                .overlay {
                    if showsSymbol {
                        Image(systemName: symbol)
                            .font(.system(size: 5.5, weight: .black))
                            .foregroundStyle(Color.black.opacity(0.55))
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

private struct TerminalDetailSurface: View {
    @ObservedObject var model: TerminalModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ShellMetrics.detailCornerRadius, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.black.opacity(0.58)
                        : Color.white.opacity(0.34)
                )

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.025 : 0.13),
                    Color.white.opacity(colorScheme == .dark ? 0.008 : 0.035)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: ShellMetrics.detailCornerRadius, style: .continuous))

            TerminalView(model: model)
                .clipShape(RoundedRectangle(cornerRadius: ShellMetrics.detailCornerRadius, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: ShellMetrics.detailCornerRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.045 : 0.10),
                    lineWidth: 0.5
                )
        }
        .accessibilityLabel("\(model.selectedSession?.title ?? "Settings") terminal")
    }
}
