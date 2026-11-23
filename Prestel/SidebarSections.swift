import SwiftUI

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
                            reopen: { model.reveal(session.id) },
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
    let reopen: () -> Void
    let close: () -> Void

    @State private var isHovered = false
    @State private var isCheckHovered = false

    var body: some View {
        Button(action: reopen) {
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
            .frame(width: width, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.075 : 0))
                    .animation(.easeInOut(duration: 0.14), value: isHovered)
            }
            .padding(.vertical, rowGapShare)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .focusable(false)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Reopen Tab", action: reopen)
            Button("Close Tab", action: close)
        }
        .help("\(session.displayTitle) — \(session.directory)")
        .accessibilityLabel("\(session.displayTitle), settled")
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

    var body: some View {
        let attention = model.activity
        let attentionIDs = Set(attention.map(\.id))
        let folderAnchors = FolderAnchor.byFirstTab(model)
        let settledIDs = Set(model.settledBySpace.flatMap { $0.tabs.map(\.id) })
        VStack(spacing: 0) {
            if !attention.isEmpty {
                ActivityHeader(title: "Needs attention", isFirst: true, width: width)
                ForEach(attention) { item in
                    ActivityTabRow(
                        session: item.session,
                        detail: AttentionText.detail(for: item),
                        isSelected: item.session.id == model.selectedID && !settledIDs.contains(item.session.id),
                        isSettled: settledIDs.contains(item.session.id),
                        width: width,
                        folderAnchor: folderAnchors[item.session.id],
                        close: {
                            if settledIDs.contains(item.session.id) { closeSettledTab(item.session.id) } else { closeTab(item.session.id) }
                        }
                    ) { model.reveal(item.session.id) }
                }
            }
            ForEach(Array(model.openTabsBySpace.enumerated()), id: \.element.space.id) { index, group in
                let rest = group.tabs.filter { !attentionIDs.contains($0.id) }
                if !rest.isEmpty {
                    ActivityHeader(title: group.space.name, isFirst: attention.isEmpty && index == 0, width: width)
                    ForEach(rest) { session in
                        ActivityTabRow(
                            session: session,
                            detail: nil,
                            isSelected: session.id == model.selectedID,
                            isSettled: false,
                            width: width,
                            folderAnchor: folderAnchors[session.id],
                            close: { closeTab(session.id) }
                        ) { model.reveal(session.id) }
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
    @ObservedObject var session: TerminalSession
    let detail: String?
    let isSelected: Bool
    let isSettled: Bool
    let width: CGFloat
    /// The folder that slides out of this row when the tab list comes back.
    var folderAnchor: FolderAnchor?
    let close: () -> Void
    let action: () -> Void

    @State private var isHovered = false

    /// Top and bottom padding of the row; the title's first line sits right below it.
    private static let verticalPadding: CGFloat = 6
    /// One line of 13pt title text.
    private static let titleLineHeight: CGFloat = 16

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: detail == nil ? "folder" : session.attention.map { AttentionText.symbol(for: $0.reason) } ?? "bell")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(detail ?? Self.folderName(session.directory))
                            .font(.system(size: 11))
                            .lineLimit(detail == nil ? 1 : 2)
                    }
                    .foregroundStyle(.secondary)
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
        }
        .buttonStyle(SidebarRowButtonStyle())
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
        .onHover { isHovered = $0 }
        .help(isSettled ? "Reopen \(session.displayTitle)" : session.directory)
        .accessibilityLabel([session.displayTitle, detail ?? Self.folderName(session.directory)].joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sidebarRowMatch(session.id)
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
