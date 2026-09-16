import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: TerminalModel
    @ObservedObject private var dragCoordinator = TabDragCoordinator.shared
    let width: CGFloat
    var closeTab: (UUID) -> Void
    @FocusState private var focusedTarget: SidebarFocusTarget?

    private var rowWidth: CGFloat { width - ShellMetrics.sidebarInset * 2 }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: ShellMetrics.sidebarRowSpacing) {
                ForEach(model.sidebarItems) { item in
                    SidebarItemRow(
                        model: model,
                        item: item,
                        width: rowWidth,
                        closeTab: closeTab
                    )
                    .focused($focusedTarget, equals: .item(item.id))
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                if let pin = dragCoordinator.pin, pin.windowID == model.id {
                    TabInsertionPin(width: rowWidth)
                        .offset(x: ShellMetrics.sidebarInset, y: TabInsertionGeometry.pinOffsetY(insertionIndex: pin.insertionIndex))
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
                .padding(.horizontal, ShellMetrics.sidebarInset)
                .frame(width: width)
                .padding(.top, 42)
                .padding(.bottom, 12)
                .focused($focusedTarget, equals: .search)
        }
        .scrollClipDisabled()
        .scrollEdgeEffectStyle(.hard, for: .vertical)
        .frame(width: width)
    }
}

private enum SidebarFocusTarget: Hashable {
    case search
    case item(UUID)
    case settings
}

private struct SidebarItemRow: View {
    @ObservedObject var model: TerminalModel
    let item: SidebarTabItem
    let width: CGFloat
    let closeTab: (UUID) -> Void

    var body: some View {
        if item.isPair,
           let leading = model.tab(id: item.members[0]),
           let trailing = model.tab(id: item.members[1]) {
            CombinedSidebarRow(
                windowID: model.id,
                listRowID: item.id,
                leading: leading,
                trailing: trailing,
                selectedID: model.selectedID,
                width: width,
                onSelect: { model.select($0) },
                onClose: closeTab,
                onSplitWithActive: { model.split(with: $0, on: .trailing) },
                onUnsplit: { model.unsplit(tabID: leading.id) }
            )
        } else if let session = model.tab(id: item.id) {
            SidebarRow(
                windowID: model.id,
                tabID: session.id,
                title: session.title,
                symbol: session.kind == .settings ? "gearshape.fill" : "terminal",
                isSelected: model.selectedID == session.id,
                width: width,
                help: "\(session.title) — \(session.directory)",
                onSelect: { model.select(session.id) },
                onClose: { closeTab(session.id) },
                splitWithActiveEnabled: model.selectedID != session.id,
                onSplitWithActive: { model.split(with: session.id, on: .trailing) },
                onUnsplit: model.split(containing: session.id) == nil ? nil : { model.unsplit(tabID: session.id) }
            )
        }
    }
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
    var splitWithActiveEnabled = false
    var onSplitWithActive: (() -> Void)?
    var onUnsplit: (() -> Void)?

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
                onHover: { isHovered = $0 },
                splitWithActiveEnabled: splitWithActiveEnabled,
                onSplitWithActive: onSplitWithActive,
                onUnsplit: onUnsplit
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

private struct CombinedSidebarRow: View {
    let windowID: UUID
    let listRowID: UUID
    let leading: TerminalSession
    let trailing: TerminalSession
    let selectedID: UUID?
    let width: CGFloat
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onSplitWithActive: (UUID) -> Void
    let onUnsplit: () -> Void

    @State private var hoveringLeading = false
    @State private var hoveringTrailing = false

    private var showsDivider: Bool {
        !hoveringLeading && !hoveringTrailing
            && selectedID != leading.id && selectedID != trailing.id
    }

    var body: some View {
        HStack(spacing: 0) {
            segment(
                session: leading,
                isFocused: selectedID == leading.id,
                isHovered: hoveringLeading,
                onHover: { hoveringLeading = $0 }
            )
            if showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 0.5)
                    .padding(.vertical, 6)
            }
            segment(
                session: trailing,
                isFocused: selectedID == trailing.id,
                isHovered: hoveringTrailing,
                onHover: { hoveringTrailing = $0 }
            )
        }
        .frame(height: ShellMetrics.sidebarRowHeight)
        .animation(.easeInOut(duration: 0.14), value: hoveringLeading)
        .animation(.easeInOut(duration: 0.14), value: hoveringTrailing)
        .animation(.easeInOut(duration: 0.16), value: selectedID)
        .frame(width: width)
        .help("\(leading.title) / \(trailing.title)")
    }

    private func segment(
        session: TerminalSession,
        isFocused: Bool,
        isHovered: Bool,
        onHover: @escaping (Bool) -> Void
    ) -> some View {
        Button {
            onSelect(session.id)
        } label: {
            HStack(spacing: 8) {
                SidebarTile(symbol: session.kind == .settings ? "gearshape.fill" : "terminal")
                Text(session.title)
                    .font(.system(size: 13, weight: isFocused ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(segmentBackground(isFocused: isFocused, isHovered: isHovered))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay {
            TabRowHitRepresentable(
                windowID: windowID,
                tabID: session.id,
                listRowID: listRowID,
                title: session.title,
                symbol: session.kind == .settings ? "gearshape.fill" : "terminal",
                onSelect: { onSelect(session.id) },
                onClose: { onClose(session.id) },
                onHover: onHover,
                splitWithActiveEnabled: false,
                onSplitWithActive: { onSplitWithActive(session.id) },
                onUnsplit: onUnsplit
            )
        }
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .accessibilityLabel(session.title)
    }

    private func segmentBackground(isFocused: Bool, isHovered: Bool) -> Color {
        if isFocused {
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
