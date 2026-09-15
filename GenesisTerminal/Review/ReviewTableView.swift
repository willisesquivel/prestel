import AppKit
import SwiftUI

struct ReviewFileListHost: NSViewRepresentable {
    @ObservedObject var model: CodeReviewModel
    var files: [ChangedFile]
    var onEscape: () -> Void
    var onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, onEscape: onEscape, onFocusChange: onFocusChange)
    }

    func makeNSView(context: Context) -> ReviewFileListView {
        let view = ReviewFileListView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ReviewFileListView, context: Context) {
        context.coordinator.model = model
        context.coordinator.onEscape = onEscape
        context.coordinator.onFocusChange = onFocusChange
        nsView.coordinator = context.coordinator
        nsView.reload(
            files: files,
            diffs: model.diffs,
            highlights: model.highlights,
            presentation: model.presentation,
            showWhitespace: model.showWhitespace
        )
    }

    static func dismantleNSView(_ nsView: ReviewFileListView, coordinator: Coordinator) {
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

        func toggle(_ fileID: String) { model.toggleFile(fileID) }
        func reveal(fileID: String, hunkIndex: Int) { model.revealContext(fileID: fileID, hunkIndex: hunkIndex) }
        func loadLarge(fileID: String, comparison: FileComparisonKind) { model.loadLargeDiff(fileID: fileID, comparison: comparison) }
        func open(_ file: ChangedFile) { model.openFile(file) }
        func revealInFinder(_ file: ChangedFile) { model.reveal(file) }
        func copyRelative(_ file: ChangedFile) { model.copyPath(file, absolute: false) }
        func copyAbsolute(_ file: ChangedFile) { model.copyPath(file, absolute: true) }
        func copyPatch(_ file: ChangedFile) { model.copyPatch(for: file) }
    }
}

@MainActor
protocol ReviewDiffCoordinating: AnyObject {
    func reveal(fileID: String, hunkIndex: Int)
    func loadLarge(fileID: String, comparison: FileComparisonKind)
    var onEscape: () -> Void { get }
    var onFocusChange: (Bool) -> Void { get }
}

final class ReviewFileListView: NSView {
    weak var coordinator: ReviewFileListHost.Coordinator?
    private let scrollView = NSScrollView()
    private let document = ReviewFileListDocument()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        clipsToBounds = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed
        scrollView.allowsMagnification = false
        scrollView.contentView.copiesOnScroll = true
        scrollView.documentView = document
        addSubview(scrollView)
        document.listView = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }

    func reload(
        files: [ChangedFile],
        diffs: [String: FileDiff],
        highlights: [String: HighlightedSource],
        presentation: ReviewPresentationState,
        showWhitespace: Bool
    ) {
        document.reload(
            files: files,
            diffs: diffs,
            highlights: highlights,
            presentation: presentation,
            showWhitespace: showWhitespace,
            coordinator: coordinator
        )
        layoutDocument()
    }

    func shutdown() {
        coordinator = nil
        document.reload(
            files: [],
            diffs: [:],
            highlights: [:],
            presentation: ReviewPresentationState(),
            showWhitespace: false,
            coordinator: nil
        )
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
        scrollView.frame = bounds
        document.layoutStack(clipWidth: max(bounds.width, 1))
    }
}

