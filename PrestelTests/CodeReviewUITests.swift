import AppKit
import Testing
@testable import Prestel

@Suite
@MainActor
struct CodeReviewUITests {
    @Test func layoutMatchesFourPanelCombinationsAtBaseline() {
        let closed = ShellLayout.resolve(.init(windowWidth: 960, sidebarVisible: false, reviewVisible: false, preferredSidebarWidth: 172, preferredReviewWidth: 420))
        #expect(closed.terminalWidth == 940)
        #expect(closed.detailOriginX == 10)

        let left = ShellLayout.resolve(.init(windowWidth: 960, sidebarVisible: true, reviewVisible: false, preferredSidebarWidth: 172, preferredReviewWidth: 420))
        #expect(left.terminalWidth == 778)

        let review = ShellLayout.resolve(.init(windowWidth: 960, sidebarVisible: false, reviewVisible: true, preferredSidebarWidth: 172, preferredReviewWidth: 420))
        #expect(review.terminalWidth == 530)
        #expect(review.effectiveReviewWidth == 420)
        #expect(review.reviewOriginX == 540)

        let both = ShellLayout.resolve(.init(windowWidth: 960, sidebarVisible: true, reviewVisible: true, preferredSidebarWidth: 172, preferredReviewWidth: 420))
        #expect(both.effectiveSidebarWidth == 172)
        #expect(both.effectiveReviewWidth == 420)
        #expect(both.terminalWidth == 368)
        #expect(both.reviewOriginX == 540)
    }

    @Test func minimumWindowPreservesTerminalAndCompressesReview() {
        let both = ShellLayout.resolve(.init(windowWidth: 760, sidebarVisible: true, reviewVisible: true, preferredSidebarWidth: 172, preferredReviewWidth: 420))
        #expect(both.effectiveSidebarWidth == 172)
        #expect(both.terminalWidth >= 320)
        #expect(both.effectiveReviewWidth >= 256)

        let wideSidebar = ShellLayout.resolve(.init(windowWidth: 760, sidebarVisible: true, reviewVisible: true, preferredSidebarWidth: 300, preferredReviewWidth: 420))
        #expect(wideSidebar.effectiveSidebarWidth == 184)
        #expect(wideSidebar.effectiveReviewWidth == 256)
        #expect(wideSidebar.terminalWidth == 320)
    }

    @Test func growingWindowRestoresPreferredWidths() {
        let compressed = ShellLayout.resolve(.init(windowWidth: 760, sidebarVisible: true, reviewVisible: true, preferredSidebarWidth: 300, preferredReviewWidth: 420))
        #expect(compressed.effectiveSidebarWidth == 184)
        let restored = ShellLayout.resolve(.init(windowWidth: 1100, sidebarVisible: true, reviewVisible: true, preferredSidebarWidth: 300, preferredReviewWidth: 420))
        #expect(restored.effectiveSidebarWidth == 300)
        #expect(restored.effectiveReviewWidth == 420)
    }

    @Test func headerClearanceDependsOnSidebarVisibility() {
        let open = ShellLayout.resolve(.init(windowWidth: 960, sidebarVisible: true, reviewVisible: false, preferredSidebarWidth: 172, preferredReviewWidth: 420))
        let closed = ShellLayout.resolve(.init(windowWidth: 960, sidebarVisible: false, reviewVisible: false, preferredSidebarWidth: 172, preferredReviewWidth: 420))
        #expect(open.headerLeadingPadding == 12)
        #expect(closed.headerLeadingPadding == 80)
    }

