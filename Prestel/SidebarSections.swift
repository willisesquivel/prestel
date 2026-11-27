import QuartzCore
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

enum SidebarFlightCoordinate {
    static let space = "SidebarFlightSpace"
}

enum SidebarRowForm: Hashable {
    case compactOpen
    case compactSettled
    case activityOpen
    case activitySettled

    var isActivity: Bool {
        self == .activityOpen || self == .activitySettled
    }
}

struct SidebarFlightAppearance: Equatable {
    var title = ""
    var symbol = "terminal"
    var detail: String?
    var detailSymbol = "folder"
    var additions: Int?
    var deletions: Int?
    var activity = false
    var settled = false
    var selected = false
    var fill = 0.0
}

struct SidebarFlightFrame: Equatable {
    let form: SidebarRowForm
    let frame: CGRect
    var appearance = SidebarFlightAppearance()
}

struct SidebarFlightFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: SidebarFlightFrame] { [:] }

    static func reduce(value: inout [UUID: SidebarFlightFrame], nextValue: () -> [UUID: SidebarFlightFrame]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct SidebarActivitySpaceHeaderFrame: Equatable {
    let title: String
    let isFirst: Bool
    let frame: CGRect
    let expansion: CGFloat
}

struct SidebarActivitySpaceHeadersPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: SidebarActivitySpaceHeaderFrame] { [:] }

    static func reduce(value: inout [UUID: SidebarActivitySpaceHeaderFrame], nextValue: () -> [UUID: SidebarActivitySpaceHeaderFrame]) {
        value.merge(nextValue()) { _, new in new }
    }
}

@MainActor
final class SidebarFlightAnimator: ObservableObject {
    nonisolated static let spring = Spring(response: 0.6, dampingRatio: 0.86)

    enum Direction {
        case settle
        case reopen
    }

    struct Glide: Identifiable {
        let id = UUID()
        let tabID: UUID
        let direction: Direction
        let arrivalForm: SidebarRowForm
        let from: CGRect
        var to: CGRect
        let departure: SidebarFlightAppearance
        let arrival: SidebarFlightAppearance
        let launchedAt = Date.now
        var hasArrived = false
    }

    @Published private(set) var glides: [Glide] = []
    @Published private var hiding: Set<UUID> = []
    private var frames: [UUID: SidebarFlightFrame] = [:]
    private var lastSeen: [UUID: CFAbsoluteTime] = [:]

    func shouldHideForFlight(_ id: UUID, form: SidebarRowForm) -> Bool {
        if hiding.contains(id) { return true }
        guard let current = frames[id] else { return false }
        return current.form != form && current.form.isActivity == form.isActivity
    }

    func prepareSettle(_ id: UUID, activity: Bool) {
        prepare(id, direction: .settle, sourceForm: activity ? .activityOpen : .compactOpen, arrivalForm: activity ? .activitySettled : .compactSettled)
    }

    func prepareReopen(_ id: UUID, activity: Bool) {
        prepare(id, direction: .reopen, sourceForm: activity ? .activitySettled : .compactSettled, arrivalForm: activity ? .activityOpen : .compactOpen)
    }

    private func prepare(_ id: UUID, direction: Direction, sourceForm: SidebarRowForm, arrivalForm: SidebarRowForm) {
        guard let current = frames[id], current.form == sourceForm else { return }
        var arrival = current.appearance
        arrival.settled = direction == .settle
        let distance = max(current.frame.height * 5, 160)
        let fallback = current.frame.offsetBy(dx: 0, dy: direction == .settle ? distance : -distance)
        launch(id: id, direction: direction, arrivalForm: arrivalForm, from: current.frame, to: fallback, departure: current.appearance, arrival: arrival)
    }

