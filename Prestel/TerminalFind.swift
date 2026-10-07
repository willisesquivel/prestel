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
    private var resetTask: Task<Void, Never>?

    private var options: SearchOptions { SearchOptions(caseSensitive: caseSensitive) }

    func show(on surface: PrestelView?) {
        resetTask?.cancel()
        resetTask = nil
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
        // The bar fades out showing what it last showed; the counter resets only
        // once it is gone, so it never flashes "No results" while closing.
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, !self.isVisible else { return }
            self.resetTask = nil
            self.index = 0
            self.total = 0
        }
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

/// Widths for the find pill. The field is the part that gives up space, so the
/// bar stays inside the terminal when Code Review (or a split) narrows it.
enum FindBarLayout {
    static let barHeight: CGFloat = 36
    static let preferredFieldWidth: CGFloat = 96
    static let counterWidth: CGFloat = 56
    static let iconWidth: CGFloat = 14
    static let buttonWidth: CGFloat = 28
    static let buttonCount = 4
    static let spacing: CGFloat = 6
    static let leadingPadding: CGFloat = 12
    static let trailingPadding: CGFloat = 4
    static let outerLeading: CGFloat = 12
    static let outerTrailing: CGFloat = 20

    struct Metrics: Equatable {
        var fieldWidth: CGFloat
        var counterWidth: CGFloat
        var buttonWidth: CGFloat
        var leadingPadding: CGFloat
        var trailingPadding: CGFloat
        var outerLeading: CGFloat
        var outerTrailing: CGFloat

        var contentWidth: CGFloat {
            leadingPadding
                + FindBarLayout.iconWidth
                + FindBarLayout.spacing * 3
                + fieldWidth
                + counterWidth
                + buttonWidth * CGFloat(FindBarLayout.buttonCount)
                + trailingPadding
        }

        var occupiedWidth: CGFloat { contentWidth + outerLeading + outerTrailing }
    }

    static func metrics(forSurfaceWidth surfaceWidth: CGFloat) -> Metrics {
        var metrics = Metrics(
            fieldWidth: preferredFieldWidth,
            counterWidth: counterWidth,
            buttonWidth: buttonWidth,
            leadingPadding: leadingPadding,
            trailingPadding: trailingPadding,
            outerLeading: outerLeading,
            outerTrailing: outerTrailing
        )
        guard surfaceWidth.isFinite else { return metrics }
        var overflow = max(0, metrics.occupiedWidth - max(0, surfaceWidth))
        // The query field shrinks first, then the counter, then the margins.
        // Buttons stay full size until there is nothing else to give up.
        take(&overflow, from: &metrics.fieldWidth, floor: 48)
        take(&overflow, from: &metrics.counterWidth, floor: 40)
        take(&overflow, from: &metrics.outerLeading, floor: 8)
        take(&overflow, from: &metrics.outerTrailing, floor: 8)
        take(&overflow, from: &metrics.fieldWidth, floor: 0)
        take(&overflow, from: &metrics.counterWidth, floor: 0)
        takeButtons(&overflow, metrics: &metrics, floor: 20)
        take(&overflow, from: &metrics.leadingPadding, floor: 6)
        take(&overflow, from: &metrics.trailingPadding, floor: 2)
        take(&overflow, from: &metrics.outerLeading, floor: 4)
        take(&overflow, from: &metrics.outerTrailing, floor: 4)
        takeButtons(&overflow, metrics: &metrics, floor: 16)
        return metrics
    }

    private static func take(_ overflow: inout CGFloat, from value: inout CGFloat, floor: CGFloat) {
        let cut = min(overflow, max(0, value - floor))
        value -= cut
        overflow -= cut
    }

    private static func takeButtons(_ overflow: inout CGFloat, metrics: inout Metrics, floor: CGFloat) {
        let slack = max(0, (metrics.buttonWidth - floor) * CGFloat(buttonCount))
        let cut = min(overflow, slack)
        metrics.buttonWidth -= cut / CGFloat(buttonCount)
        overflow -= cut
    }
}

/// Observes `find` directly (nested objects don't re-render their parent)
/// and hosts the bar only over a terminal tab.
struct TerminalFindHost: View {
    @ObservedObject var model: TerminalModel
    @ObservedObject var find: TerminalFind

