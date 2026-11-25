import SwiftUI

struct SidebarLineStats: Equatable {
    var additions: Int
    var deletions: Int
}

@MainActor
final class SidebarGitStatsModel: ObservableObject {
    @Published private(set) var statsByDirectory: [String: SidebarLineStats] = [:]

    private let service: any GitReviewServicing
    private let watcher: any RepositoryWatching
    private var keyByDirectory: [String: RepositoryKey] = [:]
    private var statsByRepository: [RepositoryKey: SidebarLineStats] = [:]
    private var scanTask: Task<Void, Never>?
    private var refreshTasks: [RepositoryKey: Task<Void, Never>] = [:]
    private var watchTasks: [RepositoryKey: Task<Void, Never>] = [:]
    private var generation = 0
    private var running = false

    init(service: any GitReviewServicing = GitRepositoryService(), watcher: any RepositoryWatching = RepositoryWatcher()) {
        self.service = service
        self.watcher = watcher
    }

    func start(directories: [String]) {
        running = true
        scan(directories: directories)
    }

    func update(directories: [String]) {
        guard running else { return }
        scan(directories: directories)
    }

    func stop() {
        running = false
        generation += 1
        scanTask?.cancel()
        scanTask = nil
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
        watchTasks.values.forEach { $0.cancel() }
        watchTasks.removeAll()
        watcher.stopAll()
        keyByDirectory.removeAll()
        statsByRepository.removeAll()
        statsByDirectory.removeAll()
    }

    static func standardized(_ directory: String) -> String {
        URL(fileURLWithPath: directory).standardizedFileURL.path
    }

    private func scan(directories: [String]) {
        generation += 1
        let scanGeneration = generation
        scanTask?.cancel()
        let uniqueDirectories = Array(Set(directories.map(Self.standardized))).sorted()
        scanTask = Task { [service, weak self] in
            var resolved: [String: RepositoryKey] = [:]
            await withTaskGroup(of: (String, RepositoryKey?).self) { group in
                for directory in uniqueDirectories {
                    group.addTask {
                        (directory, try? await service.resolveRepository(directory: directory))
                    }
                }
                for await (directory, key) in group {
                    if let key { resolved[directory] = key }
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.running, self.generation == scanGeneration else { return }
                self.keyByDirectory = resolved
                self.reconcileRepositories()
            }
        }
    }

    private func reconcileRepositories() {
        let needed = Set(keyByDirectory.values)
        for key in needed {
            if watchTasks[key] == nil {
                startWatching(key)
            }
            refresh(key)
        }
        for key in Array(watchTasks.keys) where !needed.contains(key) {
            watchTasks.removeValue(forKey: key)?.cancel()
            watcher.stop(key)
        }
        for key in Array(refreshTasks.keys) where !needed.contains(key) {
            refreshTasks.removeValue(forKey: key)?.cancel()
        }
        statsByRepository = statsByRepository.filter { needed.contains($0.key) }
        publish()
    }

    private func startWatching(_ key: RepositoryKey) {
        watchTasks[key] = Task { [watcher, weak self] in
            let events = watcher.events(for: key)
            for await _ in events {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.refresh(key)
                }
            }
        }
    }

    private func refresh(_ key: RepositoryKey) {
        guard running, keyByDirectory.values.contains(key) else { return }
        refreshTasks[key]?.cancel()
        refreshTasks[key] = Task { [service, weak self] in
            guard let snapshot = try? await service.loadCatalog(for: key, generation: 0), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.running, self.keyByDirectory.values.contains(key) else { return }
                self.statsByRepository[key] = SidebarLineStats(additions: snapshot.additions, deletions: snapshot.deletions)
                self.publish()
            }
        }
    }

    private func publish() {
        var stats: [String: SidebarLineStats] = [:]
        for (directory, key) in keyByDirectory {
            if let value = statsByRepository[key] {
                stats[directory] = value
            }
        }
        statsByDirectory = stats
    }
}

enum SidebarDefaults {
    static let activityView = "sidebarActivityView"
    static let settledCollapsed = "sidebarSettledCollapsed"
}

extension EnvironmentValues {
    /// Shared by the tab list and the activity view so a tab's row moves between them.
    @Entry var sidebarRowNamespace: Namespace.ID?
}

