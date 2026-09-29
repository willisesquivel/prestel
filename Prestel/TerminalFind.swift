import AppKit
import SwiftTerm
import SwiftUI

/// One highlighted match, in viewport rows and terminal cell columns.
struct TerminalFindHighlight: Equatable {
    var row: Int
    var column: Int
    var width: Int
}

/// Pure text search over copied terminal rows, kept apart from SwiftTerm so it
/// can be tested without a live view. Navigation and the counter come from
/// SwiftTerm's own search; this only finds what to paint on the visible rows.
enum TerminalFindMatcher {
    /// SwiftTerm caps its match count here.
    static let matchLimit = 1000

    /// Finds every non-overlapping match of `query` in one row and maps it to
    /// cell columns. `cellWidths` uses 2 for a wide cell's leading half and 0
    /// for its trailing half, so characters and columns stay aligned.
    static func highlights(
        row: Int, text: String, cellWidths: [Int], query: String, caseSensitive: Bool
    ) -> [TerminalFindHighlight] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let haystack = Array(text)
        let needle = Array(query)
        guard needle.count <= haystack.count else { return [] }
        // Character index -> first cell column (trailing halves hold no character).
        var columns: [Int] = []
        var spans: [Int] = []
        for (column, width) in cellWidths.enumerated() where width > 0 {
            columns.append(column)
            spans.append(width)
        }
        if columns.count < haystack.count {
            columns = Array(haystack.indices)
            spans = Array(repeating: 1, count: haystack.count)
        }
        let fold: (Character) -> Character = { caseSensitive ? $0 : Character($0.lowercased()) }
        let folded = haystack.map(fold)
        let target = needle.map(fold)
        var result: [TerminalFindHighlight] = []
        var start = 0
        while start + target.count <= folded.count {
            if folded[start..<(start + target.count)].elementsEqual(target) {
                let last = start + target.count - 1
                result.append(TerminalFindHighlight(
                    row: row, column: columns[start],
                    width: columns[last] + spans[last] - columns[start]))
                start += target.count
            } else {
                start += 1
            }
        }
        return result
    }

    static func highlights(
        in rows: [TerminalVisibleRowSnapshot], query: String, caseSensitive: Bool
    ) -> [TerminalFindHighlight] {
        rows.flatMap {
            highlights(row: $0.row, text: $0.text, cellWidths: $0.cellWidths,
                       query: query, caseSensitive: caseSensitive)
        }
    }

    /// "3 of 12" style counter; a capped total reads "12+".
    static func counter(index: Int, total: Int, limit: Int = matchLimit) -> String {
        if total == 0 { return "No results" }
        let count = total >= limit ? "\(total)+" : "\(total)"
        return index > 0 ? "\(index) of \(count)" : count
    }
}

/// Find-in-terminal state for one window. SwiftTerm owns the current match
/// (it selects it and scrolls it into view); an overlay on the surface paints
/// every other visible match.
@MainActor
final class TerminalFind: ObservableObject {
    @Published private(set) var isVisible = false
    @Published var query = ""
    @Published var caseSensitive = false
    @Published private(set) var index = 0
    @Published private(set) var total = 0
    /// Bumped whenever the field should take (or retake) keyboard focus.
    @Published private(set) var focusRequest = 0

    private weak var surface: PrestelView?
    private var refreshTask: Task<Void, Never>?

    private var options: SearchOptions { SearchOptions(caseSensitive: caseSensitive) }

    func show(on surface: PrestelView?) {
        attach(surface)
        isVisible = true
        focusRequest &+= 1
        if !query.isEmpty { search() }
    }

    /// Called when the selected tab changes while the bar is open.
    func attach(_ newSurface: PrestelView?) {
        guard newSurface !== surface else { return }
        detach()
        surface = newSurface
        newSurface?.onViewportChange = { [weak self] in self?.scheduleRefresh() }
        if isVisible, !query.isEmpty { search() }
    }

    func hide(returningFocusTo window: NSWindow?) {
        guard isVisible else { return }
        isVisible = false
        let closing = surface
        detach()
        index = 0
        total = 0
        if let closing, closing.window != nil {
            (window ?? closing.window)?.makeFirstResponder(closing)
        }
    }

    /// Re-runs the search from scratch (query or options changed).
    func search() {
        guard let surface else { return }
        surface.clearSearch()
        guard !query.isEmpty else {
            index = 0
            total = 0
            surface.findHighlights = []
            return
        }
        surface.findNext(query, options: options)
        refresh()
    }

    func next() { step(forward: true) }
    func previous() { step(forward: false) }

