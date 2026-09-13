import AppKit
import SwiftUI

struct ShellView: View {
    @ObservedObject var model: TerminalModel
    var closeTab: (UUID) -> Void = { _ in }
    @State private var sidebarResizeStartWidth: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let detailX = model.sidebarVisible
                ? model.sidebarWidth
                : ShellMetrics.detailInset
            let detailWidth = size.width - detailX - ShellMetrics.detailInset

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
                        value: model.sidebarVisible
                    )

                SidebarView(model: model, width: model.sidebarWidth, closeTab: closeTab)
                    .frame(height: size.height)
                    .offset(x: model.sidebarVisible ? 0 : -model.sidebarWidth)
                    .allowsHitTesting(model.sidebarVisible)
                    .accessibilityHidden(!model.sidebarVisible)
                    .animation(
                        .smooth(duration: ShellMetrics.sidebarAnimationDuration),
                        value: model.sidebarVisible
                    )

                if model.sidebarVisible {
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

            Group {
                if model.selectedTab?.kind == .settings { GenesisSettingsView().safeAreaBar(edge: .top, spacing: 0) { TerminalToolbar(model: model) } }
                else {
                    VStack(spacing: 0) {
                        TerminalToolbar(model: model)
                        TerminalSurface(model: model)
                    }
                }
            }
                .padding(.bottom, 10)
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