    var body: some View {
        GeometryReader { proxy in
            let metrics = FindBarLayout.metrics(forSurfaceWidth: proxy.size.width)
            ZStack(alignment: .topTrailing) {
                if find.isVisible, model.selectedTab?.kind == .terminal {
                    TerminalFindBar(find: find, metrics: metrics) {
                        find.hide(returningFocusTo: NSApp.keyWindow)
                    }
                    .padding(.top, ShellMetrics.navigationHeight + 24) // clears the toolbar row
                    .padding(.trailing, metrics.outerTrailing)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
        }
        .allowsHitTesting(find.isVisible)
        .animation(.easeOut(duration: 0.16), value: find.isVisible)
    }
}

/// Compact glass find bar, overlaid at the top-right of the terminal surface.
/// The counter keeps its slot so typing does not reflow the pill; only the
/// terminal width changes the field.
struct TerminalFindBar: View {
    @ObservedObject var find: TerminalFind
    var metrics: FindBarLayout.Metrics
    let close: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var hasQuery: Bool { !find.query.isEmpty }

    var body: some View {
        HStack(spacing: FindBarLayout.spacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.55))
                .frame(width: FindBarLayout.iconWidth, height: FindBarLayout.iconWidth)
            FindTextField(
                text: $find.query,
                focusRequest: find.focusRequest,
                onNext: { find.next() },
                onPrevious: { find.previous() },
                onEscape: close
            )
            .frame(width: metrics.fieldWidth)
            .accessibilityLabel("Find in terminal")
            Text(TerminalFindMatcher.counter(index: find.index, total: find.total))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: metrics.counterWidth, alignment: .trailing)
                .opacity(hasQuery ? 1 : 0)
                .accessibilityHidden(!hasQuery)
                .accessibilityLabel("Matches")
            HStack(spacing: 0) {
                FindBarButton(symbol: "textformat", help: "Match case", width: metrics.buttonWidth, isOn: find.caseSensitive) {
                    find.caseSensitive.toggle()
                }
                FindBarButton(symbol: "chevron.up", help: "Previous match (⇧⌘G)", width: metrics.buttonWidth, isEnabled: find.total > 0) {
                    find.previous()
                }
                FindBarButton(symbol: "chevron.down", help: "Next match (⌘G)", width: metrics.buttonWidth, isEnabled: find.total > 0) {
                    find.next()
                }
                FindBarButton(symbol: "xmark", help: "Close (Esc)", width: metrics.buttonWidth, action: close)
            }
        }
        .padding(.leading, metrics.leadingPadding)
        .padding(.trailing, metrics.trailingPadding)
        .frame(height: FindBarLayout.barHeight)
        .chromeGlass()
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.32 : 0.12), radius: 10, y: 4)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .onChange(of: find.query) { find.search() }
        .onChange(of: find.caseSensitive) { find.search() }
    }
}

/// An AppKit field so focus is explicit: the bar takes first responder itself
/// (on appear and on every ⌘F) instead of relying on SwiftUI focus, which could
/// fall through to another text view in the window's key-view loop.
struct FindTextField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FindEditorView {
        let field = FindEditorView()
        field.stringValue = text
        context.coordinator.focusRequest = focusRequest
        field.requestFocus()
        return field
    }

    func updateNSView(_ field: FindEditorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.onTextChange = { coordinator.parent?.text = $0 }
        field.onNext = onNext
        field.onPrevious = onPrevious
        field.onEscape = onEscape
        if field.window?.firstResponder !== field.textView, field.stringValue != text {
            field.stringValue = text
        }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            field.requestFocus()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FindEditorView, context: Context) -> CGSize? {
        // Fill the row. The text view centers its line inside that height, so the
        // first layout matches later ones instead of sitting on the top baseline.
        CGSize(width: proposal.width ?? FindBarLayout.preferredFieldWidth, height: FindBarLayout.barHeight)
    }

    final class Coordinator {
        var parent: FindTextField?
        var focusRequest = 0
    }
}

/// One scrolling line, vertically centered in the find pill from the first layout.
final class FindEditorView: NSScrollView {
    /// Room for the caret, outside the scrolled document. The stroke is 2pt and
    /// centered on the insertion point, so 1pt hangs off both sides; the glow
    /// hangs 5pt. Inset on the text container scrolls under the clip once the
    /// line is wider than the field. These insets belong to the clip view, so
    /// the same margin stays at either end of the line.
    static let caretLeadingInset: CGFloat = 5

    let textView = FindLineTextView()
    private var isUpdatingCaretInsets = false

    var onTextChange: ((String) -> Void)? {
        get { textView.onTextChange }
        set { textView.onTextChange = newValue }
    }
    var onNext: (() -> Void)? {
        get { textView.onNext }
        set { textView.onNext = newValue }
    }
    var onPrevious: (() -> Void)? {
        get { textView.onPrevious }
        set { textView.onPrevious = newValue }
    }
    var onEscape: (() -> Void)? {
        get { textView.onEscape }
        set { textView.onEscape = newValue }
    }

