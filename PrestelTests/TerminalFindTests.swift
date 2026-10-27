import AppKit
import SwiftUI
import Testing
@testable import Prestel

struct TerminalFindTests {
    private func hits(_ text: String, _ query: String, caseSensitive: Bool = false,
                      widths: [Int]? = nil) -> [TerminalFindHighlight] {
        TerminalFindMatcher.highlights(
            row: 3, text: text, cellWidths: widths ?? Array(repeating: 1, count: text.count),
            query: query, caseSensitive: caseSensitive)
    }

    @Test func findsEveryNonOverlappingMatch() {
        #expect(hits("abcabcab", "abc") == [
            TerminalFindHighlight(row: 3, column: 0, width: 3),
            TerminalFindHighlight(row: 3, column: 3, width: 3)
        ])
        #expect(hits("aaaa", "aa").count == 2)
    }

    @Test func caseSensitivityIsHonored() {
        #expect(hits("Error error ERROR", "error").count == 3)
        #expect(hits("Error error ERROR", "error", caseSensitive: true).count == 1)
    }

    @Test func emptyQueryAndTextMatchNothing() {
        #expect(hits("hello", "").isEmpty)
        #expect(hits("", "a", widths: []).isEmpty)
        #expect(hits("ab", "abc").isEmpty)
    }

    @Test func wideCellsShiftColumns() {
        // The wide character takes cells 0-1, so "x" sits at column 2.
        #expect(hits("日x", "x", widths: [2, 0, 1]) == [TerminalFindHighlight(row: 3, column: 2, width: 1)])
        #expect(hits("日x", "日", widths: [2, 0, 1]) == [TerminalFindHighlight(row: 3, column: 0, width: 2)])
    }

    @Test func wideSurfaceKeepsTheShorterField() {
        let metrics = FindBarLayout.metrics(forSurfaceWidth: 2000)
        #expect(metrics.fieldWidth == FindBarLayout.preferredFieldWidth)
        #expect(metrics.fieldWidth < 130)
        #expect(metrics.buttonWidth == FindBarLayout.buttonWidth)
        #expect(metrics.occupiedWidth < 2000)
    }

    @Test func minimumTerminalShrinksTheFieldToFit() {
        let wide = FindBarLayout.metrics(forSurfaceWidth: 2000)
        let narrow = FindBarLayout.metrics(forSurfaceWidth: ShellMetrics.minimumDetailWidth)
        #expect(narrow.occupiedWidth <= ShellMetrics.minimumDetailWidth)
        #expect(narrow.fieldWidth < wide.fieldWidth)
        #expect(narrow.fieldWidth > 0)
        #expect(narrow.buttonWidth == wide.buttonWidth)
    }

    @Test func barStaysInsideEveryTerminalWidth() {
        for width in stride(from: 160.0, through: 900.0, by: 23) {
            let metrics = FindBarLayout.metrics(forSurfaceWidth: width)
            #expect(metrics.occupiedWidth <= width + 0.01)
        }
    }

    @Test func counterText() {
        #expect(TerminalFindMatcher.counter(index: 3, total: 12) == "3 of 12")
        #expect(TerminalFindMatcher.counter(index: 0, total: 4) == "4")
        #expect(TerminalFindMatcher.counter(index: 0, total: 0) == "No results")
        #expect(TerminalFindMatcher.counter(index: 5, total: 1000) == "5 of 1000+")
    }
}

@MainActor
struct TerminalFindStateTests {
    @Test func repeatedShowRequestsFocusEachTime() {
        let find = TerminalFind()
        find.show(on: nil)
        let first = find.focusRequest
        find.show(on: nil)
        #expect(find.isVisible)
        #expect(find.focusRequest == first &+ 1)
    }

