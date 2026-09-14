import AppKit
import SwiftUI

struct SidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)

            SearchTextBox(text: $text)
                .frame(height: 20)
        }
        .padding(.leading, 10)
        .padding(.trailing, 9)
        .frame(height: ShellMetrics.searchHeight)
        .background {
            Capsule()
                .fill(.quaternary)
        }
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
    }
}

/// A dedicated NSTextView avoids the shared field editor and focus behavior of NSTextField.
struct SearchTextBox: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> SearchTextBoxView {
        let box = SearchTextBoxView(frame: NSRect(x: 0, y: 0, width: 120, height: 20))
        box.textView.delegate = context.coordinator
        box.stringValue = text
        return box
    }

    func updateNSView(_ box: SearchTextBoxView, context: Context) {
        context.coordinator.text = $text
        if box.stringValue != text, !box.textView.hasMarkedText() {
            box.stringValue = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SearchTextBoxView,
                     context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: 20)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView,
                  !editor.hasMarkedText() else { return }
            text.wrappedValue = editor.string
        }
    }
}

/// Owns clipping and the entry click, so mouse tracking cannot undo select-all.
final class SearchTextBoxView: NSScrollView {
    let textView = SearchEditorTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 20))

    var stringValue: String {
        get { textView.string }
        set {
            textView.string = newValue
            textView.undoManager?.removeAllActions()
            textView.updateTextGeometry()
        }
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

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layout() {
        super.layout()
        textView.updateTextGeometry()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let descendant = super.hitTest(point) else { return nil }
        return textView.isEditingMode ? descendant : self
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }

    override func scrollWheel(with event: NSEvent) {
        if textView.isEditingMode, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    override func resetCursorRects() {}
}

final class SearchEditorTextView: NSTextView {
    private(set) var isEditingMode = false
    private let editingUndoManager = UndoManager()
    private var mouseDownMonitor: Any?
    private var isUpdatingGeometry = false
    private var focusGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureEditor()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureEditor()
    }

    private func configureEditor() {
        drawsBackground = false
        focusRingType = .none
        isRichText = false
        isFieldEditor = false
        allowsUndo = true
        isEditable = false
        isSelectable = false
        insertionPointColor = .controlAccentColor
        font = .systemFont(ofSize: 13)
        textColor = .labelColor
        writingToolsBehavior = .none
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isVerticallyResizable = false
        isHorizontallyResizable = true
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.lineFragmentPadding = 0
        textContainer?.maximumNumberOfLines = 1
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = maxSize
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        defaultParagraphStyle = paragraph
        typingAttributes = [.font: font!, .foregroundColor: NSColor.labelColor,
                            .paragraphStyle: paragraph]
        setAccessibilityLabel("Search terminal tabs")
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    isolated deinit { if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) } }

    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { editingUndoManager }
    override func resetCursorRects() {}

    /// One unwrapped line; only the document width grows, never the search capsule.
    func updateTextGeometry() {
        guard !isUpdatingGeometry, let container = textContainer,
              let layoutManager, let font else { return }
        isUpdatingGeometry = true
        defer { isUpdatingGeometry = false }
        let visible = enclosingScrollView?.contentSize ?? bounds.size
        layoutManager.ensureLayout(for: container)
        let width = max(visible.width, ceil(layoutManager.usedRect(for: container).width) + 6)
        let inset = NSSize(width: 2, height: max(0, (visible.height - layoutManager.defaultLineHeight(for: font)) / 2))
        if textContainerInset != inset { textContainerInset = inset }
        let size = NSSize(width: width, height: visible.height)
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    override func didChangeText() {
        updateTextGeometry()
        scrollRangeToVisible(selectedRange())
        super.didChangeText()
    }

    override func becomeFirstResponder() -> Bool {
        isEditable = true
        isSelectable = true
        guard super.becomeFirstResponder() else {
            isEditable = false
            isSelectable = false
            return false
        }
        isEditingMode = true
        focusGeneration += 1
        let generation = focusGeneration
        installMouseDownMonitor()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusGeneration == generation,
                  self.window?.firstResponder === self else { return }
            self.selectAll(nil)
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        endEditing()
        return true
    }

    private func endEditing() {
        focusGeneration += 1
        isEditingMode = false
        updateInsertionPointStateAndRestartTimer(false)
        setSelectedRange(NSRange(location: 0, length: 0))
        isEditable = false
        isSelectable = false
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
        enclosingScrollView?.contentView.scroll(to: .zero)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endEditing() }
    }

    private func installMouseDownMonitor() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  window.firstResponder === self else { return event }
            let boundary = self.enclosingScrollView ?? self
            guard !boundary.bounds.contains(boundary.convert(event.locationInWindow, from: nil)) else { return event }
            // Relinquish focus before dispatch; the clicked control then owns its new focus.
            window.makeFirstResponder(nil)
            return event
        }
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            break
        case #selector(NSResponder.insertTab(_:)):
            window?.selectNextKeyView(nil)
        case #selector(NSResponder.insertBacktab(_:)):
            window?.selectPreviousKeyView(nil)
        case #selector(NSResponder.cancelOperation(_:)),
             #selector(NSStandardKeyBindingResponding.complete(_:)):
            insertText("", replacementRange: NSRange(location: 0, length: (string as NSString).length))
            window?.makeFirstResponder(nil)
        default:
            super.doCommand(by: selector)
        }
    }

    override func insertText(_ value: Any, replacementRange: NSRange) {
        let text = (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
        let singleLine = text.components(separatedBy: .newlines)
            .joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
        super.insertText(singleLine, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        ("Search" as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor
        ])
    }
}