    func updateFrames(_ newFrames: [UUID: SidebarFlightFrame]) {
        let now = CFAbsoluteTimeGetCurrent()
        for id in Array(frames.keys) where newFrames[id] == nil && now - (lastSeen[id] ?? 0) > 1 {
            frames.removeValue(forKey: id)
            lastSeen.removeValue(forKey: id)
        }
        var launches: [(id: UUID, old: SidebarFlightFrame, new: SidebarFlightFrame)] = []
        var revealsWithoutFlight = false
        for (id, new) in newFrames {
            if let index = glides.firstIndex(where: { $0.tabID == id }),
               glides[index].arrivalForm == new.form,
               Date.now.timeIntervalSince(glides[index].launchedAt) < 0.5 {
                glides[index].to = new.frame
            }
            let alreadyFlying = glides.contains { $0.tabID == id && $0.arrivalForm == new.form }
            if let old = frames[id], old.form != new.form, old.form.isActivity == new.form.isActivity, !alreadyFlying {
                if hypot(old.frame.midX - new.frame.midX, old.frame.midY - new.frame.midY) > 2 {
                    launches.append((id, old, new))
                } else {
                    revealsWithoutFlight = true
                }
            }
            frames[id] = new
            lastSeen[id] = now
        }
        for launch in launches {
            if !self.launch(id: launch.id, direction: launch.new.form == .compactSettled || launch.new.form == .activitySettled ? .settle : .reopen, arrivalForm: launch.new.form, from: launch.old.frame, to: launch.new.frame, departure: launch.old.appearance, arrival: launch.new.appearance) {
                revealsWithoutFlight = true
            }
        }
        if revealsWithoutFlight {
            objectWillChange.send()
        }
    }

    @discardableResult
    private func launch(id: UUID, direction: Direction, arrivalForm: SidebarRowForm, from: CGRect, to: CGRect, departure: SidebarFlightAppearance, arrival: SidebarFlightAppearance) -> Bool {
        guard from.width > 1, from.height > 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        glides.removeAll { $0.tabID == id }
        glides.append(Glide(tabID: id, direction: direction, arrivalForm: arrivalForm, from: from, to: to, departure: departure, arrival: arrival))
        hiding.insert(id)
        return true
    }

    func arrive(_ id: UUID) {
        guard let index = glides.firstIndex(where: { $0.id == id }) else { return }
        glides[index].hasArrived = true
        hiding.remove(glides[index].tabID)
    }

    func finish(_ id: UUID) {
        guard let index = glides.firstIndex(where: { $0.id == id }) else { return }
        let tabID = glides[index].tabID
        glides.remove(at: index)
        if glides.contains(where: { $0.tabID == tabID && !$0.hasArrived }) {
            hiding.insert(tabID)
        } else {
            hiding.remove(tabID)
        }
    }
}

