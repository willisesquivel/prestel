import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: TerminalModel
    @ObservedObject private var dragCoordinator = TabDragCoordinator.shared
    let width: CGFloat
    var closeTab: (UUID) -> Void
    @FocusState private var focusedTarget: SidebarFocusTarget?

    private var rowWidth: CGFloat { width - ShellMetrics.sidebarHorizontalInset * 2 }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: ShellMetrics.sidebarRowSpacing) {
                ForEach(model.filteredTabs) { session in
                    SidebarRow(
                        windowID: model.id,
                        tabID: session.id,
                        title: session.title,
                        symbol: session.kind == .settings ? "gearshape.fill" : "terminal",
                        isSelected: model.selectedID == session.id,
                        width: rowWidth,
                        help: "\(session.title) — \(session.directory)",
                        onSelect: { model.select(session.id) },
                        onClose: { closeTab(session.id) }
                    )
                    .focused($focusedTarget, equals: .item(session.id))
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                if let pin = dragCoordinator.pin, pin.windowID == model.id {
                    TabInsertionPin(width: rowWidth)
                        .offset(x: ShellMetrics.sidebarHorizontalInset, y: TabInsertionGeometry.pinOffsetY(insertionIndex: pin.insertionIndex))
                }
            }
            .background(TabListDropZone(windowID: model.id).frame(width: 0, height: 0))
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        // AppKit needs the native scroller to render the safe-area edge effect.
        .scrollIndicators(.automatic)
        .safeAreaBar(edge: .top, spacing: 0) {
            SidebarSearchField(text: $model.searchText)
                .frame(height: ShellMetrics.searchHeight)
                .padding(.horizontal, ShellMetrics.sidebarHorizontalInset)
                .frame(width: width)
                .padding(.top, 42)
                .focused($focusedTarget, equals: .search)
        }
        .scrollClipDisabled()
        .scrollEdgeEffectStyle(.soft, for: .top)
        .frame(width: width)
    }
}

private enum SidebarFocusTarget: Hashable {
    case search
    case item(UUID)
    case settings
}

// MARK: - Sidebar row (28pt, 20px rounded-square tile)

private struct SidebarRow: View {
    let windowID: UUID
    let tabID: UUID
    let title: String
    let symbol: String
    let isSelected: Bool
    let width: CGFloat
    let help: String
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                SidebarTile(symbol: symbol)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: ShellMetrics.sidebarRowHeight)
            .contentShape(
                .interaction,
                RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor)
        }
        .overlay {
            TabRowHitRepresentable(
                windowID: windowID,
                tabID: tabID,
                title: title,
                symbol: symbol,
                onSelect: onSelect,
                onClose: onClose,
                onHover: { isHovered = $0 }
            )
        }
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .animation(.easeInOut(duration: 0.16), value: isSelected)
        .frame(width: width)
        .contentShape(
            .focusEffect,
            RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(help)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.primary.opacity(0.16)
        }
        if isHovered {
            return Color.primary.opacity(0.075)
        }
        return .clear
    }
}

// MARK: - Uniform placeholder tile (rounded square)

/// Single generic tile shared by every tab — no per-TUI artwork.
struct SidebarTile: View {
    let symbol: String
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: 6 * (size / 20), style: .continuous)
            .fill(Color(white: 0.55).gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.monochrome)
            }
            .frame(width: size, height: size)
    }
}