    @Test func reopeningDuringFadeOutKeepsBarVisible() async throws {
        let find = TerminalFind()
        find.show(on: nil)
        find.hide(returningFocusTo: nil)
        #expect(!find.isVisible)
        find.show(on: nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(find.isVisible)
    }
}

@MainActor
struct TerminalFindCaretTests {
    @Test func leadingCaretInsetStaysOutsideTheScrolledLine() throws {
        let field = FindEditorView(frame: NSRect(x: 0, y: 0, width: 96, height: FindBarLayout.barHeight))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 40, y: 40, width: 96, height: FindBarLayout.barHeight)
        field.layoutSubtreeIfNeeded()

        #expect(field.bounds.width == 96)
        #expect(abs(field.contentView.bounds.width - 96) < 0.5)
        #expect(field.contentView.contentInsets.left == FindEditorView.caretLeadingInset)
        #expect(field.contentView.contentInsets.right == FindEditorView.caretLeadingInset)
        #expect(field.textView.textContainerInset.width == 0)
        let font = try #require(field.textView.font)
        let layout = try #require(field.textView.layoutManager)
        let line = layout.defaultLineHeight(for: font)
        let expectedY = max(0, (field.contentSize.height - line) / 2)
        #expect(field.contentSize.height > 30)
        #expect(abs(field.textView.textContainerInset.height - expectedY) < 0.6)

        field.stringValue = "ok"
        field.layoutSubtreeIfNeeded()
        #expect(field.bounds.width == 96)
        #expect(field.contentView.contentInsets.right == FindEditorView.caretLeadingInset)
        #expect(field.contentView.bounds.origin.x <= -FindEditorView.caretLeadingInset + 0.5)
        #expect(field.textView.textContainerInset.width == 0)
        let shortContainer = try #require(field.textView.textContainer)
        field.textView.layoutManager?.ensureLayout(for: shortContainer)
        let shortUsed = field.textView.layoutManager?.usedRect(for: shortContainer) ?? .zero
        #expect(shortUsed.minX < 2)
        #expect(shortUsed.maxX > 0)
        #expect(shortUsed.maxX < field.bounds.width * 0.5)