struct SidebarFlightGhostLayer: View {
    @EnvironmentObject private var animator: SidebarFlightAnimator

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(animator.glides) { glide in
                    SidebarFlightGhostView(glide: glide, canvas: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SidebarFlightGhostView: View {
    let glide: SidebarFlightAnimator.Glide
    let canvas: CGSize
    @State private var hasStarted = false
    @EnvironmentObject private var animator: SidebarFlightAnimator

    var body: some View {
        let from = glide.from
        let to = glide.to
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Color.clear
            .keyframeAnimator(initialValue: 0.0, trigger: hasStarted) { _, progress in
                let frame = CGRect(
                    x: from.minX + (to.minX - from.minX) * progress,
                    y: from.minY + (to.minY - from.minY) * progress,
                    width: from.width + (to.width - from.width) * progress,
                    height: from.height + (to.height - from.height) * progress
                )
                let lift = min(Self.smoothstep(0, 0.12, progress), 1 - Self.smoothstep(0.7, 1, progress))
                let endpointFill = glide.departure.fill + (glide.arrival.fill - glide.departure.fill) * progress
                let fill = max(endpointFill, 0.12 * lift)
                ZStack(alignment: .topLeading) {
                    SidebarFlightFace(appearance: glide.departure, size: from.size)
                        .opacity(1 - Self.smoothstep(0.2, 0.65, progress))
                    SidebarFlightFace(appearance: glide.arrival, size: to.size)
                        .opacity(Self.smoothstep(0.35, 0.8, progress))
                }
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .clipShape(shape)
                .background {
                    shape
                        .fill(Color.primary.opacity(fill))
                        .shadow(color: .black.opacity(0.22 * lift), radius: 8, y: 3)
                }
                .position(x: frame.midX, y: frame.midY)
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            } keyframes: { _ in
                SpringKeyframe(1.0, spring: SidebarFlightAnimator.spring)
            }
            .onAppear { hasStarted = true }
            .task {
                let duration = SidebarFlightAnimator.spring.settlingDuration
                try? await Task.sleep(for: .seconds(max(duration - 0.12, 0)))
                animator.arrive(glide.id)
                try? await Task.sleep(for: .seconds(0.12))
                animator.finish(glide.id)
            }
            .opacity(glide.hasArrived ? 0 : 1)
            .animation(.easeOut(duration: 0.12), value: glide.hasArrived)
    }

    private nonisolated static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

private struct SidebarFlightFace: View {
    let appearance: SidebarFlightAppearance
    let size: CGSize

    var body: some View {
        if appearance.activity {
            activityFace
        } else {
            compactFace
        }
    }

    private var compactFace: some View {
        HStack(spacing: appearance.settled ? 7 : 8) {
            if !appearance.settled {
                SidebarTile(symbol: appearance.symbol)
            }
            Text(appearance.title)
                .font(.system(size: appearance.settled ? 12 : 13, weight: !appearance.settled && appearance.selected ? .medium : .regular))
                .foregroundStyle(appearance.settled ? .secondary : .primary)
                .lineLimit(1)
                .padding(.leading, appearance.settled ? 0 : 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: size.width, height: size.height, alignment: .leading)
    }

    private var activityFace: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appearance.title)
                    .font(.system(size: 13, weight: appearance.selected ? .medium : .regular))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: appearance.detailSymbol)
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(appearance.detail ?? "")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let additions = appearance.additions, let deletions = appearance.deletions {
                        Text("·")
                            .font(.system(size: 11))
                        Text("+\(additions)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppColors.reviewAddition)
                        Text("−\(deletions)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppColors.reviewDeletion)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private struct SidebarConditionalClip: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.clipped()
        } else {
            content
        }
    }
}

private struct SidebarFlightFrameReporter: ViewModifier {
    let id: UUID
    let form: SidebarRowForm
    let appearance: SidebarFlightAppearance
    let enabled: Bool

    func body(content: Content) -> some View {
        content.background {
            if enabled {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SidebarFlightFramesPreferenceKey.self,
                        value: [id: SidebarFlightFrame(form: form, frame: proxy.frame(in: .named(SidebarFlightCoordinate.space)), appearance: appearance)]
                    )
                }
            }
        }
    }
}

extension View {
    func sidebarFlightFrame(_ id: UUID, form: SidebarRowForm, appearance: SidebarFlightAppearance = SidebarFlightAppearance(), enabled: Bool = true) -> some View {
        modifier(SidebarFlightFrameReporter(id: id, form: form, appearance: appearance, enabled: enabled))
    }
}

enum SidebarRowGeometryID: Hashable {
    case tab(UUID)
    case settled(UUID)
    case folder(UUID)
    case settledHeader
}

private struct SidebarRowMatch: ViewModifier {
    let id: SidebarRowGeometryID
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
    func sidebarRowMatch(_ id: SidebarRowGeometryID, enabled: Bool = true) -> some View {
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
private let sidebarCompactRowStride = ShellMetrics.sidebarRowHeight + ShellMetrics.sidebarRowSpacing
private let sidebarFallbackActivityRowStride = sidebarCompactRowStride + 15
private let sidebarActivityRowSlide: CGFloat = 15

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
    @State private var visualCollapsed: Bool

    init(model: TerminalModel, sessions: [TerminalSession], width: CGFloat, closeSettledTab: @escaping (UUID) -> Void) {
        self.model = model
        self.sessions = sessions
        self.width = width
        self.closeSettledTab = closeSettledTab
        _visualCollapsed = State(initialValue: UserDefaults.standard.bool(forKey: SidebarDefaults.settledCollapsed))
    }

    private var collapseAnimation: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.32, dampingFraction: 0.9)
    }

    var body: some View {
        if !sessions.isEmpty {
            VStack(spacing: 0) {
                Button {
                    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    let target = !visualCollapsed
                    withAnimation(reduce ? .easeOut(duration: 0.18) : .spring(response: 0.32, dampingFraction: 0.9)) {
                        visualCollapsed = target
                    }
                    collapsed = target
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .rotationEffect(.degrees(visualCollapsed ? 0 : 90))
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
                .buttonStyle(SidebarRowButtonStyle())
                .focusable(false)
                .help(visualCollapsed ? "Show settled tabs" : "Hide settled tabs")
                .accessibilityLabel("Settled, \(sessions.count) tabs")
                .accessibilityValue(visualCollapsed ? "Collapsed" : "Expanded")
                .sidebarRowMatch(.settledHeader)
                .transition(.identity)

                ForEach(sessions) { session in
                    SettledRow(
                        session: session,
                        windowID: model.id,
                        width: width,
                        reportsFrames: true,
                        isSelected: session.id == model.selectedID,
                        open: { model.reveal(session.id) },
                        reopen: { model.reopenTabInAnySpace(session.id) },
                        close: { closeSettledTab(session.id) }
                    )
                    .opacity(visualCollapsed ? 0 : 1)
                    .frame(height: visualCollapsed ? 0 : ShellMetrics.sidebarRowHeight + ShellMetrics.sidebarRowSpacing)
                    .modifier(SidebarConditionalClip(active: visualCollapsed))
                    .allowsHitTesting(!visualCollapsed)
                    .accessibilityHidden(visualCollapsed)
                }
            }
            .onChange(of: collapsed) { _, newValue in
                guard newValue != visualCollapsed else { return }
                withAnimation(collapseAnimation) {
                    visualCollapsed = newValue
                }
            }
            .transition(.identity)
        }
    }
}

/// A settled tab: small and grey, a click away from reopening. Its session keeps running.
private struct SettledRow: View {
    @ObservedObject var session: TerminalSession
    let windowID: UUID
    let width: CGFloat
    let reportsFrames: Bool
    let isSelected: Bool
    let open: () -> Void
    let reopen: () -> Void
    let close: () -> Void

    @ObservedObject private var hover = TabDragCoordinator.shared
    @EnvironmentObject private var flightAnimator: SidebarFlightAnimator
    @AppStorage(SidebarDefaults.activityView) private var activityView = false

    private var isHovered: Bool { hover.hoveredRowKey == session.id }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                Text(session.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, isHovered ? 8 + TabCloseMetrics.side * 2 + 8 : 8)
            .animation(.easeInOut(duration: TabCloseMetrics.fadeDuration), value: isHovered)
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
        .overlay {
            if !activityView {
                TabRowHitRepresentable(
                windowID: windowID,
                tabID: session.id,
                title: session.displayTitle,
                symbol: session.kind == .settings ? "gearshape.fill" : "terminal",
                onSelect: open,
                onClose: close,
                onHover: { _ in },
                onReopen: performReopen,
                allowsDrag: true,
                fillsHeight: true,
                    closeButtonEnabled: true,
                    isFolder: false
                )
            }
        }
        .overlay(alignment: .trailing) {
            ActivityRowActionButton(
                symbol: "checkmark",
                color: .primary,
                help: "Reopen Tab",
                accessibilityLabel: "Reopen \(session.displayTitle)",
                action: performReopen
            )
            .padding(.trailing, TabCloseMetrics.trailingInset + TabCloseMetrics.side + 4)
            .opacity(isHovered ? 1 : 0)
            .animation(.easeInOut(duration: TabCloseMetrics.fadeDuration), value: isHovered)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(!isHovered)
        }
        .focusable(false)
        .contextMenu {
            Button("Open Tab", action: open)
            Button("Reopen Tab", action: performReopen)
            Divider()
            Button("Close Tab", action: close)
        }
        .help("\(session.displayTitle) — \(session.directory)")
        .accessibilityLabel("\(session.displayTitle), settled")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sidebarRowMatch(.settled(session.id))
        .sidebarFlightFrame(
            session.id,
            form: .compactSettled,
            appearance: SidebarFlightAppearance(
                title: session.displayTitle,
                symbol: session.kind == .settings ? "gearshape.fill" : "terminal",
                settled: true,
                selected: isSelected,
                fill: isSelected ? 0.16 : 0
            ),
            enabled: reportsFrames && !activityView
        )
        .opacity(!activityView && flightAnimator.shouldHideForFlight(session.id, form: .compactSettled) ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: flightAnimator.shouldHideForFlight(session.id, form: .compactSettled))
        .transition(.identity)
    }

    private func performReopen() {
        flightAnimator.prepareReopen(session.id, activity: false)
        reopen()
    }
}

private func sidebarFlightFolderName(_ path: String) -> String {
    if path == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? path : name
}

private struct ActivityRowFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Activity layout

/// The sidebar while the activity toggle is on: tabs that want the user first, then
/// every space's open tabs, then everything settled.
struct SidebarActivityList: View {
    @ObservedObject var model: TerminalModel
    let width: CGFloat
    @Binding var compression: CGFloat
    var closeTab: (UUID) -> Void
    var closeSettledTab: (UUID) -> Void
    let renamingTabID: UUID?
    let beginRename: (UUID) -> Void
    let commitRename: (UUID, String) -> Void
    let cancelRename: () -> Void
    @ObservedObject var gitStats: SidebarGitStatsModel
    @AppStorage(SidebarDefaults.activityView) private var activityView = false
    @ObservedObject private var dragCoordinator = TabDragCoordinator.shared
    @EnvironmentObject private var flightAnimator: SidebarFlightAnimator
    @State private var rowFrames: [UUID: CGRect] = [:]