    var stringValue: String {
        get { textView.string }
        set {
            guard textView.string != newValue else { return }
            textView.string = newValue
            textView.centerLine()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: FindBarLayout.barHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        focusRingType = .none
        documentView = textView
    }

    /// Keeps the caret's overhang inside the clip without padding the document.
    /// Reapplied from layout because a scroll view will otherwise take content
    /// insets from the window.
    func applyCaretInsets() {
        guard !isUpdatingCaretInsets else { return }
        isUpdatingCaretInsets = true
        defer { isUpdatingCaretInsets = false }
        automaticallyAdjustsContentInsets = false
        let clip = contentView
        clip.automaticallyAdjustsContentInsets = false
        clip.drawsBackground = false
        let insets = NSEdgeInsets(
            top: 0, left: Self.caretLeadingInset, bottom: 0, right: Self.caretLeadingInset)
        let current = clip.contentInsets
        guard current.top != insets.top || current.left != insets.left
            || current.bottom != insets.bottom || current.right != insets.right else { return }
        clip.contentInsets = insets
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func requestFocus() { textView.requestFocus() }

    override func layout() {
        super.layout()
        guard !isUpdatingCaretInsets else { return }
        applyCaretInsets()
        let height = contentSize.height > 1 ? contentSize.height : bounds.height
        let width = max(textView.frame.width, contentSize.width)
        if abs(textView.frame.height - height) > 0.5 || textView.frame.width < width {
            textView.setFrameSize(NSSize(width: width, height: height))
        }
        textView.centerLine()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }

    override func animation(forKey key: NSAnimatablePropertyKey) -> Any? { nil }
}

final class FindLineTextView: NSTextView {
    var onTextChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onEscape: (() -> Void)?
    private var pendingFocus = false
    private var isCentering = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    private func configure() {
        drawsBackground = false
        isRichText = false
        isFieldEditor = false
        allowsUndo = true
        isEditable = true
        isSelectable = true
        insertionPointColor = .controlAccentColor
        font = .systemFont(ofSize: 13)
        textColor = .labelColor
        focusRingType = .none
        isVerticallyResizable = false
        isHorizontallyResizable = true
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        clipsToBounds = false
        textContainer?.lineFragmentPadding = 0
        textContainer?.maximumNumberOfLines = 1
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        defaultParagraphStyle = paragraph
        typingAttributes = [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextReplacementEnabled = false
        writingToolsBehavior = .none
    }

    func requestFocus() {
        if window?.firstResponder === self {
            centerLine()
            selectAll(nil)
            return
        }
        pendingFocus = true
        attemptFocus(retries: 8)
    }

    /// Keeps the line in the middle of the row. Called from layout so the first
    /// open uses the same inset as every later one.
    func centerLine() {
        guard !isCentering, let font, let layoutManager else { return }
        let visible = enclosingScrollView?.contentSize ?? bounds.size
        guard visible.height > 1 else { return }
        isCentering = true
        defer { isCentering = false }
        let line = layoutManager.defaultLineHeight(for: font)
        // Vertical only. Horizontal room is FindEditorView.caretLeadingInset
        // on both sides of the clip, which is not part of the scrolled document.
        let inset = NSSize(width: 0, height: max(0, (visible.height - line) / 2))
        if textContainerInset != inset { textContainerInset = inset }
        let textWidth = (string as NSString).size(withAttributes: typingAttributes).width
        // No extra document past the glyphs. A scroll to the end would otherwise
        // park that padding inside the field, past the trailing caret inset.
        let size = NSSize(width: max(visible.width, ceil(textWidth)), height: visible.height)
        if abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 {
            setFrameSize(size)
        }
    }

    override func layout() {
        super.layout()
        centerLine()
        if pendingFocus { attemptFocus(retries: 8) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        centerLine()
        if pendingFocus, window != nil { attemptFocus(retries: 8) }
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        pendingFocus = false
        centerLine()
        selectAll(nil)
        return true
    }

    override func didChangeText() {
        centerLine()
        scrollRangeToVisible(selectedRange())
        super.didChangeText()
        if !hasMarkedText() { onTextChange?(string) }
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.shift) { onPrevious?() } else { onNext?() }
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
        default:
            super.doCommand(by: selector)
        }
    }

    override func insertText(_ value: Any, replacementRange: NSRange) {
        let raw = (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
        let singleLine = raw.components(separatedBy: .newlines)
            .joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
        super.insertText(singleLine, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The caret is an insertion-indicator subview, composited above this draw.
        guard string.isEmpty, let font else { return }
        ("Find" as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: font, .foregroundColor: NSColor.placeholderTextColor
        ])
    }

    override func animation(forKey key: NSAnimatablePropertyKey) -> Any? { nil }

    private func attemptFocus(retries: Int) {
        guard pendingFocus else { return }
        centerLine()
        if let window, bounds.height > 1, window.makeFirstResponder(self) {
            pendingFocus = false
            return
        }
        guard retries > 0 else { pendingFocus = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.attemptFocus(retries: retries - 1)
        }
    }
}

private struct FindBarButton: View {
    let symbol: String
    let help: String
    var width: CGFloat = FindBarLayout.buttonWidth
    var isOn = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(isEnabled ? 0.72 : 0.22))
                .frame(width: width, height: 28)
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