private struct SidebarRowMatch: ViewModifier {
    let id: UUID
    let enabled: Bool
    @Environment(\.sidebarRowNamespace) private var namespace

    func body(content: Content) -> some View {
        if enabled, let namespace {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}

extension View {
    /// `enabled: false` for rows that are in the hierarchy but hidden, such as the tabs
    /// behind a collapsed folder, so they never fly in to a place nobody can see.
    func sidebarRowMatch(_ id: UUID, enabled: Bool = true) -> some View {
        modifier(SidebarRowMatch(id: id, enabled: enabled))
    }
}

extension AnyTransition {
    /// A removed row fades almost at once while the rows around it close the gap;
    /// an inserted one waits for the space to open before fading in.
    static var sidebarRowRemoval: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeIn(duration: 0.18).delay(0.12)),
            removal: .opacity.animation(.easeOut(duration: 0.06))
        )
    }
}

/// Sidebar rows do not dim while pressed; selection and hover are their only feedback.
private struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Half the row gap on each side belongs to the row, so the pointer is always over one.
private let rowGapShare = ShellMetrics.sidebarRowSpacing / 2

// MARK: - Settled

/// Settled tabs of the active space, folded under a header at the bottom of the list.
struct SettledSection: View {
    @ObservedObject var model: TerminalModel
    let width: CGFloat
    var closeSettledTab: (UUID) -> Void

    var body: some View {
        SettledList(model: model, sessions: model.filteredSettled.reversed(), width: width, closeSettledTab: closeSettledTab)
    }
}

private struct SettledList: View {
    @ObservedObject var model: TerminalModel
    let sessions: [TerminalSession]
    let width: CGFloat
    var closeSettledTab: (UUID) -> Void
    @AppStorage(SidebarDefaults.settledCollapsed) private var collapsed = false

    var body: some View {
        if !sessions.isEmpty {
            VStack(spacing: 0) {
                Button {
                    collapsed.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Text("Settled")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(sessions.count)")
                            .font(.system(size: 12).monospacedDigit())
                            .opacity(0.8)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                    .frame(width: width, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(collapsed ? "Show settled tabs" : "Hide settled tabs")
                .accessibilityLabel("Settled, \(sessions.count) tabs")
                .accessibilityValue(collapsed ? "Collapsed" : "Expanded")

                if !collapsed {
                    ForEach(sessions) { session in
                        SettledRow(
                            session: session,
                            width: width,
                            isSelected: session.id == model.selectedID,
                            open: { model.reveal(session.id) },
                            reopen: { model.reopenTabInAnySpace(session.id) },
                            close: { closeSettledTab(session.id) }
                        )
                    }
                }
            }
        }
    }
}

/// A settled tab: small and grey, a click away from reopening. Its session keeps running.
private struct SettledRow: View {
    @ObservedObject var session: TerminalSession
    let width: CGFloat
    let isSelected: Bool
    let open: () -> Void
    let reopen: () -> Void
    let close: () -> Void

    @State private var isHovered = false
    @State private var isCheckHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                Button(action: reopen) {
                    Image(systemName: isCheckHovered ? "checkmark.circle" : "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.green.opacity(isCheckHovered ? 1 : 0.8))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SidebarRowButtonStyle())
                .focusable(false)
                .onHover { isCheckHovered = $0 }
                .help("Reopen Tab")
                .accessibilityLabel("Reopen \(session.displayTitle)")

                Text(session.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: width, height: ShellMetrics.sidebarRowHeight)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.16 : (isHovered ? 0.075 : 0)))
                    .animation(.easeInOut(duration: 0.14), value: isHovered)
                    .animation(.easeInOut(duration: 0.16), value: isSelected)
            }
            .padding(.vertical, rowGapShare)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .focusable(false)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open Tab", action: open)
            Button("Reopen Tab", action: reopen)
            Divider()
            Button("Close Tab", action: close)
        }
        .help("\(session.displayTitle) — \(session.directory)")
        .accessibilityLabel("\(session.displayTitle), settled")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sidebarRowMatch(session.id)
    }
}

// MARK: - Activity layout