    var body: some View {
        let attention = model.activity
        let attentionIDs = Set(attention.map(\.id))
        let folderAnchors = FolderAnchor.byFirstTab(model)
        let settledIDs = Set(model.settledBySpace.flatMap { $0.tabs.map(\.id) })
        let activeSessionIDs = Set(model.tabs.map(\.id)).union(model.settled.map(\.id))
        let directories = Array(Set(model.allSessions.filter { $0.kind == .terminal }.map { SidebarGitStatsModel.standardized($0.directory) })).sorted()
        let spaceGroups = model.openTabsBySpace
        let spaceVisibleRows = spaceGroups.map { group in
            let rest = group.tabs.filter { !attentionIDs.contains($0.id) }
            return visibleOpenRows(rest, isActiveSpace: group.space.id == model.activeSpaceID)
        }
        let firstDisplayedSpaceIndex = spaceVisibleRows.firstIndex { !$0.isEmpty } ?? 0
        let settledSessions = model.settledBySpace.flatMap(\.tabs).filter { !attentionIDs.contains($0.id) }
        let expansionLayout = sectionExpansionOffsets(
            attention: attention.map(\.session),
            spaceRows: spaceVisibleRows,
            settled: settledSessions,
            rowFrames: rowFrames
        )
        let rowExpansions = expansionLayout.rows
        let settledHeaderExpansion = expansionLayout.settled
        let hasActiveSettledCounterpart = settledSessions.contains { activeSessionIDs.contains($0.id) }
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
                    .offset(y: activeSessionIDs.contains(item.session.id) ? 0 : -activitySlide(for: rowExpansions[item.session.id] ?? 0) * compression)
                    .opacity(activeSessionIDs.contains(item.session.id) ? 1 : 1 - compression)
                }
            }
            ForEach(Array(spaceGroups.enumerated()), id: \.element.space.id) { index, group in
                let rest = group.tabs.filter { !attentionIDs.contains($0.id) }
                let isActiveSpace = group.space.id == model.activeSpaceID
                let visibleRest = visibleOpenRows(rest, isActiveSpace: isActiveSpace)
                if !rest.isEmpty {
                    let precedingRows = attention.map(\.session) + spaceVisibleRows.prefix(index).flatMap { $0 }
                    let expansionOffset = headerExpansionOffset(for: precedingRows, rowFrames: rowFrames)
                    ActivityHeader(title: group.space.name, isFirst: attention.isEmpty && index == firstDisplayedSpaceIndex, width: width)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: SidebarActivitySpaceHeadersPreferenceKey.self,
                                    value: [
                                        group.space.id: SidebarActivitySpaceHeaderFrame(
                                            title: group.space.name,
                                            isFirst: attention.isEmpty && index == firstDisplayedSpaceIndex,
                                            frame: proxy.frame(in: .named(SidebarFlightCoordinate.space)),
                                            expansion: index == firstDisplayedSpaceIndex ? 0 : expansionOffset
                                        )
                                    ]
                                )
                            }
                        }
                        .opacity(0)
                    ForEach(visibleRest) { session in
                        if let pair = activitySplitPair(for: session, in: rest, isActiveSpace: isActiveSpace) {
                            HStack(spacing: 0) {
                                openActivityRow(
                                    session: pair.leading,
                                    width: (width - ShellMetrics.sidebarRowSpacing) / 2,
                                    isInActiveSpace: isActiveSpace,
                                    folderAnchor: folderAnchors[pair.leading.id],
                                    usesFlightFrame: true,
                                    usesRowMatch: false
                                )
                                let splitDividerVisible = dragCoordinator.hoveredRowKey != pair.leading.id
                                    && dragCoordinator.hoveredRowKey != pair.trailing.id
                                    && model.selectedID != pair.leading.id
                                    && model.selectedID != pair.trailing.id
                                ZStack {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.14))
                                        .padding(.vertical, 8)
                                        .opacity(splitDividerVisible ? 1 : 0)
                                        .animation(.easeInOut(duration: 0.14), value: splitDividerVisible)
                                }
                                .frame(width: ShellMetrics.sidebarRowSpacing)
                                openActivityRow(
                                    session: pair.trailing,
                                    width: (width - ShellMetrics.sidebarRowSpacing) / 2,
                                    isInActiveSpace: isActiveSpace,
                                    folderAnchor: nil,
                                    usesFlightFrame: true,
                                    usesRowMatch: false
                                )
                            }
                            .frame(width: width, alignment: .leading)
                            .offset(y: isActiveSpace ? 0 : -activitySlide(for: rowExpansions[pair.leading.id] ?? 0) * compression)
                            .opacity(isActiveSpace ? 1 : 1 - compression)
                            .sidebarRowMatch(.tab(pair.leading.id))
                            .transition(.identity)
                        } else {
                            ActivityTabRow(
                                model: model,
                                session: session,
                                detail: nil,
                                lineStats: gitStats.statsByDirectory[SidebarGitStatsModel.standardized(session.directory)],
                                isSelected: session.id == model.selectedID,
                                isSettled: false,
                                isInActiveSpace: isActiveSpace,
                                width: width,
                                folderAnchor: folderAnchors[session.id],
                                isRenaming: renamingTabID == session.id,
                                beginRename: { beginRename(session.id) },
                                commitRename: { commitRename(session.id, $0) },
                                cancelRename: cancelRename,
                                close: { closeTab(session.id) },
                                action: { model.reveal(session.id) }
                            )
                            .offset(y: isActiveSpace ? 0 : -activitySlide(for: rowExpansions[session.id] ?? 0) * compression)
                            .opacity(isActiveSpace ? 1 : 1 - compression)
                        }
                    }
                }
            }
            if !settledSessions.isEmpty {
                ActivityHeader(title: "Settled", isFirst: attention.isEmpty && model.openTabsBySpace.allSatisfy({ group in group.tabs.allSatisfy { attentionIDs.contains($0.id) } }), width: width)
                    .offset(y: hasActiveSettledCounterpart ? 0 : -settledHeaderExpansion * compression)
                    .sidebarRowMatch(.settledHeader)
                    .transition(.identity)
                ForEach(Array(settledSessions)) { session in
                    ActivityTabRow(
                        model: model,
                        session: session,
                        detail: nil,
                        lineStats: gitStats.statsByDirectory[SidebarGitStatsModel.standardized(session.directory)],
                        isSelected: session.id == model.selectedID,
                        isSettled: true,
                        isInActiveSpace: activeSessionIDs.contains(session.id),
                        width: width,
                        folderAnchor: nil,
                        isRenaming: renamingTabID == session.id,
                        beginRename: { beginRename(session.id) },
                        commitRename: { commitRename(session.id, $0) },
                        cancelRename: cancelRename,
                        close: { closeSettledTab(session.id) },
                        action: { model.reveal(session.id) }
                    )
                    .offset(y: activeSessionIDs.contains(session.id) ? 0 : -activitySlide(for: rowExpansions[session.id] ?? 0) * compression)
                    .opacity(activeSessionIDs.contains(session.id) ? 1 : 1 - compression)
                }
            }
        }
        .coordinateSpace(name: "SidebarActivityRows")
        .overlay(alignment: .topLeading) {
            if let pin = dragCoordinator.pin,
               pin.windowID == model.id,
               let pinY = activityPinY(insertionIndex: pin.insertionIndex) {
                TabInsertionPin(
                    width: width,
                    leadingIndent: pin.folderID == nil ? 0 : ShellMetrics.sidebarGroupSpacing
                )
                .offset(y: pinY)
            }
        }
        .background {
            TabListDropZone(windowID: model.id).frame(width: 0, height: 0)
        }
        .onPreferenceChange(ActivityRowFramesPreferenceKey.self) { rowFrames = $0 }
    }
}

