import AppKit
import SwiftUI

@MainActor
protocol ReviewDiffCoordinating: AnyObject {
    func reveal(fileID: String, hunkIndex: Int)
    func loadLarge(fileID: String, comparison: FileComparisonKind)
    var onEscape: () -> Void { get }
    var onFocusChange: (Bool) -> Void { get }
}

/// Sticky math for an expanded file header. Warp overlays a second header and
/// hides the original; we keep the original in layout and translate it so the
/// row is never duplicated. The header is translucent, so the diff is culled
/// by the same offset and never draws through it.
enum ReviewFileStickyMetrics {
    static let headerHeight: CGFloat = 40
    static let headerCornerRadius: CGFloat = 7
    /// Same fill as a selected sidebar tab.
    static let expandedHeaderFill = Color.primary.opacity(0.16)
    /// Same fill as a hovered sidebar tab.
    static let hoverHeaderFill = Color.primary.opacity(0.075)

    /// Offset applied to the original header so it stays `sidebarInset` below
    /// the list header while its file is on screen, then is pushed out by the
    /// file's bottom. `.scrollView` frames are already below the safe-area bar,
    /// so pin against `ShellMetrics.sidebarInset`, not `contentInsets.top`.
    static func headerOffset(
        sectionMinY: CGFloat,
        sectionMaxY: CGFloat,
        pinTop: CGFloat,
        headerHeight: CGFloat = headerHeight
    ) -> CGFloat {
        let distancePastPin = pinTop - sectionMinY
        let roomInsideSection = sectionMaxY - sectionMinY - headerHeight
        return min(max(distancePastPin, 0), max(roomInsideSection, 0))
    }

    /// Top of the diff to hide so it never intersects the translated header.
    static func contentCull(headerOffset: CGFloat) -> CGFloat {
        max(headerOffset, 0)
    }
}