        field.stringValue = String(repeating: "m", count: 40)
        field.layoutSubtreeIfNeeded()
        #expect(field.bounds.width == 96)
        #expect(field.textView.frame.width > field.contentSize.width)
        let length = (field.stringValue as NSString).length
        field.textView.setSelectedRange(NSRange(location: length, length: 0))
        field.textView.scrollRangeToVisible(NSRange(location: length, length: 0))
        field.layoutSubtreeIfNeeded()
        let atEnd = field.contentView.bounds.origin.x
        #expect(atEnd > 20)
        #expect(field.contentView.contentInsets.right == FindEditorView.caretLeadingInset)
        let caret = insertionPointInClip(field)
        let trailingRoom = field.contentView.bounds.maxX - caret.x
        #expect(trailingRoom >= FindEditorView.caretLeadingInset - 0.5,
                "trailing room \(trailingRoom) origin \(atEnd) caret \(caret)")
        #expect(trailingRoom <= FindEditorView.caretLeadingInset + 3,
                "trailing room \(trailingRoom) origin \(atEnd) caret \(caret)")

        field.textView.setSelectedRange(NSRange(location: 0, length: 0))
        field.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        #expect(field.contentView.bounds.origin.x <= -FindEditorView.caretLeadingInset + 0.5)
        #expect(field.contentView.contentInsets.right == FindEditorView.caretLeadingInset)
        #expect(field.bounds.width == 96)
        #expect(abs(field.textView.textContainerInset.height - expectedY) < 0.6)
    }

    @Test func glassHostKeepsLeadingCaretInset() throws {
        let hosting = NSHostingView(rootView: FindCaretGlassProbe())
        hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 80)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let field = try #require(findEditor(in: hosting))
        field.layoutSubtreeIfNeeded()
        #expect(field.contentView.contentInsets.left == FindEditorView.caretLeadingInset)
        #expect(field.contentView.contentInsets.right == FindEditorView.caretLeadingInset)
        #expect(field.textView.textContainerInset.width == 0)
        #expect(field.bounds.width == 96)
    }

    @Test func indexZeroCaretStrokeIsFullyInsideTheClip() throws {
        let field = FindEditorView(frame: NSRect(x: 20, y: 20, width: 96, height: FindBarLayout.barHeight))
        let window = CaretKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.close() }
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        field.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(field.textView))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        field.textView.updateInsertionPointStateAndRestartTimer(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let empty = try caretStroke(in: field)
        #expect(empty.columns.count >= 4, "empty caret columns \(empty.columns)")
        #expect((empty.columns.first ?? 0) > 0, "empty caret columns \(empty.columns)")
        #expect(empty.grayToTheRight, "placeholder Find should be visible beside the caret")

        field.stringValue = "ok"
        field.layoutSubtreeIfNeeded()
        field.textView.setSelectedRange(NSRange(location: 2, length: 0))
        field.textView.scrollRangeToVisible(NSRange(location: 2, length: 0))
        field.textView.updateInsertionPointStateAndRestartTimer(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let short = try caretStroke(in: field)
        #expect(field.bounds.width == 96)
        #expect(short.columns.count >= 4, "short caret columns \(short.columns) width \(short.pixelWidth)")
        #expect((short.columns.first ?? 0) > 0, "short caret columns \(short.columns)")
        #expect((short.columns.max() ?? 0) < short.pixelWidth / 2,
                "short caret columns \(short.columns) width \(short.pixelWidth)")

        field.stringValue = String(repeating: "m", count: 40)
        field.layoutSubtreeIfNeeded()
        let length = (field.stringValue as NSString).length
        field.textView.setSelectedRange(NSRange(location: length, length: 0))
        field.textView.scrollRangeToVisible(NSRange(location: length, length: 0))
        field.layoutSubtreeIfNeeded()
        field.textView.updateInsertionPointStateAndRestartTimer(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let end = try caretStroke(in: field)
        let endRight = end.columns.max() ?? -1
        let endCaret = insertionPointInClip(field)
        let endRoom = field.contentView.bounds.maxX - endCaret.x
        #expect(end.columns.count >= 4, "end caret columns \(end.columns) width \(end.pixelWidth)")
        #expect(endRight >= 0 && endRight < end.pixelWidth - 1,
                "end caret columns \(end.columns) width \(end.pixelWidth)")
        #expect(endRoom >= FindEditorView.caretLeadingInset - 0.5, "end room \(endRoom) columns \(end.columns)")
        #expect(endRoom <= FindEditorView.caretLeadingInset + 3, "end room \(endRoom) columns \(end.columns)")

        field.textView.setSelectedRange(NSRange(location: 0, length: 0))
        field.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        field.layoutSubtreeIfNeeded()
        field.textView.updateInsertionPointStateAndRestartTimer(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let home = try caretStroke(in: field)
        #expect(home.columns.count >= 4, "home caret columns \(home.columns) origin \(field.contentView.bounds.origin.x)")
        #expect((home.columns.first ?? 0) > 0, "home caret columns \(home.columns)")
        let indicator = try #require(field.textView.subviews.first {
            String(describing: type(of: $0)).contains("Insertion") && $0.frame.minY > 1
        })
        let inClip = field.contentView.convert(indicator.frame, from: indicator.superview)
        #expect(inClip.minX - 1 >= field.contentView.bounds.minX)
    }
}

private final class CaretKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

private struct CaretStroke {
    var columns: [Int]
    var pixelWidth: Int
    var grayToTheRight: Bool
}