    @Test func closedPanelsKeepRestingWidthSoShowHideCanSlide() {
        let closed = ShellLayout.resolve(.init(windowWidth: 960, sidebarVisible: false, reviewVisible: false, preferredSidebarWidth: 172, preferredReviewWidth: 420))
        #expect(closed.effectiveSidebarWidth == 0)
        #expect(closed.effectiveReviewWidth == 0)
        #expect(closed.restingSidebarWidth == 172)
        #expect(closed.restingReviewWidth == 420)
        #expect(closed.restingReviewOriginX == 540)
        #expect(closed.reviewOriginX == 960)

        let left = ShellLayout.resolve(.init(windowWidth: 960, sidebarVisible: true, reviewVisible: false, preferredSidebarWidth: 172, preferredReviewWidth: 420))
        #expect(left.restingSidebarWidth == left.effectiveSidebarWidth)
        #expect(left.restingReviewWidth == 420)
        #expect(left.restingReviewOriginX == 540)

        let review = ShellLayout.resolve(.init(windowWidth: 960, sidebarVisible: false, reviewVisible: true, preferredSidebarWidth: 172, preferredReviewWidth: 420))
        #expect(review.restingReviewWidth == review.effectiveReviewWidth)
        #expect(review.restingReviewOriginX == review.reviewOriginX)
        #expect(review.restingSidebarWidth == 172)

        let both = ShellLayout.resolve(.init(windowWidth: 960, sidebarVisible: true, reviewVisible: true, preferredSidebarWidth: 172, preferredReviewWidth: 420))
        #expect(both.restingSidebarWidth == both.effectiveSidebarWidth)
        #expect(both.restingReviewWidth == both.effectiveReviewWidth)
        #expect(both.restingReviewOriginX == both.reviewOriginX)
    }