/// File header row (40pt) for the SwiftUI review file list. Mirrors the old
/// AppKit header: disclosure chevron, basename + status subtitle, monospaced
/// +/− counts, and a file-actions menu. Tapping anywhere but the menu toggles.
struct ReviewFileHeaderRow: View {
    let file: ChangedFile
    let expanded: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopyRelative: () -> Void
    let onCopyAbsolute: () -> Void
    let onCopyPatch: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.identityPath.basename)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.metadataLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, 4)
            .help(pathHelp)

            Spacer(minLength: 8)

            if !file.hasBinaryComparison {
                Text("+\(file.additions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColors.reviewAddition)
                Text("−\(file.deletions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColors.reviewDeletion)
                    .padding(.leading, 6)
            }

            Menu {
                Button("Copy Relative Path", action: onCopyRelative)
                    .disabled(!file.identityPath.isLossless)
                Button("Copy Absolute Path", action: onCopyAbsolute)
                    .disabled(!file.identityPath.isLossless)
                Button("Open File", action: onOpen)
                    .disabled(file.kind == .deleted || !file.identityPath.isLossless)
                Button("Reveal in Finder", action: onReveal)
                    .disabled(!file.identityPath.isLossless)
                Button("Copy Patch", action: onCopyPatch)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .help("File actions")
            .padding(.trailing, 8)
        }
        .frame(height: ReviewFileStickyMetrics.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: ReviewFileStickyMetrics.headerCornerRadius, style: .continuous)
                .fill(backgroundColor)
        }
        .contentShape(
            .interaction,
            RoundedRectangle(cornerRadius: ReviewFileStickyMetrics.headerCornerRadius, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .animation(.easeInOut(duration: 0.16), value: expanded)
        .onTapGesture(perform: onToggle)
        .contextMenu {
            Button("Copy Relative Path", action: onCopyRelative)
                .disabled(!file.identityPath.isLossless)
            Button("Copy Absolute Path", action: onCopyAbsolute)
                .disabled(!file.identityPath.isLossless)
            Button("Open File", action: onOpen)
                .disabled(file.kind == .deleted || !file.identityPath.isLossless)
            Button("Reveal in Finder", action: onReveal)
                .disabled(!file.identityPath.isLossless)
            Button("Copy Patch", action: onCopyPatch)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(file.identityPath.basename), \(file.metadataLabel)")
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityAction(named: expanded ? "Collapse" : "Expand", onToggle)
    }

    private var backgroundColor: Color {
        if expanded {
            return ReviewFileStickyMetrics.expandedHeaderFill
        }
        if isHovered {
            return ReviewFileStickyMetrics.hoverHeaderFill
        }
        return .clear
    }

    private var pathHelp: String {
        file.oldPath.map { "\($0.display) → \(file.identityPath.display)" } ?? file.identityPath.display
    }
}

/// One file in the review list. Expanded files keep their original header in
/// layout and translate it to `pinTop` while the file is on screen.
struct ReviewFileCard: View {
    @ObservedObject var model: CodeReviewModel
    var file: ChangedFile
    var paneHeight: CGFloat
    var onEscape: () -> Void
    var onCollapseWhilePinned: () -> Void

    @State private var stickyOffset: CGFloat = 0

    private var expanded: Bool {
        model.presentation.expandedFileIDs.contains(file.id)
    }

    var body: some View {
        let offset = expanded ? stickyOffset : 0
        let cull = ReviewFileStickyMetrics.contentCull(headerOffset: offset)
        VStack(spacing: 0) {
            ReviewFileHeaderRow(
                file: file,
                expanded: expanded,
                onToggle: toggle,
                onOpen: { model.openFile(file) },
                onReveal: { model.reveal(file) },
                onCopyRelative: { model.copyPath(file, absolute: false) },
                onCopyAbsolute: { model.copyPath(file, absolute: true) },
                onCopyPatch: { model.copyPatch(for: file) }
            )
            .offset(y: offset)
            .zIndex(1)

            if expanded {
                ReviewDiffHost(
                    model: model,
                    file: file,
                    onEscape: onEscape,
                    onFocusChange: { _ in }
                )
                .frame(height: paneHeight, alignment: .top)
                // Flatten the AppKit pane first so the mask actually culls its
                // pixels. NSViewRepresentable otherwise paints through SwiftUI
                // clips, and the header fill is translucent.
                .compositingGroup()
                .mask(alignment: .top) {
                    Rectangle()
                        .padding(.top, cull)
                }
            }
        }
        .animation(nil, value: stickyOffset)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .scrollView(axis: .vertical))
        } action: { frame in
            let next: CGFloat
            if expanded {
                next = ReviewFileStickyMetrics.headerOffset(
                    sectionMinY: frame.minY,
                    sectionMaxY: frame.maxY,
                    pinTop: ShellMetrics.sidebarInset
                )
            } else {
                next = 0
            }
            if abs(next - stickyOffset) > 0.5 {
                stickyOffset = next
            }
        }
    }

    private func toggle() {
        let collapsingPinned = expanded && stickyOffset > 0.5
        model.toggleFile(file.id)
        if collapsingPinned {
            onCollapseWhilePinned()
        }
    }
}

struct ReviewDiffHost: NSViewRepresentable, Equatable {
    @ObservedObject var model: CodeReviewModel
    var file: ChangedFile
    var onEscape: () -> Void
    var onFocusChange: (Bool) -> Void