private extension SidebarActivityList {
    func activitySlide(for expansion: CGFloat) -> CGFloat {
        min(expansion, sidebarActivityRowSlide)
    }

    func sectionExpansionOffsets(attention: [TerminalSession], spaceRows: [[TerminalSession]], settled: [TerminalSession], rowFrames: [UUID: CGRect]) -> (rows: [UUID: CGFloat], settled: CGFloat) {
        var rowExpansions: [UUID: CGFloat] = [:]
        var rowsBeforeSections = attention
        for row in rowsBeforeSections { rowExpansions[row.id] = 0 }
        for rows in spaceRows {
            let offset = headerExpansionOffset(for: rowsBeforeSections, rowFrames: rowFrames)
            for row in rows { rowExpansions[row.id] = offset }
            rowsBeforeSections += rows
        }
        let settledOffset = headerExpansionOffset(for: rowsBeforeSections, rowFrames: rowFrames)
        for row in settled { rowExpansions[row.id] = settledOffset }
        return (rowExpansions, settledOffset)
    }

    func headerExpansionOffset(for rows: [TerminalSession], rowFrames: [UUID: CGRect]) -> CGFloat {
        rows.reduce(0) { total, row in
            total + rowExpansion(for: row, rowFrames: rowFrames)
        }
    }