    @Test func hostedReviewToggleDoesNotRecreateSelectedSurface() async throws {
        let model = TerminalModel()
        let controller = TerminalWindowController(model: model)
        let window = try #require(controller.window)
        defer { controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window)) }
        window.setFrame(NSRect(x: 0, y: 0, width: 960, height: 650), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let surface = try #require(model.selectedTab?.surface)
        let pid = model.selectedTab?.process?.shellPid
        model.reviewVisible = true
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        model.reviewVisible = false
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.selectedTab?.surface === surface)
        #expect(model.selectedTab?.process?.shellPid == pid)
        #expect(surface.window === window)
    }

    @Test func diffGutterStaysPinnedDuringHorizontalPan() {
        let pane = ReviewDiffPane(frame: NSRect(x: 0, y: 0, width: 220, height: 140))
        let file = ChangedFile(
            identityPath: .from("Wide.swift"),
            kind: .modified,
            comparisons: [
                ComparisonSummary(
                    kind: .unstaged,
                    additions: 1,
                    deletions: 1,
                    isBinary: false,
                    oldPath: nil,
                    newPath: .from("Wide.swift"),
                    oldMode: nil,
                    newMode: nil,
                    oldOID: nil,
                    newOID: nil
                )
            ],
            oldPath: nil
        )
        let long = String(repeating: "let value = 1234567890; ", count: 12)
        let rows: [ReviewDocumentRow] = [
            .code(DiffLine(kind: .deletion, oldNumber: 40, newNumber: nil, text: long, missingNewline: false), fileID: file.id, comparison: .unstaged, revision: "rev", hunkIndex: 0, lineIndex: 0),
            .code(DiffLine(kind: .addition, oldNumber: nil, newNumber: 41, text: long, missingNewline: false), fileID: file.id, comparison: .unstaged, revision: "rev", hunkIndex: 0, lineIndex: 1),
            .code(DiffLine(kind: .context, oldNumber: 41, newNumber: 42, text: long, missingNewline: false), fileID: file.id, comparison: .unstaged, revision: "rev", hunkIndex: 0, lineIndex: 2)
        ]
        pane.reload(rows: rows, highlights: [:], showWhitespace: false, file: file)
        pane.layoutSubtreeIfNeeded()

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let expectedWidth = ReviewDiffMetrics.stickyWidth(
            gutterWidth: ReviewDiffMetrics.lineNumberGutterWidth(for: rows, font: font)
        )
        #expect(pane.stickyGutterFrame.minX == 0)
        #expect(pane.stickyGutterFrame.width == expectedWidth)
        #expect(pane.codeScrollFrame.minX == pane.stickyGutterFrame.maxX)
        #expect(pane.codeScrollFrame.maxX == pane.bounds.maxX)
        let documentWidthAtRest = pane.diffDocumentWidth
        #expect(documentWidthAtRest > pane.codeScrollFrame.width)

        pane.scrollDiffDocument(to: NSPoint(x: 90, y: 0))
        pane.layoutSubtreeIfNeeded()
        #expect(pane.stickyGutterFrame.minX == 0)
        #expect(pane.stickyGutterFrame.width == expectedWidth)
        #expect(pane.codeScrollFrame.minX == pane.stickyGutterFrame.maxX)
        #expect(abs(pane.diffVisibleOrigin.x - 90) < 0.5)
        #expect(pane.diffDocumentWidth == documentWidthAtRest)
    }

    @Test func gutterNumberColorIsOpaqueAndHigherContrastThanTertiary() {
        let light = ReviewDiffMetrics.gutterNumberColor(dark: false).usingColorSpace(.sRGB)!
        let dark = ReviewDiffMetrics.gutterNumberColor(dark: true).usingColorSpace(.sRGB)!
        #expect(light.alphaComponent == 1)
        #expect(dark.alphaComponent == 1)
        #expect(light.redComponent < 0.45)
        #expect(dark.redComponent > 0.65)
    }

    @Test func gutterShowsASingleLineNumber() {
        let deletion = DiffLine(kind: .deletion, oldNumber: 678, newNumber: nil, text: "", missingNewline: false)
        let addition = DiffLine(kind: .addition, oldNumber: nil, newNumber: 678, text: "", missingNewline: false)
        let contextSame = DiffLine(kind: .context, oldNumber: 675, newNumber: 675, text: "", missingNewline: false)
        let contextShifted = DiffLine(kind: .context, oldNumber: 679, newNumber: 681, text: "", missingNewline: false)
        #expect(ReviewDiffMetrics.displayNumber(for: deletion) == "678")
        #expect(ReviewDiffMetrics.displayNumber(for: addition) == "678")
        #expect(ReviewDiffMetrics.displayNumber(for: contextSame) == "675")
        #expect(ReviewDiffMetrics.displayNumber(for: contextShifted) == "681")
    }

    @Test func highlightMapsSwiftSnapshotOntoDiffLines() {
        let oldText = "let foo = 1\nlet bar = 2\n"
        let newText = "let foo = 1\nlet baz = 3\n"
        let oldStarts = ReviewSyntaxHighlighter.lineStarts(for: oldText)
        let newStarts = ReviewSyntaxHighlighter.lineStarts(for: newText)
        #expect(oldStarts == [0, 12])
        #expect(newStarts == [0, 12])

        func keyword(at start: Int) -> SyntaxSpan {
            SyntaxSpan(utf16Start: start, utf16Length: 3, red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        }
        let fileID = "Test.swift"
        let key = reviewDiffKey(fileID, .unstaged)
        let highlights: [String: HighlightedSource] = [
            "old:\(key)": HighlightedSource(
                identity: "old",
                appearanceGeneration: 1,
                spans: [keyword(at: 0), keyword(at: 12)],
                lineStarts: oldStarts
            ),
            "new:\(key)": HighlightedSource(
                identity: "new",
                appearanceGeneration: 1,
                spans: [keyword(at: 0), keyword(at: 12)],
                lineStarts: newStarts
            ),
        ]

        let deletion = DiffLine(kind: .deletion, oldNumber: 2, newNumber: nil, text: "let bar = 2", missingNewline: false)
        let addition = DiffLine(kind: .addition, oldNumber: nil, newNumber: 2, text: "let baz = 3", missingNewline: false)
        let context = DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "let foo = 1", missingNewline: false)

        let delRuns = ReviewHighlightMapper.runs(for: deletion, fileID: fileID, comparison: .unstaged, highlights: highlights)
        let addRuns = ReviewHighlightMapper.runs(for: addition, fileID: fileID, comparison: .unstaged, highlights: highlights)
        let ctxRuns = ReviewHighlightMapper.runs(for: context, fileID: fileID, comparison: .unstaged, highlights: highlights)

        #expect(delRuns?.count == 1)
        #expect(delRuns?.first?.location == 0 && delRuns?.first?.length == 3)
        #expect(addRuns?.count == 1)
        #expect(addRuns?.first?.location == 0 && addRuns?.first?.length == 3)
        #expect(ctxRuns?.count == 1)
        #expect(ctxRuns?.first?.location == 0 && ctxRuns?.first?.length == 3)
    }

    @Test func highlightContextFallsBackToOldWhenNewIsMissing() {
        let oldText = "let foo = 1\n"
        let oldStarts = ReviewSyntaxHighlighter.lineStarts(for: oldText)
        let fileID = "Fallback.swift"
        let key = reviewDiffKey(fileID, .unstaged)
        let highlights: [String: HighlightedSource] = [
            "old:\(key)": HighlightedSource(
                identity: "old",
                appearanceGeneration: 1,
                spans: [SyntaxSpan(utf16Start: 0, utf16Length: 3, red: 0.1, green: 0.5, blue: 0.9, alpha: 1)],
                lineStarts: oldStarts
            ),
        ]
        let context = DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "let foo = 1", missingNewline: false)
        let runs = ReviewHighlightMapper.runs(for: context, fileID: fileID, comparison: .unstaged, highlights: highlights)
        #expect(runs?.count == 1)
        #expect(runs?.first?.location == 0 && runs?.first?.length == 3)
    }

    @Test func stickyFileHeaderStaysPinnedThenPushesOutWithTheFile() {
        let header = ReviewFileStickyMetrics.headerHeight
        let pinTop: CGFloat = 12

        #expect(ReviewFileStickyMetrics.headerOffset(sectionMinY: pinTop, sectionMaxY: 400, pinTop: pinTop) == 0)
        #expect(ReviewFileStickyMetrics.headerOffset(sectionMinY: 80, sectionMaxY: 400, pinTop: pinTop) == 0)

        let pinned = ReviewFileStickyMetrics.headerOffset(sectionMinY: -20, sectionMaxY: 500, pinTop: pinTop)
        #expect(pinned == pinTop - (-20))

        let leaving = ReviewFileStickyMetrics.headerOffset(sectionMinY: -200, sectionMaxY: 30, pinTop: pinTop)
        #expect(leaving == 30 - (-200) - header)
        #expect(-200 + leaving + header == 30)
        #expect(ReviewFileStickyMetrics.contentCull(headerOffset: leaving) == leaving)
    }

    @Test func stickyFileHeaderCullMatchesOverlap() {
        #expect(ReviewFileStickyMetrics.contentCull(headerOffset: 0) == 0)
        #expect(ReviewFileStickyMetrics.contentCull(headerOffset: 18) == 18)
        #expect(ReviewFileStickyMetrics.contentCull(headerOffset: -4) == 0)
    }

    @Test func highlightMissingSpansFallsBackToLabelColor() {
        let fileID = "Missing.swift"
        let deletion = DiffLine(kind: .deletion, oldNumber: 1, newNumber: nil, text: "let x = 1", missingNewline: false)
        #expect(ReviewHighlightMapper.runs(for: deletion, fileID: fileID, comparison: .unstaged, highlights: [:]) == nil)

        let key = reviewDiffKey(fileID, .unstaged)
        let empty = HighlightedSource(identity: "new", appearanceGeneration: 1, spans: [], lineStarts: [0])
        #expect(ReviewHighlightMapper.runs(for: deletion, fileID: fileID, comparison: .unstaged, highlights: ["old:\(key)": empty]) == nil)

        let outOfRange = HighlightedSource(
            identity: "new",
            appearanceGeneration: 1,
            spans: [SyntaxSpan(utf16Start: 0, utf16Length: 3, red: 1, green: 0, blue: 0, alpha: 1)],
            lineStarts: [0]
        )
        let badLine = DiffLine(kind: .deletion, oldNumber: 99, newNumber: nil, text: "let x = 1", missingNewline: false)
        #expect(ReviewHighlightMapper.runs(for: badLine, fileID: fileID, comparison: .unstaged, highlights: ["old:\(key)": outOfRange]) == nil)
    }
}