    /// Model-driven reloads flow through the observed object; identity alone
    /// decides view equality so unrelated parent refreshes (scroll tracking)
    /// never retrigger a pane reload mid-scroll.
    static nonisolated func == (lhs: ReviewDiffHost, rhs: ReviewDiffHost) -> Bool {
        lhs.file.id == rhs.file.id
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, onEscape: onEscape, onFocusChange: onFocusChange)
    }

    func makeNSView(context: Context) -> ReviewDiffPane {
        let view = ReviewDiffPane()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ReviewDiffPane, context: Context) {
        context.coordinator.model = model
        context.coordinator.onEscape = onEscape
        context.coordinator.onFocusChange = onFocusChange
        nsView.coordinator = context.coordinator
        nsView.reload(
            rows: ReviewDocumentBuilder.bodyRows(file: file, diffs: model.diffs, presentation: model.presentation),
            highlights: model.highlights,
            showWhitespace: model.showWhitespace,
            file: file
        )
    }

    static func dismantleNSView(_ nsView: ReviewDiffPane, coordinator: Coordinator) {
        nsView.shutdown()
    }

    @MainActor
    final class Coordinator: NSObject, ReviewDiffCoordinating {
        var model: CodeReviewModel
        var onEscape: () -> Void
        var onFocusChange: (Bool) -> Void

        init(model: CodeReviewModel, onEscape: @escaping () -> Void, onFocusChange: @escaping (Bool) -> Void) {
            self.model = model
            self.onEscape = onEscape
            self.onFocusChange = onFocusChange
        }

        func reveal(fileID: String, hunkIndex: Int) { model.revealContext(fileID: fileID, hunkIndex: hunkIndex) }
        func loadLarge(fileID: String, comparison: FileComparisonKind) { model.loadLargeDiff(fileID: fileID, comparison: comparison) }
    }
}

enum ReviewDiffMetrics {
    static let markerSlotWidth: CGFloat = 14
    static let changeBarWidth: CGFloat = 2
    static let numberLeadingInset: CGFloat = 8
    static let codeTextLeading: CGFloat = 4

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func lineNumberGutterWidth(for rows: [ReviewDocumentRow], font: NSFont) -> CGFloat {
        var maxNumber = 1
        for row in rows {
            if case .code(let line, _, _, _, _, _) = row {
                maxNumber = max(maxNumber, line.oldNumber ?? 1, line.newNumber ?? 1)
            }
        }
        let digits = max(3, String(maxNumber).count)
        return CGFloat(digits) * font.maximumAdvancement.width + 16
    }

    /// Single line-number column (GEN-51 follow-up): deletion shows the old
    /// number, everything else shows the new number with old as fallback.
    /// Context lines no longer render the same number twice.
    static func displayNumber(for line: DiffLine) -> String {
        switch line.kind {
        case .deletion:
            return line.oldNumber.map(String.init) ?? ""
        case .addition, .context:
            return line.newNumber.map(String.init) ?? line.oldNumber.map(String.init) ?? ""
        }
    }

    static func stickyWidth(gutterWidth: CGFloat) -> CGFloat {
        gutterWidth + markerSlotWidth
    }

    /// Opaque, mid-weight gray. `tertiaryLabelColor` is too faint on window glass
    /// and on the add/delete fills, in both appearances.
    /// Color lives in `Assets.xcassets/ReviewGutterNumber` (Any + Dark).
    static func gutterNumberColor(dark: Bool) -> NSColor {
        return AppColors.gutterNumber(dark: dark)
    }

    /// Row backgrounds. Colors live in `ReviewAdditionFill` / `ReviewDeletionFill`.
    static func changeFillColor(kind: DiffLineKind, dark: Bool) -> NSColor? {
        switch kind {
        case .addition:
            return AppColors.additionFill(dark: dark)
        case .deletion:
            return AppColors.deletionFill(dark: dark)
        case .context:
            return nil
        }
    }

    /// 2pt gutter edge. Colors live in `ReviewAdditionBar` / `ReviewDeletionBar`.
    static func changeBarColor(kind: DiffLineKind, dark: Bool) -> NSColor? {
        switch kind {
        case .addition:
            return AppColors.additionBar(dark: dark)
        case .deletion:
            return AppColors.deletionBar(dark: dark)
        case .context:
            return nil
        }
    }
}

/// Line-relative syntax color run. Coordinates are UTF-16 offsets into the
/// `DiffLine.text` (which matches the snapshot line, so 1:1 with the file).
struct ReviewHighlightRun: Hashable, Sendable {
    var location: Int
    var length: Int
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    var nsRange: NSRange { NSRange(location: location, length: length) }