/// The sidebar while the activity toggle is on: tabs that want the user first, then
/// every space's open tabs, then everything settled.
struct SidebarActivityList: View {
    @ObservedObject var model: TerminalModel
    let width: CGFloat
    var closeTab: (UUID) -> Void
    var closeSettledTab: (UUID) -> Void
    let renamingTabID: UUID?
    let beginRename: (UUID) -> Void
    let commitRename: (UUID, String) -> Void
    let cancelRename: () -> Void
    @StateObject private var gitStats = SidebarGitStatsModel()

    var body: some View {
        let attention = model.activity
        let attentionIDs = Set(attention.map(\.id))
        let folderAnchors = FolderAnchor.byFirstTab(model)
        let settledIDs = Set(model.settledBySpace.flatMap { $0.tabs.map(\.id) })
        let activeSessionIDs = Set(model.tabs.map(\.id)).union(model.settled.map(\.id))
        let directories = Array(Set(model.allSessions.filter { $0.kind == .terminal }.map { SidebarGitStatsModel.standardized($0.directory) })).sorted()
        VStack(spacing: 0) {
            if !attention.isEmpty {
                ActivityHeader(title: "Needs attention", isFirst: true, width: width)
                ForEach(attention) { item in
                    ActivityTabRow(
                        model: model,
                        session: item.session,
                        detail: AttentionText.detail(for: item),
                        lineStats: gitStats.statsByDirectory[SidebarGitStatsModel.standardized(item.session.directory)],
                        isSelected: item.session.id == model.selectedID,
                        isSettled: settledIDs.contains(item.session.id),
                        isInActiveSpace: activeSessionIDs.contains(item.session.id),
                        width: width,
                        folderAnchor: folderAnchors[item.session.id],
                        isRenaming: renamingTabID == item.session.id,
                        beginRename: { beginRename(item.session.id) },
                        commitRename: { commitRename(item.session.id, $0) },
                        cancelRename: cancelRename,
                        close: {
                            if settledIDs.contains(item.session.id) { closeSettledTab(item.session.id) } else { closeTab(item.session.id) }
                        },
                        action: { model.reveal(item.session.id) }
                    )
                }
            }
            ForEach(Array(model.openTabsBySpace.enumerated()), id: \.element.space.id) { index, group in
                let rest = group.tabs.filter { !attentionIDs.contains($0.id) }
                if !rest.isEmpty {
                    ActivityHeader(title: group.space.name, isFirst: attention.isEmpty && index == 0, width: width)
                    ForEach(rest) { session in
                        ActivityTabRow(
                            model: model,
                            session: session,
                            detail: nil,
                            lineStats: gitStats.statsByDirectory[SidebarGitStatsModel.standardized(session.directory)],
                            isSelected: session.id == model.selectedID,
                            isSettled: false,
                            isInActiveSpace: group.space.id == model.activeSpaceID,
                            width: width,
                            folderAnchor: folderAnchors[session.id],
                            isRenaming: renamingTabID == session.id,
                            beginRename: { beginRename(session.id) },
                            commitRename: { commitRename(session.id, $0) },
                            cancelRename: cancelRename,
                            close: { closeTab(session.id) },
                            action: { model.reveal(session.id) }
                        )
                    }
                }
            }
            SettledList(
                model: model,
                sessions: model.settledBySpace.flatMap(\.tabs).filter { !attentionIDs.contains($0.id) },
                width: width,
                closeSettledTab: closeSettledTab
            )
        }
        .onAppear { gitStats.start(directories: directories) }
        .onChange(of: directories) { _, newDirectories in
            gitStats.update(directories: newDirectories)
        }
        .onDisappear { gitStats.stop() }
    }
}

/// Where a folder row of the active space comes from when the tab list returns. A
/// collapsed folder grows out of the row of the tab it hides; an open one comes from just
/// above its first tab, whose own row goes to its place under the folder.
struct FolderAnchor {
    let id: UUID
    let aboveRow: Bool

    @MainActor
    static func byFirstTab(_ model: TerminalModel) -> [UUID: FolderAnchor] {
        let order = Dictionary(uniqueKeysWithValues: model.tabs.enumerated().map { ($1.id, $0) })
        var anchors: [UUID: FolderAnchor] = [:]
        for folder in model.folders {
            guard let first = folder.tabIDs.min(by: { (order[$0] ?? .max) < (order[$1] ?? .max) }) else { continue }
            anchors[first] = FolderAnchor(id: folder.id, aboveRow: !folder.collapsed)
        }
        return anchors
    }
}

