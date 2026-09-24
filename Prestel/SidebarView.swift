import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: TerminalModel
    @ObservedObject private var dragCoordinator = TabDragCoordinator.shared
    let width: CGFloat
    var closeTab: (UUID) -> Void
    var closeArchivedTab: (UUID) -> Void = { _ in }
    @FocusState private var focusedTarget: SidebarFocusTarget?
    @State private var renaming: SidebarRenameTarget?

    private var rowWidth: CGFloat { width - ShellMetrics.sidebarInset * 2 }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: ShellMetrics.sidebarRowSpacing) {
                if model.showingArchive {
                    archivedList
                } else {
                    let sections = model.sidebarSections
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        switch section {
                        case .loose(let item):
                            SidebarItemRow(
                                model: model,
                                item: item,
                                previousItem: looseItem(at: index - 1, in: sections),
                                nextItem: looseItem(at: index + 1, in: sections),
                                width: rowWidth,
                                renaming: renaming,
                                closeTab: closeTab,
                                beginRename: beginRename,
                                commitRename: commitRename,
                                cancelRename: { renaming = nil }
                            )
                            .focused($focusedTarget, equals: .item(item.id))
                        case .folder(let group):
                            FolderSection(
                                model: model,
                                group: group,
                                width: rowWidth,
                                renaming: renaming,
                                closeTab: closeTab,
                                beginRename: beginRename,
                                commitRename: commitRename,
                                cancelRename: { renaming = nil }
                            )
                            .focused($focusedTarget, equals: .item(group.id))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                if !model.showingArchive, let pin = dragCoordinator.pin, pin.windowID == model.id {
                    TabInsertionPin(
                        width: rowWidth,
                        leadingIndent: pin.folderID == nil ? 0 : ShellMetrics.sidebarGroupSpacing
                    )
                    .offset(x: ShellMetrics.sidebarInset, y: TabInsertionGeometry.pinOffsetY(insertionIndex: pin.insertionIndex))
                }
            }
            .background {
                if !model.showingArchive {
                    TabListDropZone(windowID: model.id).frame(width: 0, height: 0)
                }
            }
            .padding(.top, ShellMetrics.sidebarInset)
            .padding(.bottom, ShellMetrics.sidebarInset)
        }
        // AppKit needs the native scroller to render the safe-area edge effect.
        .scrollIndicators(.automatic)
        .safeAreaBar(edge: .top, spacing: 0) {
            SidebarSearchField(text: $model.searchText)
                .frame(height: ShellMetrics.searchHeight)
                .padding(.horizontal, ShellMetrics.sidebarInset)
                .frame(width: width)
                .padding(.top, 42)
                .padding(.bottom, ShellMetrics.sidebarInset)
                .focused($focusedTarget, equals: .search)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            ArchivedSidebarButton(
                isSelected: model.showingArchive,
                width: rowWidth
            ) {
                model.showingArchive.toggle()
            }
            .padding(.horizontal, ShellMetrics.sidebarInset)
            .padding(.top, ShellMetrics.sidebarInset)
            .padding(.bottom, ShellMetrics.sidebarInset)
            .frame(width: width)
            .focused($focusedTarget, equals: .archived)
        }
        .scrollClipDisabled()
        .scrollEdgeEffectStyle(.hard, for: .vertical)
        .frame(width: width)
    }

    private func looseItem(at index: Int, in sections: [SidebarSection]) -> SidebarTabItem? {
        guard sections.indices.contains(index), case .loose(let item) = sections[index] else { return nil }
        return item
    }

    @ViewBuilder
    private var archivedList: some View {
        let items = model.filteredArchived
        if items.isEmpty {
            Text(model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "No archived tabs"
                 : "No matching tabs")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .containerRelativeFrame(.vertical)
        } else {
            ForEach(items) { session in
                ArchivedTabRow(
                    session: session,
                    isSelected: model.selectedID == session.id,
                    width: rowWidth,
                    isRenaming: renaming == .tab(session.id),
                    onSelect: { model.select(session.id) },
                    onUnarchive: { model.unarchiveTab(session.id) },
                    onClose: { closeArchivedTab(session.id) },
                    onBeginRename: { beginRename(.tab(session.id)) },
                    onCommitRename: { commitRename(.tab(session.id), $0) },
                    onCancelRename: { renaming = nil }
                )
                .focused($focusedTarget, equals: .item(session.id))
            }
        }
    }

    private func beginRename(_ target: SidebarRenameTarget) {
        if case .folder(let id) = target,
           model.folders.first(where: { $0.id == id })?.collapsed == true {
            model.toggleFolder(id)
        }
        focusedTarget = nil
        renaming = target
    }

    private func commitRename(_ target: SidebarRenameTarget, _ proposed: String) {
        switch target {
        case .tab(let id):
            model.renameTab(id, to: proposed)
        case .folder(let id):
            model.renameFolder(id, to: proposed)
        }
        renaming = nil
    }
}

