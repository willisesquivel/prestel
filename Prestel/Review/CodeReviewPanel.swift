import AppKit
import SwiftUI

struct CodeReviewPanel: View {
    private enum ControlsMetrics {
        static let minimumTitleWidthForLabeledCommit: CGFloat = 52
    }

    @ObservedObject var model: CodeReviewModel
    var visible: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastVisibleLoadState: ReviewLoadState = .hidden
    @State private var frozenPaint: ReviewSlidePaint?
    @State private var freezeToken = UUID()

    var body: some View {
        Group {
            switch painted.loadState {
            case .hidden, .resolving, .loading:
                if painted.hasSnapshot, let snapshot = model.snapshot {
                    fileListScroll(snapshot)
                } else {
                    statusPage { ReviewStatus(symbol: "progress.indicator", text: "Loading repository changes…", spinning: true) }
                }
            case .noTerminal:
                statusPage { ReviewStatus(symbol: "terminal", text: "Select a terminal to review its repository.") }
            case .noRepository:
                statusPage { ReviewStatus(symbol: "folder", text: "The current terminal is not inside a Git repository.") }
            case .noWorkingTree:
                statusPage { ReviewStatus(symbol: "internaldrive", text: "This repository has no working tree.") }
            case .unavailable(let message):
                statusPage { ReviewStatus(symbol: "exclamationmark.triangle", text: "Git could not be executed.", detail: message, retry: { model.refresh() }) }
            case .error(let message):
                statusPage { ReviewStatus(symbol: "exclamationmark.triangle", text: "Repository changes could not be loaded.", detail: message, retry: { model.refresh() }) }
            case .waitingForGit:
                statusPage { ReviewStatus(symbol: "hourglass", text: "Waiting for the Git operation to finish.", retry: { model.refresh() }) }
            case .ready:
                if painted.hasSnapshot, let snapshot = model.snapshot {
                    if snapshot.isClean, model.presentation.filter == .all {
                        statusPage { ReviewStatus(symbol: "checkmark.circle", text: "No uncommitted changes.") }
                    } else {
                        fileListScroll(snapshot)
                    }
                } else {
                    statusPage { ReviewStatus(symbol: "progress.indicator", text: "Loading repository changes…", spinning: true) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .onAppear { rememberVisibleLoadState(model.loadState) }
        .onChange(of: model.loadState) { _, newValue in
            rememberVisibleLoadState(newValue)
        }
        .onChange(of: visible) { _, _ in
            freezePaintedContentForSlide()
        }
        .onChange(of: colorScheme) { _, newValue in
            model.updateAppearance(newValue == .dark)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code Review")
    }

    /// Bind() sets `.hidden` immediately on close so watchers stop. Keep painting
    /// the last real state so the tab can slide away instead of popping out.
    private var displayedLoadState: ReviewLoadState {
        ReviewDisplayedLoadState.resolve(
            loadState: model.loadState,
            lastVisible: lastVisibleLoadState,
            hasSnapshot: model.snapshot != nil
        )
    }

    private var painted: ReviewSlidePaint {
        frozenPaint ?? ReviewSlidePaint(
            loadState: displayedLoadState,
            hasSnapshot: model.snapshot != nil
        )
    }

    private func rememberVisibleLoadState(_ state: ReviewLoadState) {
        if state != .hidden {
            lastVisibleLoadState = state
        }
    }

    /// Bind can publish `.ready` while the offset is still interpolating. A new
    /// file-list identity then appears at rest. Hold the current paint until
    /// the sidebar-matching slide finishes.
    private func freezePaintedContentForSlide() {
        let token = UUID()
        freezeToken = token
        frozenPaint = ReviewSlidePaint(
            loadState: displayedLoadState,
            hasSnapshot: model.snapshot != nil
        )
        let delay = reduceMotion ? 0 : ShellMetrics.sidebarAnimationDuration
        Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard freezeToken == token else { return }
            frozenPaint = nil
            // The slide is over. A closed panel was still mounted offscreen with
            // the last file list, so its diff text and views lived until quit.
            if !visible {
                lastVisibleLoadState = .hidden
                model.releaseHiddenContents()
            }
        }
    }

    private var barSnapshot: ReviewSnapshot? {
        switch painted.loadState {
        case .hidden, .resolving, .loading, .ready:
            return painted.hasSnapshot ? model.snapshot : nil
        default:
            return nil
        }
    }

    private var isCleanStatus: Bool {
        if case .ready = painted.loadState,
           painted.hasSnapshot,
           let snapshot = model.snapshot,
           snapshot.isClean,
           model.presentation.filter == .all {
            return true
        }
        return false
    }

    @ViewBuilder
    private func statusPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            if let snapshot = barSnapshot {
                panelBar(snapshot)
            }
        }
        .scrollEdgeEffectStyle(.hard, for: .vertical)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func fileListScroll(_ snapshot: ReviewSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: ShellMetrics.sidebarInset) {
                    ForEach(model.visibleFiles(in: snapshot)) { file in
                        ReviewFileCard(
                            model: model,
                            file: file,
                            paneHeight: paneHeight(for: file),
                            onEscape: { model.onRestoreTerminalFocus?() },
                            onCollapseWhilePinned: {
                                // Wait for the collapse to lay out. Scrolling against the
                                // pre-collapse content height can leave the offset past the
                                // shrunken content, which renders as an empty list.
                                Task { @MainActor in
                                    await Task.yield()
                                    var transaction = Transaction()
                                    transaction.animation = nil
                                    withTransaction(transaction) {
                                        proxy.scrollTo(file.id, anchor: .top)
                                    }
                                }
                            }
                        )
                        .id(file.id)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ShellMetrics.sidebarInset)
                .padding(.top, ShellMetrics.sidebarInset)
                .padding(.bottom, ShellMetrics.sidebarInset)
            }
            // AppKit needs the native scroller to render the safe-area edge effect.
            .scrollIndicators(.automatic)
            .safeAreaBar(edge: .top, spacing: 0) {
                panelBar(snapshot)
            }
            .scrollClipDisabled()
            .scrollEdgeEffectStyle(.hard, for: .vertical)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func panelBar(_ snapshot: ReviewSnapshot) -> some View {
        VStack(spacing: 0) {
            header(snapshot)
            if !isCleanStatus {
                controls(snapshot)
            }
        }
        .padding(.top, 12)
        // 6pt here + the 6pt control bottom = 12pt below the bar, matching
        // the sidebar bar rhythm.
        .padding(.bottom, 6)
    }

    /// Panes size to their full content height: the file list is the only
    /// vertical scroller, diffs scroll horizontally within their pane.
    private func paneHeight(for file: ChangedFile) -> CGFloat {
        let rows = ReviewDocumentBuilder.bodyRows(file: file, diffs: model.diffs, presentation: model.presentation)
        return max(ReviewDocumentBuilder.contentHeight(of: rows), 36)
    }

    private func header(_ snapshot: ReviewSnapshot) -> some View {
        let totals = model.filteredTotals(in: snapshot)
        return HStack(alignment: .center, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.revision.key.basename)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .help(snapshot.revision.key.worktreeRoot)
            Text(branchLabel(snapshot))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text("\(totals.count) file\(totals.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Text("+\(totals.additions)")
                    .foregroundStyle(AppColors.reviewAddition)
                Text("−\(totals.deletions)")
                    .foregroundStyle(AppColors.reviewDeletion)
            }
            .font(.system(size: 11, design: .monospaced))
            .help(totalsHelp(snapshot))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ShellMetrics.sidebarInset)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .contextMenu {
            Button("Copy Repository Path") { model.copyRepositoryPath() }
        }
    }

    private func controls(_ snapshot: ReviewSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            controlsRow(snapshot, symbolOnly: false)
            controlsRow(snapshot, symbolOnly: true)
        }
        .focusable(false)
        .padding(.horizontal, ShellMetrics.sidebarInset)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }

    private func controlsRow(_ snapshot: ReviewSnapshot, symbolOnly: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Uncommitted changes")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(
                    minWidth: symbolOnly ? 0 : ControlsMetrics.minimumTitleWidthForLabeledCommit,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            Button {
                model.openCommitComposer()
            } label: {
                Group {
                    if symbolOnly {
                        Image(systemName: "checkmark.circle")
                            .frame(width: ShellMetrics.navigationHeight)
                    } else {
                        Label("Commit", systemImage: "checkmark.circle")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 12)
                    }
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(snapshot.waitingOnIndexLock ? 0.25 : 0.78))
                .frame(height: ShellMetrics.navigationHeight)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .chromeGlass()
            .disabled(snapshot.waitingOnIndexLock)
            .help(snapshot.waitingOnIndexLock ? "Wait for the Git operation to finish." : "Commit these changes")
            .accessibilityLabel("Commit changes")

            HStack(spacing: 0) {
                Menu {
                    ForEach(ReviewFilter.allCases) { filter in
                        Button(filter.title) { model.setFilter(filter) }
                    }
                } label: {
                    ReviewChromeSymbol(symbol: "line.3.horizontal.decrease")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Filter")
                .accessibilityLabel("Filter")

                ChromeDivider()

                Button {
                    model.refresh()
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ReviewChromeSymbol(symbol: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .accessibilityLabel("Refresh")

                ChromeDivider()

                Menu {
                    Button("Expand All") { model.expandAll() }
                    Button("Collapse All") { model.collapseAll() }
                    Button(model.showWhitespace ? "Hide Whitespace" : "Show Whitespace") {
                        model.showWhitespace.toggle()
                    }
                    Button(model.expandFilesByDefault ? "Collapse Files by Default" : "Expand Files by Default") {
                        model.expandFilesByDefault.toggle()
                    }
                    Divider()
                    Button("Copy Repository Path") { model.copyRepositoryPath() }
                } label: {
                    ReviewChromeSymbol(symbol: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("More")
                .accessibilityLabel("More")
            }
            .frame(width: 118, height: ShellMetrics.navigationHeight)
            .chromeGlass()
            .accessibilityElement(children: .contain)
        }
    }

    private func branchLabel(_ snapshot: ReviewSnapshot) -> String {
        if snapshot.revision.isDetached {
            let short = snapshot.revision.headOID.map { String($0.prefix(7)) } ?? "HEAD"
            return "Detached · \(short)"
        }
        if snapshot.revision.isUnborn {
            return "\(snapshot.revision.branchName ?? "main") · No commits yet"
        }
        return snapshot.revision.branchName ?? "—"
    }

    private func totalsHelp(_ snapshot: ReviewSnapshot) -> String {
        if snapshot.files.contains(where: { $0.comparisons.count > 1 }) {
            return "Counts sum staged and unstaged comparisons, not a net HEAD-to-working-tree measurement."
        }
        return "Additions and deletions for the active filter."
    }
}

/// A symbol sized like the navigation capsule’s buttons, filling its segment.
private struct ReviewChromeSymbol: View {
    var symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.72))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

private struct ReviewStatus: View {
    var symbol: String
    var text: String
    var detail: String? = nil
    var retry: (() -> Void)? = nil
    var spinning = false

    var body: some View {
        VStack(spacing: 8) {
            if spinning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            if let retry {
                Button("Retry", action: retry)
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}

struct ReviewResizeHandle: NSViewRepresentable {
    let height: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onReset: () -> Void
    let onIncrement: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReviewResizeNSView {
        ReviewResizeNSView()
    }

    func updateNSView(_ nsView: ReviewResizeNSView, context: Context) {
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
        nsView.onReset = onReset
        nsView.onIncrement = onIncrement
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReviewResizeNSView, context: Context) -> CGSize? {
        CGSize(width: 10, height: height)
    }
}

final class ReviewResizeNSView: NSView {
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?
    var onReset: (() -> Void)?
    var onIncrement: ((CGFloat) -> Void)?
    private var dragStartX: CGFloat?

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        dragStartX = event.locationInWindow.x
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        onChanged?(dragStartX - event.locationInWindow.x)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        onEnded?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onIncrement?(-16)
        case 124: onIncrement?(16)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .incrementor }
    override func accessibilityLabel() -> String? { "Code Review divider" }
    override func accessibilityValue() -> Any? { nil }
}

struct ReviewHairline: View {
    @Environment(\.displayScale) private var scale
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1 / max(scale, 1))
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}

/// Visual load-state for the review panel. First-open bind publishes
/// `.resolving` after the slide starts; keep that on `.hidden` so the
/// spinner already off-screen is the same view that moves into place.
enum ReviewDisplayedLoadState {
    static func resolve(
        loadState: ReviewLoadState,
        lastVisible: ReviewLoadState,
        hasSnapshot: Bool
    ) -> ReviewLoadState {
        if loadState == .hidden, lastVisible != .hidden {
            return lastVisible
        }
        switch loadState {
        case .resolving, .loading:
            return hasSnapshot ? loadState : .hidden
        default:
            return loadState
        }
    }
}

struct ReviewSlidePaint: Equatable {
    var loadState: ReviewLoadState
    var hasSnapshot: Bool
}
