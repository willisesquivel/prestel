import AppKit
import SwiftUI

struct CodeReviewPanel: View {
    @ObservedObject var model: CodeReviewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            switch model.loadState {
            case .hidden:
                ReviewStatus(symbol: "progress.indicator", text: "Loading repository changes…", spinning: true)
            case .noTerminal:
                ReviewStatus(symbol: "terminal", text: "Select a terminal to review its repository.")
            case .noRepository:
                ReviewStatus(symbol: "folder", text: "The current terminal is not inside a Git repository.")
            case .noWorkingTree:
                ReviewStatus(symbol: "internaldrive", text: "This repository has no working tree.")
            case .unavailable(let message):
                ReviewStatus(symbol: "exclamationmark.triangle", text: "Git could not be executed.", detail: message, retry: { model.refresh() })
            case .error(let message):
                ReviewStatus(symbol: "exclamationmark.triangle", text: "Repository changes could not be loaded.", detail: message, retry: { model.refresh() })
            case .waitingForGit:
                ReviewStatus(symbol: "hourglass", text: "Waiting for the Git operation to finish.", retry: { model.refresh() })
            case .resolving, .loading:
                if let snapshot = model.snapshot {
                    content(snapshot)
                } else {
                    ReviewStatus(symbol: "progress.indicator", text: "Loading repository changes…", spinning: true)
                }
            case .ready:
                if let snapshot = model.snapshot {
                    if snapshot.isClean, model.presentation.filter == .all {
                        header(snapshot)
                        ReviewStatus(symbol: "checkmark.circle", text: "No uncommitted changes.")
                    } else {
                        content(snapshot)
                    }
                } else {
                    ReviewStatus(symbol: "progress.indicator", text: "Loading repository changes…", spinning: true)
                }
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .onChange(of: colorScheme) { _, newValue in
            model.updateAppearance(newValue == .dark)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code Review")
    }

    @ViewBuilder
    private func content(_ snapshot: ReviewSnapshot) -> some View {
        header(snapshot)
        controls(snapshot)
        ReviewFileListHost(
            model: model,
            files: model.visibleFiles(in: snapshot),
            onEscape: { model.onRestoreTerminalFocus?() },
            onFocusChange: { _ in }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ snapshot: ReviewSnapshot) -> some View {
        let totals = model.filteredTotals(in: snapshot)
        return VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.revision.key.basename)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .help(snapshot.revision.key.worktreeRoot)
            Text(branchLabel(snapshot))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("\(totals.count) file\(totals.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Text("+\(totals.additions)")
                    .foregroundStyle(Color(nsColor: .systemGreen))
                Text("−\(totals.deletions)")
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
            .font(.system(size: 11, design: .monospaced))
            .help(totalsHelp(snapshot))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ShellMetrics.sidebarHorizontalInset)
        .padding(.top, 0)
        .padding(.bottom, 6)
        .contextMenu {
            Button("Copy Repository Path") { model.copyRepositoryPath() }
        }
    }

    private func controls(_ snapshot: ReviewSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("Uncommitted changes")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            Menu {
                ForEach(ReviewFilter.allCases) { filter in
                    Button(filter.title) { model.setFilter(filter) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .help("Filter")
            Button {
                model.refresh()
            } label: {
                Group {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Refresh")
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
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .help("More")
        }
        .padding(.horizontal, ShellMetrics.sidebarHorizontalInset)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
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