private struct ActivityHeader: View {
    let title: String
    let isFirst: Bool
    let width: CGFloat

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.top, isFirst ? 2 : 12)
            .padding(.bottom, 4)
            .frame(width: width, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A tab in the activity view: two lines, the title over the folder it is in, or over
/// what it wants when it needs attention.
private struct ActivityTabRow: View {
    @ObservedObject var model: TerminalModel
    @ObservedObject var session: TerminalSession
    let detail: String?
    let lineStats: SidebarLineStats?
    let isSelected: Bool
    let isSettled: Bool
    let isInActiveSpace: Bool
    let width: CGFloat
    /// The folder that slides out of this row when the tab list comes back.
    var folderAnchor: FolderAnchor?
    let isRenaming: Bool
    let beginRename: () -> Void
    let commitRename: (String) -> Void
    let cancelRename: () -> Void
    let close: () -> Void
    let action: () -> Void

    @ObservedObject private var hover = TabDragCoordinator.shared

    private var isHovered: Bool { hover.hoveredRowKey == session.id }

    /// Top and bottom padding of the row; the title's first line sits right below it.
    private static let verticalPadding: CGFloat = 6
    /// One line of 13pt title text.
    private static let titleLineHeight: CGFloat = 16

    private var isOpenTerminal: Bool {
        !isSettled && session.kind == .terminal
    }

    private var canUseActiveSpaceActions: Bool {
        isOpenTerminal && isInActiveSpace
    }

    private var splitWithActiveEnabled: Bool {
        guard canUseActiveSpaceActions,
              let selected = model.selectedID,
              selected != session.id,
              model.tabs.contains(where: { $0.id == selected }) else { return false }
        return true
    }

    private var folderDestinations: [(title: String, handler: () -> Void)] {
        guard canUseActiveSpaceActions else { return [] }
        return model.folders.map { folder in
            (title: folder.name, handler: {
                model.add(session.id, to: folder.id)
            })
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                SidebarInlineName(
                    text: session.displayTitle,
                    isSelected: isSelected,
                    isRenaming: isRenaming,
                    onCommit: commitRename,
                    onCancel: cancelRename
                )
                detailLine
            }
            Spacer(minLength: 0)
            if session.attention != nil {
                Circle()
                    .fill(Color(red: 0.89, green: 0.80, blue: 0.56))
                    .frame(width: 7, height: 7)
                    .padding(.top, 6)
                    .opacity(isHovered ? 0 : 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, Self.verticalPadding)
        .frame(width: width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.16 : (isHovered ? 0.075 : 0)))
                .animation(.easeInOut(duration: 0.14), value: isHovered)
                .animation(.easeInOut(duration: 0.16), value: isSelected)
        }
        .background(alignment: .top) {
            if let folderAnchor {
                Color.clear
                    .frame(height: ShellMetrics.sidebarRowHeight)
                    .padding(.top, folderAnchor.aboveRow ? -(ShellMetrics.sidebarRowHeight + ShellMetrics.sidebarRowSpacing) : 0)
                    .sidebarRowMatch(folderAnchor.id)
            }
        }
        .padding(.vertical, rowGapShare)
        .contentShape(Rectangle())
        .overlay {
            if !isRenaming {
                hitTarget
            }
        }
        .overlay(alignment: .topTrailing) {
            ActivityCloseButton(title: session.displayTitle, action: close)
                .padding(.top, rowGapShare + Self.verticalPadding + (Self.titleLineHeight - TabCloseMetrics.side) / 2)
                .padding(.trailing, TabCloseMetrics.trailingInset)
                .opacity(isHovered ? 1 : 0)
                .animation(.easeInOut(duration: TabCloseMetrics.fadeDuration), value: isHovered)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
        }
        .focusable(false)
        .help(isSettled ? "Open \(session.displayTitle)" : session.directory)
        .accessibilityLabel([session.displayTitle, detailText].joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sidebarRowMatch(session.id)
    }

    private var hitTarget: TabRowHitRepresentable {
        TabRowHitRepresentable(
            windowID: model.id,
            tabID: session.id,
            listRowID: nil,
            title: session.displayTitle,
            symbol: session.kind == .settings ? "gearshape.fill" : "terminal",
            onSelect: action,
            onModifiedSelect: nil,
            onPrepareDrag: nil,
            onClose: close,
            onHover: { _ in },
            splitWithActiveEnabled: splitWithActiveEnabled,
            onSplitWithActive: canUseActiveSpaceActions ? { model.split(with: session.id, on: .trailing) } : nil,
            onUnsplit: canUseActiveSpaceActions && model.split(containing: session.id) != nil ? { model.unsplit(tabID: session.id) } : nil,
            onArchive: isOpenTerminal ? { model.settleTabInAnySpace(session.id) } : nil,
            onReopen: isSettled ? { model.reopenTabInAnySpace(session.id) } : nil,
            onRename: beginRename,
            onDoubleClick: nil,
            onNewFolder: canUseActiveSpaceActions ? { _ = model.makeFolder(containing: session.id) } : nil,
            onRemoveFromFolder: canUseActiveSpaceActions && model.folderContaining(session.id) != nil ? { model.removeFromFolder(session.id) } : nil,
            onDeleteFolder: nil,
            folderDestinations: folderDestinations,
            allowsDrag: false,
            fillsHeight: true,
            closeButtonEnabled: false,
            isFolder: false
        )
    }

    private var detailSymbol: String {
        guard detail == nil else {
            return session.attention.map { AttentionText.symbol(for: $0.reason) } ?? "bell"
        }
        return "folder"
    }

    private var detailText: String {
        detail ?? Self.folderName(session.directory)
    }

    @ViewBuilder
    private var detailLine: some View {
        HStack(spacing: 4) {
            Image(systemName: detailSymbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(detailText)
                .font(.system(size: 11))
                .lineLimit(detail == nil ? 1 : 2)
            if detail == nil, let lineStats {
                Text("·")
                    .font(.system(size: 11))
                Text("+\(lineStats.additions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColors.reviewAddition)
                Text("−\(lineStats.deletions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColors.reviewDeletion)
            }
        }
        .foregroundStyle(.secondary)
    }

    private static func folderName(_ path: String) -> String {
        if path == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// The same hover X the tab list draws, as a SwiftUI button for the activity view's rows.
private struct ActivityCloseButton: View {
    let title: String
    let action: () -> Void
    @State private var isHot = false

    var body: some View {
        Button(action: action) {
            Color.clear.frame(width: TabCloseMetrics.side, height: TabCloseMetrics.side)
        }
        .buttonStyle(ActivityCloseStyle(isHot: isHot))
        .onHover { isHot = $0 }
        .focusable(false)
        .help("Close Tab")
        .accessibilityLabel("Close \(title)")
    }
}

private struct ActivityCloseStyle: ButtonStyle {
    var isHot: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(SidebarIconStyle.opacity))
            }
            .background {
                RoundedRectangle(cornerRadius: TabCloseMetrics.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .labelColor).opacity(configuration.isPressed ? 0.20 : (isHot ? 0.10 : 0)))
                    .animation(.easeInOut(duration: TabCloseMetrics.fadeDuration), value: isHot)
            }
            .contentShape(RoundedRectangle(cornerRadius: TabCloseMetrics.cornerRadius, style: .continuous))
    }
}

@MainActor
enum AttentionText {
    static func symbol(for reason: SessionAttention.Reason) -> String {
        switch reason {
        case .commandFinished(let command):
            return (command.exitCode ?? 0) == 0 ? "checkmark" : "xmark"
        case .bell:
            return "bell.fill"
        case .notification:
            return "text.bubble.fill"
        }
    }

    static func detail(for item: ActivityItem) -> String {
        let reason: String
        switch item.attention.reason {
        case .commandFinished(let command):
            let duration = CommandNotifier.format(command.duration)
            if let code = command.exitCode, code != 0 {
                reason = "Failed (exit \(code)) after \(duration)"
            } else {
                reason = "Finished after \(duration)"
            }
        case .bell:
            reason = "Rang the bell"
        case .notification(let message):
            reason = message
        }
        guard let space = item.space else { return reason }
        return "\(space.name) · \(reason)"
    }
}