private enum SidebarFocusTarget: Hashable {
    case search
    case item(UUID)
    case archived
    case settings
}

private enum SidebarRenameTarget: Hashable {
    case tab(UUID)
    case folder(UUID)
}

private struct FolderSection: View {
    @ObservedObject var model: TerminalModel
    let group: SidebarFolderGroup
    let width: CGFloat
    let renaming: SidebarRenameTarget?
    let closeTab: (UUID) -> Void
    let beginRename: (SidebarRenameTarget) -> Void
    let commitRename: (SidebarRenameTarget, String) -> Void
    let cancelRename: () -> Void
    @State private var open: Bool

    init(
        model: TerminalModel,
        group: SidebarFolderGroup,
        width: CGFloat,
        renaming: SidebarRenameTarget?,
        closeTab: @escaping (UUID) -> Void,
        beginRename: @escaping (SidebarRenameTarget) -> Void,
        commitRename: @escaping (SidebarRenameTarget, String) -> Void,
        cancelRename: @escaping () -> Void
    ) {
        self.model = model
        self.group = group
        self.width = width
        self.renaming = renaming
        self.closeTab = closeTab
        self.beginRename = beginRename
        self.commitRename = commitRename
        self.cancelRename = cancelRename
        _open = State(initialValue: group.showsChildren)
    }

    /// Header gap plus one 28pt row per child. `open` is local so the height can interpolate.
    private var rowsHeight: CGFloat {
        let count = CGFloat(group.children.count)
        guard open, count > 0 else { return 0 }
        let gap = ShellMetrics.sidebarRowSpacing
        return gap + count * ShellMetrics.sidebarRowHeight + (count - 1) * gap
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            FolderSidebarRow(
                windowID: model.id,
                folder: group.folder,
                isActive: group.active,
                width: width,
                isRenaming: renaming == .folder(group.folder.id),
                onToggle: { model.toggleFolder(group.folder.id) },
                onBeginRename: { beginRename(.folder(group.folder.id)) },
                onCommitRename: { commitRename(.folder(group.folder.id), $0) },
                onCancelRename: cancelRename,
                onDelete: { model.deleteFolder(group.folder.id) }
            )
            VStack(alignment: .trailing, spacing: ShellMetrics.sidebarRowSpacing) {
                ForEach(Array(group.children.enumerated()), id: \.element.id) { index, item in
                    SidebarItemRow(
                        model: model,
                        item: item,
                        previousItem: index > 0 ? group.children[index - 1] : nil,
                        nextItem: index + 1 < group.children.count ? group.children[index + 1] : nil,
                        width: width - 12,
                        acceptsPointer: group.showsChildren,
                        renaming: renaming,
                        closeTab: closeTab,
                        beginRename: beginRename,
                        commitRename: commitRename,
                        cancelRename: cancelRename
                    )
                }
            }
            .padding(.top, open && !group.children.isEmpty ? ShellMetrics.sidebarRowSpacing : 0)
            .frame(height: rowsHeight, alignment: .top)
            .clipped()
            .opacity(open ? 1 : 0)
            .allowsHitTesting(group.showsChildren)
        }
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .opacity(open ? 1 : 0)
        }
        .onChange(of: group.showsChildren) { _, show in
            withAnimation(.easeInOut(duration: 0.25)) {
                open = show
            }
        }
        .frame(width: width, alignment: .trailing)
    }
}