    private func step(forward: Bool) {
        guard let surface, !query.isEmpty else { return }
        if forward {
            surface.findNext(query, options: options)
        } else {
            surface.findPrevious(query, options: options)
        }
        refresh()
    }

    /// Output and scrolling move matches around; coalesce the recount.
    private func scheduleRefresh() {
        guard isVisible, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.refresh()
        }
    }

    private func refresh() {
        guard let surface, !query.isEmpty else { return }
        let summary = surface.searchMatchSummary(query, options: options, limit: TerminalFindMatcher.matchLimit)
        index = summary.index
        total = summary.total
        surface.findHighlights = TerminalFindMatcher.highlights(
            in: surface.terminalStateSnapshot().visibleRows,
            query: query, caseSensitive: caseSensitive)
    }

    private func detach() {
        refreshTask?.cancel()
        refreshTask = nil
        surface?.onViewportChange = nil
        surface?.findHighlights = []
        surface?.clearSearch()
        surface = nil
    }
}

/// Transparent layer over the terminal that paints match highlights.
/// It never takes hits, so selection and scrolling reach the terminal.
final class TerminalFindOverlay: NSView {
    var highlights: [TerminalFindHighlight] = [] { didSet { if highlights != oldValue { needsDisplay = true } } }
    var cellSize: CGSize = .zero { didSet { if cellSize != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func animation(forKey key: NSAnimatablePropertyKey) -> Any? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard cellSize.width > 0, cellSize.height > 0 else { return }
        NSColor.systemYellow.withAlphaComponent(0.38).setFill()
        for match in highlights {
            let rect = NSRect(
                x: CGFloat(match.column) * cellSize.width,
                y: CGFloat(match.row) * cellSize.height,
                width: CGFloat(match.width) * cellSize.width,
                height: cellSize.height)
            guard rect.intersects(dirtyRect) else { continue }
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 3, yRadius: 3).fill()
        }
    }
}

/// Observes `find` directly (nested objects don't re-render their parent)
/// and hosts the bar only over a terminal tab.
struct TerminalFindHost: View {
    @ObservedObject var model: TerminalModel
    @ObservedObject var find: TerminalFind

    var body: some View {
        ZStack {
            if find.isVisible, model.selectedTab?.kind == .terminal {
                TerminalFindBar(find: find) { find.hide(returningFocusTo: NSApp.keyWindow) }
                    .padding(.top, ShellMetrics.navigationHeight + 24) // clears the toolbar row
                    .padding(.trailing, 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(find.isVisible)
        .animation(.easeOut(duration: 0.16), value: find.isVisible)
    }
}

/// Compact glass find bar, overlaid at the top-right of the terminal surface.
struct TerminalFindBar: View {
    @ObservedObject var find: TerminalFind
    let close: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var fieldFocused: Bool

    private var hasQuery: Bool { !find.query.isEmpty }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Find", text: $find.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .frame(width: 120)
                    .onKeyPress(.return, phases: .down) { press in
                        press.modifiers.contains(.shift) ? find.previous() : find.next()
                        return .handled
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        close()
                        return .handled
                    }
                    .accessibilityLabel("Find in terminal")
                if hasQuery {
                    Text(TerminalFindMatcher.counter(index: find.index, total: find.total))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel("Matches")
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: ShellMetrics.searchHeight)
            .background { Capsule().fill(.quaternary) }

            HStack(spacing: 0) {
                FindBarButton(symbol: "textformat", help: "Match case", isOn: find.caseSensitive) {
                    find.caseSensitive.toggle()
                }
                FindBarButton(symbol: "chevron.up", help: "Previous match (⇧⌘G)", isEnabled: find.total > 0) {
                    find.previous()
                }
                FindBarButton(symbol: "chevron.down", help: "Next match (⌘G)", isEnabled: find.total > 0) {
                    find.next()
                }
                FindBarButton(symbol: "xmark", help: "Close (Esc)", action: close)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: ShellMetrics.searchHeight + 8)
        .chromeGlass()
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.32 : 0.12), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .onAppear { fieldFocused = true }
        .onChange(of: find.focusRequest) { fieldFocused = true }
        .onChange(of: find.query) { find.search() }
        .onChange(of: find.caseSensitive) { find.search() }
    }
}

private struct FindBarButton: View {
    let symbol: String
    let help: String
    var isOn = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(isEnabled ? 0.72 : 0.22))
                .frame(width: 26, height: 26)
                .background { if isOn { Circle().fill(Color.accentColor.opacity(0.16)) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