    func rowExpansion(for row: TerminalSession, rowFrames: [UUID: CGRect]) -> CGFloat {
        let stride = rowFrames[row.id]?.height ?? sidebarFallbackActivityRowStride
        return max(0, stride - sidebarCompactRowStride)
    }

    @ViewBuilder
    func openActivityRow(session: TerminalSession, width: CGFloat, isInActiveSpace: Bool, folderAnchor: FolderAnchor?, usesFlightFrame: Bool = true, usesRowMatch: Bool = true) -> some View {
        ActivityTabRow(
            model: model,
            session: session,
            detail: nil,
            lineStats: gitStats.statsByDirectory[SidebarGitStatsModel.standardized(session.directory)],
            isSelected: session.id == model.selectedID,
            isSettled: false,
            isInActiveSpace: isInActiveSpace,
            width: width,
            folderAnchor: folderAnchor,
            isRenaming: renamingTabID == session.id,
            beginRename: { beginRename(session.id) },
            commitRename: { commitRename(session.id, $0) },
            cancelRename: cancelRename,
            close: { closeTab(session.id) },
            action: { model.reveal(session.id) },
            usesFlightFrame: usesFlightFrame,
            usesRowMatch: usesRowMatch
        )
    }

    func visibleOpenRows(_ sessions: [TerminalSession], isActiveSpace: Bool) -> [TerminalSession] {
        guard isActiveSpace else { return sessions }
        let ids = Set(sessions.map(\.id))
        return sessions.filter { session in
            guard let split = model.split(containing: session.id) else { return true }
            return !(split.trailingID == session.id && ids.contains(split.leadingID))
        }
    }

