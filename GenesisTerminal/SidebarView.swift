import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: TerminalModel
    let width: CGFloat
    var closeTab: (UUID) -> Void
    @FocusState private var focusedTarget: SidebarFocusTarget?

    var body: some View {
        VStack(spacing: 0) {
            // Search capsule sits below the native titlebar with the same top
            // clearance as before, so rows never slide under window controls.
            SidebarSearchField(text: $model.searchText)
                .frame(width: width - ShellMetrics.sidebarHorizontalInset * 2)
                .padding(.top, 42)
                .focused($focusedTarget, equals: .search)

            ScrollView(.vertical) {
                VStack(spacing: ShellMetrics.sidebarRowSpacing) {
                    ForEach(model.filteredTabs) { session in
                        SidebarRow(
                            title: session.title,
                            symbol: session.kind == .settings ? "gearshape.fill" : "terminal",
                            isSelected: model.selectedID == session.id,
                            width: width - ShellMetrics.sidebarHorizontalInset * 2,
                            help: "\(session.title) — \(session.directory)"
                        ) {
                            model.select(session.id)
                        }
                        .focused($focusedTarget, equals: .item(session.id))
                        .contextMenu { Button("Close Tab") { closeTab(session.id) } }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
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
    let title: String
    let symbol: String
    let isSelected: Bool
    let width: CGFloat
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
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
        .onHover { hovering in
            isHovered = hovering
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