private final class ReviewFileListDocument: NSView {
    weak var listView: ReviewFileListView?
    private var files: [ChangedFile] = []
    private var diffs: [String: FileDiff] = [:]
    private var highlights: [String: HighlightedSource] = [:]
    private var presentation = ReviewPresentationState()
    private var showWhitespace = false
    private var headers: [String: ReviewFileHeaderView] = [:]
    private var panes: [String: ReviewDiffPane] = [:]

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func reload(
        files: [ChangedFile],
        diffs: [String: FileDiff],
        highlights: [String: HighlightedSource],
        presentation: ReviewPresentationState,
        showWhitespace: Bool,
        coordinator: ReviewFileListHost.Coordinator?
    ) {
        self.files = files
        self.diffs = diffs
        self.highlights = highlights
        self.presentation = presentation
        self.showWhitespace = showWhitespace
        let ids = Set(files.map(\.id))
        for (id, header) in headers where !ids.contains(id) {
            header.removeFromSuperview()
            headers.removeValue(forKey: id)
        }
        for (id, pane) in panes where !ids.contains(id) || !presentation.expandedFileIDs.contains(id) {
            pane.shutdown()
            pane.removeFromSuperview()
            panes.removeValue(forKey: id)
        }
        for file in files {
            let header = headers[file.id] ?? ReviewFileHeaderView()
            if header.superview == nil {
                addSubview(header)
                headers[file.id] = header
            }
            header.configure(file: file, expanded: presentation.expandedFileIDs.contains(file.id), coordinator: coordinator)
            if presentation.expandedFileIDs.contains(file.id) {
                let pane = panes[file.id] ?? ReviewDiffPane()
                if pane.superview == nil {
                    addSubview(pane)
                    panes[file.id] = pane
                }
                pane.coordinator = coordinator
                pane.reload(
                    rows: ReviewDocumentBuilder.bodyRows(file: file, diffs: diffs, presentation: presentation),
                    highlights: highlights,
                    showWhitespace: showWhitespace,
                    file: file
                )
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutStack(clipWidth: max(bounds.width, 1))
    }

    func layoutStack(clipWidth: CGFloat) {
        let inset = ShellMetrics.sidebarHorizontalInset
        let width = max(clipWidth - inset * 2, 1)
        var y: CGFloat = 0
        for file in files {
            if let header = headers[file.id] {
                header.frame = NSRect(x: inset, y: y, width: width, height: 40)
                y += 40 + ShellMetrics.sidebarRowSpacing
            }
            if presentation.expandedFileIDs.contains(file.id), let pane = panes[file.id] {
                let rows = ReviewDocumentBuilder.bodyRows(file: file, diffs: diffs, presentation: presentation)
                let height = min(max(ReviewDocumentBuilder.contentHeight(of: rows), 36), 420)
                pane.frame = NSRect(x: inset, y: y, width: width, height: height)
                y += height + ShellMetrics.sidebarRowSpacing
            }
        }
        y += 16
        let size = NSSize(width: clipWidth, height: max(y, 1))
        if frame.size != size {
            setFrameSize(size)
        }
    }
}

private final class ReviewFileHeaderView: NSView {
    private var file: ChangedFile?
    weak var coordinator: ReviewFileListHost.Coordinator?
    private let disclosure = NSButton()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let additions = NSTextField(labelWithString: "")
    private let deletions = NSTextField(labelWithString: "")
    private let menuButton = NSButton()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        [title, subtitle, additions, deletions].forEach {
            $0.isBordered = false
            $0.drawsBackground = false
            $0.lineBreakMode = .byTruncatingMiddle
            $0.cell?.truncatesLastVisibleLine = true
        }
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.lineBreakMode = .byTruncatingMiddle
        additions.lineBreakMode = .byClipping
        deletions.lineBreakMode = .byClipping
        additions.textColor = .systemGreen
        deletions.textColor = .systemRed
        additions.alignment = .right
        deletions.alignment = .right
        disclosure.bezelStyle = .regularSquare
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.target = self
        disclosure.action = #selector(toggle)
        menuButton.bezelStyle = .regularSquare
        menuButton.isBordered = false
        menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "File actions")
        menuButton.imagePosition = .imageOnly
        menuButton.target = self
        menuButton.action = #selector(showMenu)
        addSubview(disclosure)
        addSubview(title)
        addSubview(subtitle)
        addSubview(additions)
        addSubview(deletions)
        addSubview(menuButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(file: ChangedFile, expanded: Bool, coordinator: ReviewFileListHost.Coordinator?) {
        self.file = file
        self.coordinator = coordinator
        disclosure.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: "Disclosure"
        )
        title.stringValue = file.identityPath.basename
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.toolTip = file.oldPath.map { "\($0.display) → \(file.identityPath.display)" } ?? file.identityPath.display
        subtitle.stringValue = file.metadataLabel
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        if file.hasBinaryComparison {
            additions.stringValue = ""
            deletions.stringValue = ""
        } else {
            additions.stringValue = "+\(file.additions)"
            deletions.stringValue = "−\(file.deletions)"
        }
        additions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        deletions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        additions.sizeToFit()
        deletions.sizeToFit()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        disclosure.frame = NSRect(x: 4, y: 8, width: 24, height: 24)
        menuButton.frame = NSRect(x: max(8, bounds.width - 32), y: 8, width: 24, height: 24)
        let deletionsWidth = deletions.stringValue.isEmpty ? 0 : ceil(deletions.attributedStringValue.size().width) + 4
        let additionsWidth = additions.stringValue.isEmpty ? 0 : ceil(additions.attributedStringValue.size().width) + 4
        var cursor = menuButton.frame.minX - 8
        if deletionsWidth > 0 {
            cursor -= deletionsWidth
            deletions.frame = NSRect(x: cursor, y: 6, width: deletionsWidth, height: 16)
            cursor -= 6
        } else {
            deletions.frame = .zero
        }
        if additionsWidth > 0 {
            cursor -= additionsWidth
            additions.frame = NSRect(x: cursor, y: 6, width: additionsWidth, height: 16)
        } else {
            additions.frame = .zero
        }
        let textX: CGFloat = 32
        let textWidth = max(40, cursor - 8 - textX)
        title.frame = NSRect(x: textX, y: 4, width: textWidth, height: 16)
        subtitle.frame = NSRect(x: textX, y: 22, width: textWidth, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if let file {
            coordinator?.toggle(file.id)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let file {
            NSMenu.popUpContextMenu(handleMenu(file), with: event, for: self)
        }
    }

    @objc private func toggle() {
        if let file {
            coordinator?.toggle(file.id)
        }
    }

    @objc private func showMenu() {
        if let file {
            handleMenu(file).popUp(positioning: nil, at: NSPoint(x: menuButton.bounds.minX, y: menuButton.bounds.maxY), in: menuButton)
        }
    }

    private func handleMenu(_ file: ChangedFile) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, enabled: Bool = true, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = file
            item.isEnabled = enabled
            return item
        }
        menu.addItem(item("Copy Relative Path", enabled: file.identityPath.isLossless, action: #selector(copyRelative(_:))))
        menu.addItem(item("Copy Absolute Path", enabled: file.identityPath.isLossless, action: #selector(copyAbsolute(_:))))
        menu.addItem(item("Open File", enabled: file.kind != .deleted && file.identityPath.isLossless, action: #selector(openFile(_:))))
        menu.addItem(item("Reveal in Finder", enabled: file.identityPath.isLossless, action: #selector(revealFile(_:))))
        menu.addItem(item("Copy Patch", action: #selector(copyPatch(_:))))
        return menu
    }

    @objc private func copyRelative(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? ChangedFile else { return }
        coordinator?.copyRelative(file)
    }
    @objc private func copyAbsolute(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? ChangedFile else { return }
        coordinator?.copyAbsolute(file)
    }
    @objc private func openFile(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? ChangedFile else { return }
        coordinator?.open(file)
    }
    @objc private func revealFile(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? ChangedFile else { return }
        coordinator?.revealInFinder(file)
    }
    @objc private func copyPatch(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? ChangedFile else { return }
        coordinator?.copyPatch(file)
    }
}

struct ReviewDiffHost: NSViewRepresentable {
    @ObservedObject var model: CodeReviewModel
    var file: ChangedFile
    var onEscape: () -> Void
    var onFocusChange: (Bool) -> Void

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

final class ReviewDiffPane: NSView, ReviewFocusOwning {
    weak var coordinator: ReviewDiffCoordinating?
    private let scrollView = NSScrollView()
    private let document = ReviewDiffDocumentView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        clipsToBounds = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .allowed
        scrollView.allowsMagnification = false
        scrollView.documentView = document
        addSubview(scrollView)
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
        scrollView.frame = bounds
        document.sizeToFit(clipWidth: max(bounds.width, 1))
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

private final class ReviewDiffDocumentView: NSView {
    weak var pane: ReviewDiffPane?
    private var rows: [ReviewDocumentRow] = []
    private var highlights: [String: HighlightedSource] = [:]
    private var showWhitespace = false
    private var file: ChangedFile?
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var gutterWidth: CGFloat = 44
    private var maxCodeWidth: CGFloat = 0
    private let selection = ReviewSelectionController()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

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
        gutterWidth = Self.gutterWidth(for: rows, font: font)
        maxCodeWidth = Self.maxCodeWidth(for: rows, font: font)
        needsDisplay = true
    }

    func sizeToFit(clipWidth: CGFloat) {
        let width = max(clipWidth, gutterWidth + 16 + maxCodeWidth)
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
            drawLabel(text, in: rect, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        case .folded(_, let text, _):
            drawLabel(text, in: rect, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        case .hunkHeader(let header):
            drawLabel(header, in: rect, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: .tertiaryLabelColor)
        default:
            break
        }
    }

    private func drawLabel(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let drawRect = NSRect(x: rect.minX + 8, y: rect.minY + 4, width: max(0, rect.width - 16), height: max(0, rect.height - 8))
        (text as NSString).draw(in: drawRect, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawCode(line: DiffLine, fileID: String, comparison: FileComparisonKind, in rect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch line.kind {
        case .addition:
            NSColor.systemGreen.withAlphaComponent(dark ? 0.16 : 0.10).setFill()
            rect.fill()
            NSColor.systemGreen.withAlphaComponent(0.85).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height).fill()
        case .deletion:
            NSColor.systemRed.withAlphaComponent(dark ? 0.14 : 0.08).setFill()
            rect.fill()
            NSColor.systemRed.withAlphaComponent(0.85).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height).fill()
        case .context:
            break
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        var display = line.text
        if showWhitespace {
            display = display.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\t", with: "→")
        }
        let ns = display as NSString
        let textY = rect.minY + max(0, (rect.height - 16) / 2)
        let textX = rect.minX + gutterWidth + 14
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
        let gutterAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let half = gutterWidth / 2
        let old = line.oldNumber.map(String.init) ?? ""
        let new = line.newNumber.map(String.init) ?? ""
        (old as NSString).draw(in: NSRect(x: rect.minX + 8, y: textY, width: half - 10, height: 16), withAttributes: gutterAttributes)
        (new as NSString).draw(in: NSRect(x: rect.minX + half, y: textY, width: half - 8, height: 16), withAttributes: gutterAttributes)
        let marker: String
        let markerColor: NSColor
        switch line.kind {
        case .addition:
            marker = "+"
            markerColor = .systemGreen
        case .deletion:
            marker = "−"
            markerColor = .systemRed
        case .context:
            marker = " "
            markerColor = .tertiaryLabelColor
        }
        (marker as NSString).draw(
            in: NSRect(x: rect.minX + gutterWidth, y: textY, width: 12, height: 16),
            withAttributes: [.font: font, .foregroundColor: markerColor]
        )
        let textRect = NSRect(x: textX, y: textY, width: max(0, rect.width - textX), height: 16)
        ns.draw(
            in: textRect,
            withAttributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        )
        if line.missingNewline {
            ("No newline at end of file" as NSString).draw(
                in: NSRect(x: textX, y: rect.maxY - 10, width: 240, height: 10),
                withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor]
            )
        }
    }

    private func utf16Index(at point: NSPoint, in rect: NSRect, line: DiffLine) -> Int {
        var display = line.text
        if showWhitespace {
            display = display.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\t", with: "→")
        }
        let ns = display as NSString
        let textX = rect.minX + gutterWidth + 14
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

    private static func gutterWidth(for rows: [ReviewDocumentRow], font: NSFont) -> CGFloat {
        var maxNumber = 1
        for row in rows {
            if case .code(let line, _, _, _, _, _) = row {
                maxNumber = max(maxNumber, line.oldNumber ?? 1, line.newNumber ?? 1)
            }
        }
        let digits = max(3, String(maxNumber).count)
        return CGFloat(digits) * font.maximumAdvancement.width * 2 + 16
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