    func activitySplitPair(for session: TerminalSession, in sessions: [TerminalSession], isActiveSpace: Bool) -> (leading: TerminalSession, trailing: TerminalSession)? {
        guard isActiveSpace,
              let split = model.split(containing: session.id),
              split.leadingID == session.id,
              let trailing = sessions.first(where: { $0.id == split.trailingID }) else { return nil }
        return (session, trailing)
    }

    func activityPinY(insertionIndex: Int) -> CGFloat? {
        let rows = rowFrames.values.sorted { $0.minY < $1.minY }
        guard !rows.isEmpty else { return nil }
        let boundary: CGFloat
        if insertionIndex <= 0 {
            boundary = rows[0].minY - rowGapShare
        } else if insertionIndex >= rows.count {
            boundary = rows[rows.count - 1].maxY + rowGapShare
        } else {
            boundary = (rows[insertionIndex - 1].maxY + rows[insertionIndex].minY) / 2
        }
        return boundary - TabInsertionGeometry.pinHeight / 2
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

struct ActivityHeader: View {
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
    var usesFlightFrame = true
    var usesRowMatch = true

    @ObservedObject private var hover = TabDragCoordinator.shared
    @EnvironmentObject private var flightAnimator: SidebarFlightAnimator
    @AppStorage(SidebarDefaults.activityView) private var activityView = false

    private var isHovered: Bool { hover.hoveredRowKey == session.id }

    /// Top and bottom padding of the row; the title's first line sits right below it.
    private static let verticalPadding: CGFloat = 6
    /// One line of 13pt title text.
    private static let titleLineHeight: CGFloat = 16

    private var trailingAccessoryWidth: CGFloat {
        isSettled ? TabCloseMetrics.side * 2 + 4 : TabCloseMetrics.side
    }

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

    @ViewBuilder
    private var rowContent: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                SidebarInlineName(
                    text: session.displayTitle,
                    isSelected: isSelected,
                    isRenaming: isRenaming,
                    onCommit: commitRename,
                    onCancel: cancelRename,
                    horizontalInset: 0
                )
                .padding(.trailing, isHovered ? trailingAccessoryWidth + TabCloseMetrics.trailingInset : 0)
                .animation(.easeInOut(duration: TabCloseMetrics.fadeDuration), value: isHovered)
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
        .padding(.leading, 8)
        .padding(.trailing, 8)
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
                    .sidebarRowMatch(.folder(folderAnchor.id))
            }
        }
        .padding(.vertical, rowGapShare)
        .contentShape(Rectangle())
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ActivityRowFramesPreferenceKey.self,
                    value: [session.id: proxy.frame(in: .named("SidebarActivityRows"))]
                )
            }
        }
    }

    private var rowWithOverlays: some View {
        rowContent
            .overlay {
                if !isRenaming, activityView {
                    hitTarget
                }
            }
            .overlay(alignment: .topTrailing) { reopenAccessory }
            .focusable(false)
            .help(isSettled ? "Open \(session.displayTitle)" : session.directory)
            .accessibilityLabel([session.displayTitle, detailText].joined(separator: ", "))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    var body: some View {
        rowWithOverlays
            .sidebarRowMatch(isSettled ? .settled(session.id) : .tab(session.id), enabled: usesRowMatch)
            .sidebarFlightFrame(
                session.id,
                form: isSettled ? .activitySettled : .activityOpen,
                appearance: SidebarFlightAppearance(
                    title: session.displayTitle,
                    symbol: session.kind == .settings ? "gearshape.fill" : "terminal",
                    detail: detailText,
                    detailSymbol: detailSymbol,
                    additions: lineStats?.additions,
                    deletions: lineStats?.deletions,
                    activity: true,
                    settled: isSettled,
                    selected: isSelected,
                    fill: isSelected ? 0.16 : 0
                ),
                enabled: usesFlightFrame && activityView
            )
            .opacity(usesFlightFrame && activityView && flightAnimator.shouldHideForFlight(session.id, form: isSettled ? .activitySettled : .activityOpen) ? 0 : 1)
            .animation(.easeOut(duration: 0.12), value: flightAnimator.shouldHideForFlight(session.id, form: isSettled ? .activitySettled : .activityOpen))
            .transition(.identity)
    }

    @ViewBuilder
    private var reopenAccessory: some View {
        Group {
            if isSettled {
                ActivityRowActionButton(
                    symbol: "checkmark",
                    color: .primary,
                    help: "Reopen Tab",
                    accessibilityLabel: "Reopen \(session.displayTitle)"
                ) { model.reopenTabInAnySpace(session.id) }
            }
        }
        .padding(.top, rowGapShare + Self.verticalPadding + (Self.titleLineHeight - TabCloseMetrics.side) / 2)
        .padding(.trailing, TabCloseMetrics.trailingInset + TabCloseMetrics.side + 4)
        .opacity(isHovered ? 1 : 0)
        .animation(.easeInOut(duration: TabCloseMetrics.fadeDuration), value: isHovered)
        .allowsHitTesting(isHovered)
        .accessibilityHidden(!isHovered)
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
            onPrepareDrag: { model.prepareSelectionForDrag(session.id) },
            onClose: close,
            onHover: { _ in },
            splitWithActiveEnabled: splitWithActiveEnabled,
            onSplitWithActive: canUseActiveSpaceActions ? { model.split(with: session.id, on: .trailing) } : nil,
            onUnsplit: canUseActiveSpaceActions && model.split(containing: session.id) != nil ? { model.unsplit(tabID: session.id) } : nil,
            onArchive: isOpenTerminal ? {
                flightAnimator.prepareSettle(session.id, activity: true)
                model.settleTabInAnySpace(session.id)
            } : nil,
            onReopen: isSettled ? {
                flightAnimator.prepareReopen(session.id, activity: true)
                model.reopenTabInAnySpace(session.id)
            } : nil,
            onRename: beginRename,
            onDoubleClick: nil,
            onNewFolder: canUseActiveSpaceActions ? { _ = model.makeFolder(containing: session.id) } : nil,
            onRemoveFromFolder: canUseActiveSpaceActions && model.folderContaining(session.id) != nil ? { model.removeFromFolder(session.id) } : nil,
            onDeleteFolder: nil,
            folderDestinations: folderDestinations,
            allowsDrag: true,
            fillsHeight: true,
            closeButtonEnabled: true,
            closeButtonCenterYFromTop: rowGapShare + Self.verticalPadding + Self.titleLineHeight / 2,
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
                .truncationMode(.tail)
            if detail == nil, let lineStats {
                HStack(spacing: 4) {
                    Text("·")
                        .font(.system(size: 11))
                    Text("+\(lineStats.additions)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppColors.reviewAddition)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("−\(lineStats.deletions)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppColors.reviewDeletion)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
            }
        }
        .foregroundStyle(.secondary)
    }

    private static func folderName(_ path: String) -> String {
        sidebarFlightFolderName(path)
    }
}

/// The same hover buttons the tab list draws, as SwiftUI buttons for the activity view's rows.
private struct ActivityRowActionButton: View {
    let symbol: String
    let color: Color
    let help: String
    let accessibilityLabel: String
    let action: () -> Void
    @State private var isHot = false

    var body: some View {
        Button(action: action) {
            Color.clear.frame(width: TabCloseMetrics.side, height: TabCloseMetrics.side)
        }
        .buttonStyle(ActivityRowActionStyle(symbol: symbol, color: color, isHot: isHot))
        .onHover { isHot = $0 }
        .focusable(false)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ActivityRowActionStyle: ButtonStyle {
    let symbol: String
    let color: Color
    var isHot: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SidebarIconStyle.color)
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