    func makeColor() -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Maps file-absolute `SyntaxSpan`s (UTF-16 + sRGB, see `ReviewSyntaxHighlighter`)
/// onto a single `DiffLine` via its 1-based `oldNumber` / `newNumber`.
///
/// Rules (GEN-51):
/// - deletion → `old:` snapshot, addition → `new:` snapshot,
///   context → `new:` with `old:` fallback.
/// - Unknown language / over budget / binary → no entry in `highlights`,
///   so this returns nil and the caller keeps `NSColor.labelColor`.
/// - Foreground only. Row fills, gutter, selection, and whitespace dots are
///   owned by the caller.
enum ReviewHighlightMapper {
    static func runs(
        for line: DiffLine,
        fileID: String,
        comparison: FileComparisonKind,
        highlights: [String: HighlightedSource]
    ) -> [ReviewHighlightRun]? {
        let key = reviewDiffKey(fileID, comparison)
        switch line.kind {
        case .deletion:
            guard let number = line.oldNumber,
                  let source = highlights["old:\(key)"] else { return nil }
            return lineRuns(source: source, lineNumber: number, lineText: line.text)
        case .addition:
            guard let number = line.newNumber,
                  let source = highlights["new:\(key)"] else { return nil }
            return lineRuns(source: source, lineNumber: number, lineText: line.text)
        case .context:
            if let number = line.newNumber,
               let source = highlights["new:\(key)"],
               let runs = lineRuns(source: source, lineNumber: number, lineText: line.text) {
                return runs
            }
            if let number = line.oldNumber,
               let source = highlights["old:\(key)"],
               let runs = lineRuns(source: source, lineNumber: number, lineText: line.text) {
                return runs
            }
            return nil
        }
    }

    /// Converts file-absolute spans onto one line. Returns nil when nothing
    /// covers the line so the caller falls back to `labelColor`.
    static func lineRuns(
        source: HighlightedSource,
        lineNumber: Int,
        lineText: String
    ) -> [ReviewHighlightRun]? {
        guard lineNumber >= 1, lineNumber <= source.lineStarts.count else { return nil }
        let lineStart = source.lineStarts[lineNumber - 1]
        let lineLength = (lineText as NSString).length
        guard lineLength > 0, !source.spans.isEmpty else { return nil }
        let lineEnd = lineStart + lineLength
        var out: [ReviewHighlightRun] = []
        out.reserveCapacity(4)
        for span in source.spans {
            guard span.utf16Length > 0 else { continue }
            let spanStart = span.utf16Start
            let spanEnd = spanStart + span.utf16Length
            if spanEnd <= lineStart || spanStart >= lineEnd { continue }
            let clippedStart = max(spanStart, lineStart)
            let clippedEnd = min(spanEnd, lineEnd)
            guard clippedStart < clippedEnd else { continue }
            out.append(
                ReviewHighlightRun(
                    location: clippedStart - lineStart,
                    length: clippedEnd - clippedStart,
                    red: span.red,
                    green: span.green,
                    blue: span.blue,
                    alpha: span.alpha
                )
            )
        }
        return out.isEmpty ? nil : out
    }
}

private final class ReviewDiffScrollView: NSScrollView {
    var onDidScroll: (() -> Void)?
    private var isReflecting = false

    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        guard !isReflecting else { return }
        isReflecting = true
        onDidScroll?()
        isReflecting = false
    }