private func insertionPointInClip(_ field: FindEditorView) -> NSPoint {
    let textView = field.textView
    guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
        return .zero
    }
    layoutManager.ensureLayout(for: container)
    let origin = textView.textContainerOrigin
    let chars = (textView.string as NSString).length
    let index = textView.selectedRange().location
    let x: CGFloat
    if chars == 0 || layoutManager.numberOfGlyphs == 0 {
        x = origin.x
    } else if index >= chars {
        let glyph = layoutManager.numberOfGlyphs - 1
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        x = origin.x + rect.maxX
    } else {
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        x = origin.x + layoutManager.location(forGlyphAt: glyph).x
    }
    return textView.convert(NSPoint(x: x, y: origin.y), to: field.contentView)
}

private func caretStroke(in field: FindEditorView) throws -> CaretStroke {
    let clip = field.contentView
    field.window?.displayIfNeeded()
    // The stroke layer is created at opacity 0 and blinks on. Sample it while it is on.
    for subview in field.textView.subviews where String(describing: type(of: subview)).contains("Insertion") {
        for layer in subview.layer?.sublayers ?? [] where layer.frame.width <= 3 && layer.frame.height > 8 {
            layer.isHidden = false
            layer.opacity = 1
        }
    }
    let scale = clip.window?.backingScaleFactor ?? 2
    let bounds = clip.bounds
    let width = max(1, Int((bounds.width * scale).rounded(.up)))
    let height = max(1, Int((bounds.height * scale).rounded(.up)))
    let rep = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
    let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
    context.cgContext.translateBy(x: 0, y: CGFloat(height))
    context.cgContext.scaleBy(x: scale, y: -scale)
    context.cgContext.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
    clip.layer?.render(in: context.cgContext)
    for subview in field.textView.subviews where String(describing: type(of: subview)).contains("Insertion") {
        let frame = clip.convert(subview.frame, from: subview.superview)
        context.cgContext.saveGState()
        context.cgContext.translateBy(x: frame.minX, y: frame.minY)
        subview.layer?.render(in: context.cgContext)
        context.cgContext.restoreGState()
    }
    guard let data = rep.bitmapData else {
        return CaretStroke(columns: [], pixelWidth: width, grayToTheRight: false)
    }
    var columns = Set<Int>()
    var bestY = 0
    var best = -1
    for y in 0..<height {
        var count = 0
        for x in 0..<width {
            let o = (y * width + x) * 4
            let r = Int(data[o]), b = Int(data[o + 2]), a = Int(data[o + 3])
            if b > 120, b > r + 30, a > 60 { count += 1 }
        }
        if count > best { best = count; bestY = y }
    }
    for x in 0..<width {
        let o = (bestY * width + x) * 4
        let r = Int(data[o]), b = Int(data[o + 2]), a = Int(data[o + 3])
        if b > 120, b > r + 30, a > 60 { columns.insert(x) }
    }
    // The placeholder is the label color at partial alpha on a clear backdrop, so it
    // can read as black or white rather than mid-gray. Any neutral ink counts.
    var gray = false
    let start = (columns.max() ?? 0) + 1
    if start < width {
        for y in 0..<height {
            for x in start..<min(width, start + 80) {
                let o = (y * width + x) * 4
                let r = Int(data[o]), g = Int(data[o + 1]), b = Int(data[o + 2]), a = Int(data[o + 3])
                if a > 40, abs(r - g) < 24, abs(g - b) < 24 { gray = true }
            }
        }
    }
    return CaretStroke(columns: columns.sorted(), pixelWidth: width, grayToTheRight: gray)
}

private struct FindCaretGlassProbe: View {
    var body: some View {
        FindTextField(
            text: .constant(""),
            focusRequest: 0,
            onNext: {},
            onPrevious: {},
            onEscape: {}
        )
        .frame(width: 96, height: FindBarLayout.barHeight)
        .padding(.horizontal, 12)
        .chromeGlass()
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private func findEditor(in view: NSView) -> FindEditorView? {
    if let field = view as? FindEditorView { return field }
    for subview in view.subviews {
        if let found = findEditor(in: subview) { return found }
    }
    return nil
}