private struct SidebarItemRow: View {
    @ObservedObject var model: TerminalModel
    let item: SidebarTabItem
    var previousItem: SidebarTabItem?
    var nextItem: SidebarTabItem?
    let width: CGFloat
    var acceptsPointer = true
    let renaming: SidebarRenameTarget?
    let closeTab: (UUID) -> Void
    let beginRename: (SidebarRenameTarget) -> Void
    let commitRename: (SidebarRenameTarget, String) -> Void
    let cancelRename: () -> Void

    var body: some View {
        row
            .background {
                SidebarSelectionChrome(
                    item: item,
                    previousItem: previousItem,
                    nextItem: nextItem,
                    selectedTabIDs: model.selectedTabIDs
                )
            }
            .animation(.easeInOut(duration: 0.16), value: model.selectedTabIDs)
    }

    @ViewBuilder
    private var row: some View {
        if item.isPair,
           let leading = model.tab(id: item.members[0]),
           let trailing = model.tab(id: item.members[1]) {
            CombinedSidebarRow(
                windowID: model.id,
                listRowID: item.id,
                leading: leading,
                trailing: trailing,
                selectedTabIDs: model.selectedTabIDs,
                width: width,
                acceptsPointer: acceptsPointer,
                renaming: renaming,
                onSelect: { model.select($0) },
                onModifiedSelect: { id, shift, command in
                    model.select(id, shift: shift, command: command)
                },
                onPrepareDrag: { model.prepareSelectionForDrag($0) },
                onClose: closeTab,
                onSplitWithActive: { model.split(with: $0, on: .trailing) },
                onUnsplit: { model.unsplit(tabID: leading.id) },
                onArchive: { model.archiveTab($0) },
                onBeginRename: { beginRename(.tab($0)) },
                onCommitRename: { commitRename(.tab($0), $1) },
                onCancelRename: cancelRename,
                onNewFolder: { _ = model.makeFolder(containing: $0) },
                onRemoveFromFolder: model.folderContaining(leading.id) == nil ? nil : { model.removeFromFolder($0) },
                folderDestinations: folderDestinations(for: leading.id)
            )
        } else if let session = model.tab(id: item.id) {
            SidebarRow(
                windowID: model.id,
                tabID: session.id,
                title: session.displayTitle,
                symbol: session.kind == .settings ? "gearshape.fill" : "terminal",
                isSelected: model.selectedTabIDs.contains(session.id),
                width: width,
                acceptsPointer: acceptsPointer,
                help: "\(session.displayTitle) — \(session.directory)",
                isRenaming: renaming == .tab(session.id),
                onSelect: { model.select(session.id) },
                onModifiedSelect: { shift, command in
                    model.select(session.id, shift: shift, command: command)
                },
                onPrepareDrag: { model.prepareSelectionForDrag(session.id) },
                onClose: { closeTab(session.id) },
                splitWithActiveEnabled: model.selectedID != session.id,
                onSplitWithActive: { model.split(with: session.id, on: .trailing) },
                onUnsplit: model.split(containing: session.id) == nil ? nil : { model.unsplit(tabID: session.id) },
                onArchive: { model.archiveTab(session.id) },
                onBeginRename: { beginRename(.tab(session.id)) },
                onCommitRename: { commitRename(.tab(session.id), $0) },
                onCancelRename: cancelRename,
                onNewFolder: { _ = model.makeFolder(containing: session.id) },
                onRemoveFromFolder: model.folderContaining(session.id) == nil ? nil : { model.removeFromFolder(session.id) },
                folderDestinations: folderDestinations(for: session.id)
            )
        }
    }

    private func folderDestinations(for tabID: UUID) -> [(title: String, handler: () -> Void)] {
        let current = model.folderContaining(tabID)?.id
        return model.folders.compactMap { folder in
            guard folder.id != current else { return nil }
            return (folder.name, { model.add(tabID, to: folder.id) })
        }
    }
}

/// One continuous Lume-style selection band. Each half records whether a
/// split-tab segment occupies it, then bridges the list's 1pt row spacing.
private struct SidebarSelectionChrome: View {
    let item: SidebarTabItem
    let previousItem: SidebarTabItem?
    let nextItem: SidebarTabItem?
    let selectedTabIDs: Set<UUID>