    /// Panes scroll horizontally only; the file list owns vertical scrolling.
    /// Horizontal gestures stay here, everything else travels up the responder
    /// chain to the outer list so wheeling over a file never dead-ends.
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if dx != 0 && abs(dx) >= abs(dy) {
            super.scrollWheel(with: event)
        } else if dy != 0 {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class ReviewDiffPane: NSView, ReviewFocusOwning {
    weak var coordinator: ReviewDiffCoordinating?
    private let scrollView = ReviewDiffScrollView()
    private let document = ReviewDiffDocumentView()
    private let gutter = ReviewDiffGutterView()
    private var isSyncingGutter = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        clipsToBounds = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.allowsMagnification = false
        scrollView.contentView.copiesOnScroll = false
        scrollView.documentView = document
        scrollView.onDidScroll = { [weak self] in
            self?.syncStickyGutter()
        }
        gutter.document = document
        gutter.clipsToBounds = true
        addSubview(scrollView)
        addSubview(gutter)
        document.pane = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func reload(
        rows: [ReviewDocumentRow],
        highlights: [String: HighlightedSource],
        showWhitespace: Bool,
        file: ChangedFile
    ) {
        document.reload(rows: rows, highlights: highlights, showWhitespace: showWhitespace, file: file)
        layoutDocument()
    }

    func shutdown() {
        coordinator = nil
        document.reload(rows: [], highlights: [:], showWhitespace: false, file: nil)
        document.setFrameSize(NSSize(width: 1, height: 1))
    }

    override func layout() {
        super.layout()
        layoutDocument()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutDocument()
    }

    private func layoutDocument() {
        let sticky = document.stickyWidth
        let height = max(bounds.height, 1)
        if sticky <= 0.5 {
            // Message-only panes (binary, mode-only, etc.) have no line numbers:
            // hide the gutter so the message centers to the full file width,
            // i.e. to the header, not to the code area beside an empty gutter.
            gutter.isHidden = true
            scrollView.frame = NSRect(x: 0, y: 0, width: max(bounds.width, 1), height: height)
            document.sizeToFit(clipWidth: max(bounds.width, 1))
        } else {
            gutter.isHidden = false
            let gutterWidth = max(sticky, 1)
            let codeWidth = max(bounds.width - gutterWidth, 1)
            gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: height)
            scrollView.frame = NSRect(x: gutterWidth, y: 0, width: codeWidth, height: height)
            document.sizeToFit(clipWidth: codeWidth)
        }
        syncStickyGutter()
    }

    func syncStickyGutter() {
        guard !isSyncingGutter else { return }
        isSyncingGutter = true
        defer { isSyncingGutter = false }
        let origin = NSPoint(x: 0, y: scrollView.documentVisibleRect.minY)
        if gutter.bounds.origin != origin {
            gutter.setBoundsOrigin(origin)
        }
        gutter.needsDisplay = true
    }

    func scrollDiffWheel(_ event: NSEvent) {
        scrollView.scrollWheel(with: event)
    }

    var stickyGutterFrame: NSRect { gutter.frame }
    var codeScrollFrame: NSRect { scrollView.frame }
    var diffVisibleOrigin: NSPoint { scrollView.documentVisibleRect.origin }
    var diffDocumentWidth: CGFloat { document.bounds.width }

    func scrollDiffDocument(to origin: NSPoint) {
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            coordinator?.onEscape()
            return
        }
        if event.charactersIgnoringModifiers == "c" && event.modifierFlags.contains(.command) {
            document.copySelection()
            return
        }
        if event.charactersIgnoringModifiers == "a" && event.modifierFlags.contains(.command) {
            document.selectAllInComparison()
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        coordinator?.onFocusChange(true)
        return super.becomeFirstResponder()
    }
}

private final class ReviewDiffGutterView: NSView {
    weak var document: ReviewDiffDocumentView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        document?.pane?.scrollDiffWheel(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        document?.drawGutter(in: dirtyRect, width: bounds.width)
    }
}

private final class ReviewDiffDocumentView: NSView {
    weak var pane: ReviewDiffPane?
    private var rows: [ReviewDocumentRow] = []
    private var highlights: [String: HighlightedSource] = [:]
    private var showWhitespace = false
    private var file: ChangedFile?
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var gutterWidth: CGFloat = 44
    private var maxCodeWidth: CGFloat = 0
    private var isMessageOnly = false
    private let selection = ReviewSelectionController()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    var stickyWidth: CGFloat {
        guard !isMessageOnly, gutterWidth > 0 else { return 0 }
        return ReviewDiffMetrics.stickyWidth(gutterWidth: gutterWidth)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        selection.onChange = { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload(
        rows: [ReviewDocumentRow],
        highlights: [String: HighlightedSource],
        showWhitespace: Bool,
        file: ChangedFile?
    ) {
        self.rows = rows
        self.highlights = highlights
        self.showWhitespace = showWhitespace
        self.file = file
        let hasCode = rows.contains(where: { if case .code = $0 { return true }; return false })
        isMessageOnly = !hasCode
        gutterWidth = hasCode ? ReviewDiffMetrics.lineNumberGutterWidth(for: rows, font: font) : 0
        maxCodeWidth = Self.maxCodeWidth(for: rows, font: font)
        needsDisplay = true
    }

    func sizeToFit(clipWidth: CGFloat) {
        let width = max(clipWidth, maxCodeWidth)
        let height = max(ReviewDocumentBuilder.contentHeight(of: rows), 1)
        let size = NSSize(width: width, height: height)
        if frame.size != size {
            setFrameSize(size)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        var y: CGFloat = 0
        for row in rows {
            let height = ReviewDocumentBuilder.height(of: row)
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: height)
            if rect.intersects(dirtyRect) {
                draw(row: row, in: rect)
            }
            y += height
        }
    }

    func drawGutter(in dirtyRect: NSRect, width: CGFloat) {
        let dark = ReviewDiffMetrics.isDark(effectiveAppearance)
        var y: CGFloat = 0
        for row in rows {
            let height = ReviewDocumentBuilder.height(of: row)
            let rect = NSRect(x: 0, y: y, width: width, height: height)
            if rect.intersects(dirtyRect), case .code(let line, _, _, _, _, _) = row {
                drawGutter(line: line, in: rect, dark: dark)
            }
            y += height
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(pane)
        let point = convert(event.locationInWindow, from: nil)
        guard let (item, rect) = row(at: point) else { return }
        switch item {
        case .folded(let fileID, _, let hunkIndex):
            pane?.coordinator?.reveal(fileID: fileID, hunkIndex: hunkIndex)
        case .code(let line, let fileID, let comparison, let revision, _, _):
            let extending = event.modifierFlags.contains(.shift)
            let rowIndex = codeIndex(fileID: fileID, comparison: comparison, line: line)
            let utf16 = utf16Index(at: point, in: rect, line: line)
            selection.select(fileID: fileID, comparison: comparison, revision: revision, row: rowIndex, utf16: utf16, extending: extending)
        case .message(_, let text):
            if text.contains("exceeds"), let file {
                pane?.coordinator?.loadLarge(fileID: file.id, comparison: file.comparisons.first?.kind ?? .unstaged)
            }
        default:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let target = codeTarget(at: point) else {
            needsDisplay = true
            return
        }
        selection.select(
            fileID: target.fileID,
            comparison: target.comparison,
            revision: target.revision,
            row: target.rowIndex,
            utf16: target.utf16,
            extending: true
        )
        needsDisplay = true
    }

    func copySelection() {
        let text = selection.copyText(from: rows)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func selectAllInComparison() {
        guard let selection = selection.selection else { return }
        var last = 0
        var lastUTF = 0
        var index = -1
        for row in rows {
            guard case .code(let line, let fileID, let comparison, _, _, _) = row else { continue }
            guard fileID == selection.fileID, comparison == selection.comparison else { continue }
            index += 1
            last = index
            lastUTF = (line.text as NSString).length
        }
        self.selection.selectAll(fileID: selection.fileID, comparison: selection.comparison, revision: selection.revision, lastRow: last, lastUTF16: lastUTF)
        needsDisplay = true
    }

    private func row(at point: NSPoint) -> (ReviewDocumentRow, NSRect)? {
        var y: CGFloat = 0
        for row in rows {
            let height = ReviewDocumentBuilder.height(of: row)
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: height)
            if point.y >= rect.minY && point.y < rect.maxY {
                return (row, rect)
            }
            y += height
        }
        return nil
    }

    private func draw(row: ReviewDocumentRow, in rect: NSRect) {
        switch row {
        case .code(let line, let fileID, let comparison, _, _, _):
            drawCode(line: line, fileID: fileID, comparison: comparison, in: rect)
        case .comparisonHeader(_, let comparison):
            drawLabel("\(comparison.kind.shortTitle)  \(comparison.kind.subtitle)", in: rect, font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
        case .message(_, let text):
            if isMessageOnly {
                drawCenteredLabel(text, in: rect, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            } else {
                drawLabel(text, in: rect, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            }
        case .folded(_, let text, _):
            drawLabel(text, in: rect, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        case .hunkHeader(let header):
            drawLabel(header, in: rect, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: .tertiaryLabelColor)
        default:
            break
        }
    }

    private func drawLabel(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let x = rect.minX + 8
        let drawRect = NSRect(x: x, y: rect.minY + 4, width: max(0, rect.maxX - x - 8), height: max(0, rect.height - 8))
        (text as NSString).draw(in: drawRect, withAttributes: [.font: font, .foregroundColor: color])
    }

    /// File-level placeholders (Binary file changed., mode-only, etc.) center
    /// horizontally to the file header. The pane hides the gutter for these,
    /// so `rect` already spans the full file width.
    private func drawCenteredLabel(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let drawRect = NSRect(x: rect.minX, y: rect.minY + 4, width: rect.width, height: max(0, rect.height - 8))
        (text as NSString).draw(in: drawRect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func drawCode(line: DiffLine, fileID: String, comparison: FileComparisonKind, in rect: NSRect) {
        let dark = ReviewDiffMetrics.isDark(effectiveAppearance)
        if let fill = ReviewDiffMetrics.changeFillColor(kind: line.kind, dark: dark) {
            fill.setFill()
            rect.fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        var display = line.text
        if showWhitespace {
            display = display.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\t", with: "→")
        }
        let ns = display as NSString
        let textY = rect.minY + max(0, (rect.height - 16) / 2)
        let textX = rect.minX + ReviewDiffMetrics.codeTextLeading
        if let range = selection.utf16Range(
            fileID: fileID,
            comparison: comparison,
            row: codeIndex(fileID: fileID, comparison: comparison, line: line),
            lineLength: ns.length
        ), range.length > 0 {
            let prefix = ns.substring(to: range.location)
            let selected = ns.substring(with: range)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let prefixWidth = (prefix as NSString).size(withAttributes: attributes).width
            let selectedWidth = (selected as NSString).size(withAttributes: attributes).width
            NSColor.selectedTextBackgroundColor.setFill()
            NSRect(x: textX + prefixWidth, y: rect.minY, width: max(selectedWidth, 2), height: rect.height).fill()
        }
        let textRect = NSRect(x: textX, y: textY, width: max(0, rect.width - textX), height: 16)
        if let runs = ReviewHighlightMapper.runs(for: line, fileID: fileID, comparison: comparison, highlights: highlights) {
            // Foreground-only highlighting. Row fills, selection background,
            // whitespace dots, and the sticky gutter are left untouched.
            // Gaps keep labelColor so unknown spans never break readability,
            // including on the translucent add/delete fills.
            let storable = NSMutableAttributedString(
                string: display,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            )
            for run in runs {
                guard run.length > 0, run.location >= 0, run.location < storable.length else { continue }
                let length = min(run.length, storable.length - run.location)
                storable.addAttribute(.foregroundColor, value: run.makeColor(), range: NSRange(location: run.location, length: length))
            }
            storable.draw(in: textRect)
        } else {
            ns.draw(
                in: textRect,
                withAttributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            )
        }
        if line.missingNewline {
            ("No newline at end of file" as NSString).draw(
                in: NSRect(x: textX, y: rect.maxY - 10, width: 240, height: 10),
                withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor]
            )
        }
    }

    private func drawGutter(line: DiffLine, in rect: NSRect, dark: Bool) {
        if let fill = ReviewDiffMetrics.changeFillColor(kind: line.kind, dark: dark) {
            fill.setFill()
            rect.fill()
        }
        if let bar = ReviewDiffMetrics.changeBarColor(kind: line.kind, dark: dark) {
            bar.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: ReviewDiffMetrics.changeBarWidth, height: rect.height).fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.alignment = .right
        let numberColor = ReviewDiffMetrics.gutterNumberColor(dark: dark)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: numberColor,
            .paragraphStyle: paragraph
        ]
        let textY = rect.minY + max(0, (rect.height - 16) / 2)
        let number = ReviewDiffMetrics.displayNumber(for: line)
        (number as NSString).draw(
            in: NSRect(x: rect.minX + ReviewDiffMetrics.numberLeadingInset, y: textY, width: max(0, gutterWidth - ReviewDiffMetrics.numberLeadingInset - 4), height: 16),
            withAttributes: attributes
        )
        let marker: String
        let markerColor: NSColor
        switch line.kind {
        case .addition:
            marker = "+"
            markerColor = AppColors.addition(dark: dark)
        case .deletion:
            marker = "−"
            markerColor = AppColors.deletion(dark: dark)
        case .context:
            marker = " "
            markerColor = numberColor
        }
        let markerStyle = NSMutableParagraphStyle()
        markerStyle.alignment = .center
        (marker as NSString).draw(
            in: NSRect(x: rect.minX + gutterWidth, y: textY, width: 12, height: 16),
            withAttributes: [.font: font, .foregroundColor: markerColor, .paragraphStyle: markerStyle]
        )
    }

    private func utf16Index(at point: NSPoint, in rect: NSRect, line: DiffLine) -> Int {
        var display = line.text
        if showWhitespace {
            display = display.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\t", with: "→")
        }
        let ns = display as NSString
        let textX = rect.minX + ReviewDiffMetrics.codeTextLeading
        let x = point.x - textX
        if x <= 0 { return 0 }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var width: CGFloat = 0
        for index in 0..<ns.length {
            let characterWidth = ns.substring(with: NSRange(location: index, length: 1)).size(withAttributes: attributes).width
            if width + characterWidth / 2 >= x { return index }
            width += characterWidth
        }
        return ns.length
    }

    private func codeTarget(at point: NSPoint) -> (fileID: String, comparison: FileComparisonKind, revision: String, rowIndex: Int, utf16: Int)? {
        if let (item, rect) = row(at: point), case .code(let line, let fileID, let comparison, let revision, _, _) = item {
            return (
                fileID,
                comparison,
                revision,
                codeIndex(fileID: fileID, comparison: comparison, line: line),
                utf16Index(at: point, in: rect, line: line)
            )
        }
        var nearest: (distance: CGFloat, item: ReviewDocumentRow, rect: NSRect)?
        var y: CGFloat = 0
        for row in rows {
            let height = ReviewDocumentBuilder.height(of: row)
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: height)
            if case .code = row {
                let distance = min(abs(point.y - rect.minY), abs(point.y - rect.maxY))
                if nearest == nil || distance < nearest!.distance {
                    nearest = (distance, row, rect)
                }
            }
            y += height
        }
        guard let nearest, case .code(let line, let fileID, let comparison, let revision, _, _) = nearest.item else { return nil }
        return (
            fileID,
            comparison,
            revision,
            codeIndex(fileID: fileID, comparison: comparison, line: line),
            utf16Index(at: point, in: nearest.rect, line: line)
        )
    }

    private func codeIndex(fileID: String, comparison: FileComparisonKind, line: DiffLine) -> Int {
        var index = -1
        for row in rows {
            guard case .code(let candidate, let rowFile, let rowComparison, _, _, _) = row else { continue }
            guard rowFile == fileID, rowComparison == comparison else { continue }
            index += 1
            if candidate == line { return index }
        }
        return max(0, index)
    }

    private static func maxCodeWidth(for rows: [ReviewDocumentRow], font: NSFont) -> CGFloat {
        var width: CGFloat = 0
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        for row in rows {
            if case .code(let line, _, _, _, _, _) = row {
                width = max(width, (line.text as NSString).size(withAttributes: attributes).width + 24)
            } else if case .hunkHeader(let header) = row {
                width = max(width, (header as NSString).size(withAttributes: attributes).width + 24)
            } else if case .message(_, let text) = row {
                width = max(width, (text as NSString).size(withAttributes: attributes).width + 24)
            }
        }
        return width
    }
}