    private let cornerRadius: CGFloat = 7
    private var current: Occupancy { occupancy(of: item) }
    private var previous: Occupancy { occupancy(of: previousItem) }
    private var next: Occupancy { occupancy(of: nextItem) }

    var body: some View {
        GeometryReader { geometry in
            let dividerWidth = item.members.count > 1 ? ShellMetrics.sidebarRowSpacing : 0
            let halfWidth = (geometry.size.width - dividerWidth) / 2
            ZStack(alignment: .topLeading) {
                if current.leading {
                    UnevenRoundedRectangle(
                        topLeadingRadius: previous.leading ? 0 : cornerRadius,
                        bottomLeadingRadius: next.leading ? 0 : cornerRadius,
                        bottomTrailingRadius: next.leading || current.trailing ? 0 : cornerRadius,
                        topTrailingRadius: previous.leading || current.trailing ? 0 : cornerRadius,
                        style: .continuous
                    )
                    .fill(selectionColor)
                    .frame(
                        width: halfWidth,
                        height: geometry.size.height + (next.leading ? ShellMetrics.sidebarRowSpacing : 0)
                    )
                }

                if current.trailing {
                    UnevenRoundedRectangle(
                        topLeadingRadius: previous.trailing || current.leading ? 0 : cornerRadius,
                        bottomLeadingRadius: next.trailing || current.leading ? 0 : cornerRadius,
                        bottomTrailingRadius: next.trailing ? 0 : cornerRadius,
                        topTrailingRadius: previous.trailing ? 0 : cornerRadius,
                        style: .continuous
                    )
                    .fill(selectionColor)
                    .frame(
                        width: halfWidth,
                        height: geometry.size.height + (next.trailing ? ShellMetrics.sidebarRowSpacing : 0)
                    )
                    .offset(x: halfWidth + dividerWidth)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var selectionColor: Color {
        Color.primary.opacity(0.16)
    }

    private func occupancy(of item: SidebarTabItem?) -> Occupancy {
        guard let item, let first = item.members.first else { return Occupancy() }
        if item.members.count == 1 {
            let selected = selectedTabIDs.contains(first)
            return Occupancy(leading: selected, trailing: selected)
        }
        return Occupancy(
            leading: selectedTabIDs.contains(first),
            trailing: item.members.dropFirst().first.map(selectedTabIDs.contains) ?? false
        )
    }

    private struct Occupancy {
        var leading = false
        var trailing = false
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
    var acceptsPointer = true
    let help: String
    var isRenaming = false
    let onSelect: () -> Void
    var onModifiedSelect: ((Bool, Bool) -> Void)?
    var onPrepareDrag: (() -> Void)?
    let onClose: () -> Void
    var splitWithActiveEnabled = false
    var onSplitWithActive: (() -> Void)?
    var onUnsplit: (() -> Void)?
    var onArchive: (() -> Void)?
    var onBeginRename: () -> Void = {}
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    var onNewFolder: (() -> Void)?
    var onRemoveFromFolder: (() -> Void)?
    var folderDestinations: [(title: String, handler: () -> Void)] = []

    @ObservedObject private var hover = TabDragCoordinator.shared

    private var isHovered: Bool { hover.hoveredRowKey == tabID }

    var body: some View {
        rowChrome
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor)
            }
            .overlay {
                if !isRenaming, acceptsPointer {
                    TabRowHitRepresentable(
                        windowID: windowID,
                        tabID: tabID,
                        title: title,
                        symbol: symbol,
                        onSelect: onSelect,
                        onModifiedSelect: onModifiedSelect,
                        onPrepareDrag: onPrepareDrag,
                        onClose: onClose,
                        onHover: { _ in },
                        splitWithActiveEnabled: splitWithActiveEnabled,
                        onSplitWithActive: onSplitWithActive,
                        onUnsplit: onUnsplit,
                        onArchive: onArchive,
                        onRename: onBeginRename,
                        onNewFolder: onNewFolder,
                        onRemoveFromFolder: onRemoveFromFolder,
                        folderDestinations: folderDestinations
                    )
                }
            }
            .animation(.easeInOut(duration: 0.14), value: hover.hoveredRowKey)
            .animation(.easeInOut(duration: 0.16), value: isSelected)
            .frame(width: width)
            .contentShape(
                .focusEffect,
                RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(help)
    }

    @ViewBuilder
    private var rowChrome: some View {
        if isRenaming {
            label
        } else {
            Button(action: onSelect) { label }
                .buttonStyle(.plain)
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            SidebarTile(symbol: symbol)
            SidebarTitleLabel(
                title: title,
                isSelected: isSelected,
                isRenaming: isRenaming,
                onCommit: onCommitRename,
                onCancel: onCancelRename
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: ShellMetrics.sidebarRowHeight)
        .contentShape(
            .interaction,
            RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    private var backgroundColor: Color {
        if isSelected {
            return .clear
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
    let selectedTabIDs: Set<UUID>
    let width: CGFloat
    var acceptsPointer = true
    let renaming: SidebarRenameTarget?
    let onSelect: (UUID) -> Void
    let onModifiedSelect: (UUID, Bool, Bool) -> Void
    let onPrepareDrag: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onSplitWithActive: (UUID) -> Void
    let onUnsplit: () -> Void
    let onArchive: (UUID) -> Void
    let onBeginRename: (UUID) -> Void
    let onCommitRename: (UUID, String) -> Void
    let onCancelRename: () -> Void
    let onNewFolder: (UUID) -> Void
    var onRemoveFromFolder: ((UUID) -> Void)?
    var folderDestinations: [(title: String, handler: () -> Void)] = []

    @ObservedObject private var hover = TabDragCoordinator.shared

    private var hoveringLeading: Bool { hover.hoveredRowKey == leading.id }
    private var hoveringTrailing: Bool { hover.hoveredRowKey == trailing.id }

    private var showsDivider: Bool {
        !hoveringLeading && !hoveringTrailing
            && !selectedTabIDs.contains(leading.id) && !selectedTabIDs.contains(trailing.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            segment(
                session: leading,
                isSelected: selectedTabIDs.contains(leading.id),
                isHovered: hoveringLeading
            )
            ZStack {
                if showsDivider {
                    Rectangle()
                        .fill(Color.primary.opacity(0.14))
                        .padding(.vertical, 6)
                }
            }
            .frame(width: ShellMetrics.sidebarRowSpacing)
            segment(
                session: trailing,
                isSelected: selectedTabIDs.contains(trailing.id),
                isHovered: hoveringTrailing
            )
        }
        .frame(height: ShellMetrics.sidebarRowHeight)
        .animation(.easeInOut(duration: 0.14), value: hover.hoveredRowKey)
        .animation(.easeInOut(duration: 0.16), value: selectedTabIDs)
        .frame(width: width)
        .help("\(leading.displayTitle) / \(trailing.displayTitle)")
    }

    @ViewBuilder
    private func segment(
        session: TerminalSession,
        isSelected: Bool,
        isHovered: Bool
    ) -> some View {
        let renamingThis = renaming == .tab(session.id)
        if renamingThis {
            segmentLabel(session: session, isSelected: isSelected, isHovered: isHovered)
        } else {
            Button {
                onSelect(session.id)
            } label: {
                segmentLabel(session: session, isSelected: isSelected, isHovered: isHovered)
            }
            .buttonStyle(.plain)
            .overlay {
                if acceptsPointer {
                TabRowHitRepresentable(
                    windowID: windowID,
                    tabID: session.id,
                    listRowID: listRowID,
                    title: session.displayTitle,
                    symbol: session.kind == .settings ? "gearshape.fill" : "terminal",
                    onSelect: { onSelect(session.id) },
                    onModifiedSelect: { shift, command in
                        onModifiedSelect(session.id, shift, command)
                    },
                    onPrepareDrag: { onPrepareDrag(session.id) },
                    onClose: { onClose(session.id) },
                    onHover: { _ in },
                    splitWithActiveEnabled: false,
                    onSplitWithActive: { onSplitWithActive(session.id) },
                    onUnsplit: onUnsplit,
                    onArchive: { onArchive(session.id) },
                    onRename: { onBeginRename(session.id) },
                    onNewFolder: { onNewFolder(session.id) },
                    onRemoveFromFolder: onRemoveFromFolder.map { remove in { remove(session.id) } },
                    folderDestinations: folderDestinations
                )
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityLabel(session.displayTitle)
        }
    }

    private func segmentLabel(
        session: TerminalSession,
        isSelected: Bool,
        isHovered: Bool
    ) -> some View {
        HStack(spacing: 8) {
            SidebarTile(symbol: session.kind == .settings ? "gearshape.fill" : "terminal")
            SidebarTitleLabel(
                title: session.displayTitle,
                isSelected: isSelected,
                isRenaming: renaming == .tab(session.id),
                onCommit: { onCommitRename(session.id, $0) },
                onCancel: onCancelRename
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(segmentBackground(isSelected: isSelected, isHovered: isHovered))
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func segmentBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return .clear
        }
        if isHovered {
            return Color.primary.opacity(0.075)
        }
        return .clear
    }
}

private struct ArchivedSidebarButton: View {
    let isSelected: Bool
    let width: CGFloat
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                SidebarTile(symbol: isSelected ? "archivebox.fill" : "archivebox")

                Text("Archived")
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
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .animation(.easeInOut(duration: 0.16), value: isSelected)
        .frame(width: width)
        .contentShape(
            .focusEffect,
            RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityLabel("Archived")
        .accessibilityIdentifier("archived-tabs")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("Archived tabs")
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

private struct ArchivedTabRow: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let width: CGFloat
    var isRenaming = false
    let onSelect: () -> Void
    let onUnarchive: () -> Void
    let onClose: () -> Void
    var onBeginRename: () -> Void = {}
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}

    @State private var isHovered = false

    var body: some View {
        rowChrome
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor)
            }
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.14), value: isHovered)
            .animation(.easeInOut(duration: 0.16), value: isSelected)
            .frame(width: width)
            .help("\(session.displayTitle) — \(session.directory)")
            .accessibilityLabel(session.displayTitle)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var rowChrome: some View {
        if isRenaming {
            label
        } else {
            Button(action: onSelect) { label }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Rename Tab", action: onBeginRename)
                    Button("Unarchive", action: onUnarchive)
                    Button("Close Tab", action: onClose)
                }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            SidebarTile(symbol: session.kind == .settings ? "gearshape.fill" : "terminal")
            SidebarTitleLabel(
                title: session.displayTitle,
                isSelected: isSelected,
                isRenaming: isRenaming,
                onCommit: onCommitRename,
                onCancel: onCancelRename
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .onTapGesture(count: 2) { onBeginRename() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: ShellMetrics.sidebarRowHeight)
        .contentShape(
            .interaction,
            RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
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

// MARK: - Folder row

private struct FolderSidebarRow: View {
    let windowID: UUID
    let folder: TabFolder
    let isActive: Bool
    let width: CGFloat
    let isRenaming: Bool
    let onToggle: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var hover = TabDragCoordinator.shared

    private var isHovered: Bool { hover.hoveredRowKey == folder.id }

    var body: some View {
        HStack(spacing: 8) {
            SidebarTile(symbol: "folder")

            SidebarTitleLabel(
                title: folder.name,
                isSelected: isActive,
                isRenaming: isRenaming,
                onCommit: onCommitRename,
                onCancel: onCancelRename
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: ShellMetrics.sidebarRowHeight)
        .frame(width: width)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor)
        }
        .overlay {
            if !isRenaming {
                TabRowHitRepresentable(
                    windowID: windowID,
                    tabID: nil,
                    listRowID: folder.id,
                    title: folder.name,
                    symbol: "folder",
                    onSelect: onToggle,
                    onClose: {},
                    onHover: { _ in },
                    onRename: onBeginRename,
                    onDeleteFolder: onDelete,
                    allowsDrag: false,
                    isFolder: true
                )
            }
        }
        .animation(.easeInOut(duration: 0.14), value: hover.hoveredRowKey)
        .animation(.easeInOut(duration: 0.16), value: isActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), folder")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: folder.collapsed ? "Expand" : "Collapse", onToggle)
    }

    private var backgroundColor: Color {
        if isActive { return Color.primary.opacity(0.16) }
        if isHovered { return Color.primary.opacity(0.075) }
        return .clear
    }
}

/// One text view draws the label and edits it. Swapping in a field editor moves the glyphs.
private struct SidebarTitleLabel: View {
    let title: String
    let isSelected: Bool
    let isRenaming: Bool
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        SidebarInlineName(
            text: title,
            isSelected: isSelected,
            isRenaming: isRenaming,
            onCommit: onCommit,
            onCancel: onCancel
        )
    }
}

private struct SidebarInlineName: NSViewRepresentable {
    var text: String
    var isSelected: Bool
    var isRenaming: Bool
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SidebarInlineNameScrollView {
        let scroll = SidebarInlineNameScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.focusRingType = .none
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none

        let textView = SidebarInlineNameView(frame: NSRect(x: 0, y: 0, width: 80, height: 16))
        textView.delegate = context.coordinator
        textView.autoresizingMask = NSView.AutoresizingMask.width
        scroll.documentView = textView
        scroll.nameView = textView
        apply(to: textView, context: context)
        return scroll
    }

    func updateNSView(_ nsView: SidebarInlineNameScrollView, context: Context) {
        guard let textView = nsView.nameView else { return }
        apply(to: textView, context: context)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SidebarInlineNameScrollView,
        context: Context
    ) -> CGSize? {
        let font = Self.labelFont(selected: isSelected)
        let line = ceil(nsView.nameView?.layoutManager?.defaultLineHeight(for: font) ?? font.boundingRectForFont.height)
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 80
        return CGSize(width: width, height: line)
    }

    private func apply(to textView: SidebarInlineNameView, context: Context) {
        textView.onCommit = onCommit
        textView.onCancel = onCancel
        let font = Self.labelFont(selected: isSelected)
        if textView.font != font { textView.font = font }
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor

        let wasEditing = textView.isEditingMode
        let firstApply = !context.coordinator.didApplyOnce
        context.coordinator.didApplyOnce = true

        if !isRenaming || !wasEditing {
            if textView.string != text {
                textView.string = text
            }
        }
        textView.restyle()

        textView.isEditingMode = isRenaming
        if wasEditing && !isRenaming {
            textView.string = text
            textView.restyle()
            textView.resetScroll()
        }

        let entersEditing = isRenaming && !wasEditing && !firstApply
        if entersEditing || (firstApply && isRenaming) {
            textView.prepareEditingSession()
            DispatchQueue.main.async { [weak textView] in
                textView?.claimKeyboardFocus(retries: 5)
            }
        }
    }

    private static func labelFont(selected: Bool) -> NSFont {
        NSFont.systemFont(ofSize: 13, weight: selected ? .medium : .regular)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var didApplyOnce = false

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? SidebarInlineNameView else { return }
            textView.commitUnlessCancelled()
        }
    }
}

final class SidebarInlineNameScrollView: NSScrollView {
    weak var nameView: SidebarInlineNameView?

    override func layout() {
        super.layout()
        guard let nameView else { return }
        var frame = nameView.frame
        frame.origin = .zero
        frame.size.height = contentSize.height
        if !nameView.isEditingMode || frame.width < contentSize.width {
            frame.size.width = contentSize.width
        }
        if nameView.frame != frame { nameView.frame = frame }
        nameView.restyle()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard nameView?.isEditingMode == true else { return nil }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// Label and editor are this same view, so the glyphs do not move when renaming starts.
final class SidebarInlineNameView: NSTextView {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var cancelled = false
    private var committed = false
    private var mouseDownMonitor: Any?
    private var appliedStyle: String?
    private let horizontalInset: CGFloat = 2

    var isEditingMode = false {
        didSet {
            guard isEditingMode != oldValue else { return }
            isEditable = isEditingMode
            isSelectable = isEditingMode
            if !isEditingMode {
                updateInsertionPointStateAndRestartTimer(false)
                setSelectedRange(NSRange(location: 0, length: 0))
                removeMouseDownMonitor()
                if window?.firstResponder === self {
                    window?.makeFirstResponder(nil)
                }
            }
            restyle()
        }
    }

    override convenience init(frame frameRect: NSRect) {
        let container = NSTextContainer(size: NSSize(width: frameRect.width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        self.init(frame: frameRect, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        drawsBackground = false
        isRichText = false
        isEditable = false
        isSelectable = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        focusRingType = .none
        textContainerInset = NSSize(width: horizontalInset, height: 0)
        textContainer?.lineFragmentPadding = 0
        textContainer?.maximumNumberOfLines = 1
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textColor = .labelColor
        insertionPointColor = .labelColor
    }

    func prepareEditingSession() {
        cancelled = false
        committed = false
    }

    func claimKeyboardFocus(retries: Int) {
        guard isEditingMode, let window else {
            guard retries > 0 else { return }
            DispatchQueue.main.async { [weak self] in self?.claimKeyboardFocus(retries: retries - 1) }
            return
        }
        window.makeFirstResponder(self)
        selectAllDeferred()
        guard window.firstResponder !== self, retries > 0 else { return }
        DispatchQueue.main.async { [weak self] in self?.claimKeyboardFocus(retries: retries - 1) }
    }

    func restyle() {
        guard let container = textContainer, let layoutManager, let font else { return }
        let mark = "\(isEditingMode)|\(font.fontName)|\(font.pointSize)|\(string)|\(Int(bounds.width))|\(Int(bounds.height))"
        if mark == appliedStyle { return }
        appliedStyle = mark
        let selection = selectedRange()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = isEditingMode ? .byClipping : .byTruncatingTail
        style.alignment = .left
        let color = textColor ?? .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        typingAttributes = attributes
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            if isEditingMode { setSelectedRange(selection) }
        }
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 1
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let vertical = max(0, (bounds.height - lineHeight) / 2)
        let inset = NSSize(width: horizontalInset, height: vertical)
        if textContainerInset != inset { textContainerInset = inset }

        if isEditingMode {
            container.widthTracksTextView = false
            container.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            isHorizontallyResizable = true
            layoutManager.ensureLayout(for: container)
            let used = ceil(layoutManager.usedRect(for: container).width)
            let width = max(enclosingScrollView?.contentSize.width ?? bounds.width, used + horizontalInset * 2)
            if abs(frame.width - width) > 0.5 {
                var next = frame
                next.size.width = width
                frame = next
            }
        } else {
            isHorizontallyResizable = false
            container.widthTracksTextView = false
            let visible = enclosingScrollView?.contentSize.width ?? bounds.width
            container.containerSize = NSSize(
                width: max(0, visible - horizontalInset * 2),
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    func resetScroll() {
        guard let scrollView = enclosingScrollView else { return }
        var next = frame
        next.origin.x = 0
        next.size.width = scrollView.contentSize.width
        frame = next
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func becomeFirstResponder() -> Bool {
        guard isEditingMode else { return false }
        let accepted = super.becomeFirstResponder()
        if accepted { installMouseDownMonitor() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { removeMouseDownMonitor() }
        return resigned
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            commitUnlessCancelled()
            window?.makeFirstResponder(nil)
        case #selector(NSResponder.cancelOperation(_:)),
             #selector(NSStandardKeyBindingResponding.complete(_:)):
            cancelled = true
            onCancel?()
            window?.makeFirstResponder(nil)
        default:
            super.doCommand(by: selector)
        }
    }

    func selectAllDeferred() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditingMode, self.window?.firstResponder === self else { return }
            self.setSelectedRange(NSRange(location: 0, length: (self.string as NSString).length))
        }
    }

    func commitUnlessCancelled() {
        guard isEditingMode, !cancelled, !committed else { return }
        committed = true
        onCommit?(string)
    }

    private func installMouseDownMonitor() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.firstResponder === self else {
                return event
            }
            let host = self.enclosingScrollView ?? self
            let point = host.convert(event.locationInWindow, from: nil)
            guard !host.bounds.contains(point) else { return event }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, window.firstResponder === self else { return }
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func removeMouseDownMonitor() {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
    }

    isolated deinit {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
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
