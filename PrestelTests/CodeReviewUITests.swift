import AppKit
import SwiftUI
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

    @Test func firstOpenSpinnerStaysOnHiddenIdentityUntilASnapshotExists() {
        #expect(
            ReviewDisplayedLoadState.resolve(loadState: .hidden, lastVisible: .hidden, hasSnapshot: false) == .hidden
        )
        #expect(
            ReviewDisplayedLoadState.resolve(loadState: .resolving, lastVisible: .hidden, hasSnapshot: false) == .hidden
        )
        #expect(
            ReviewDisplayedLoadState.resolve(loadState: .loading, lastVisible: .hidden, hasSnapshot: false) == .hidden
        )
        #expect(
            ReviewDisplayedLoadState.resolve(loadState: .ready, lastVisible: .hidden, hasSnapshot: true) == .ready
        )
        #expect(
            ReviewDisplayedLoadState.resolve(loadState: .hidden, lastVisible: .ready, hasSnapshot: true) == .ready
        )
        #expect(
            ReviewDisplayedLoadState.resolve(loadState: .noRepository, lastVisible: .hidden, hasSnapshot: false) == .noRepository
        )
    }

    @Test func slidePaintDoesNotAdoptASnapshotThatArrivesMidSlide() {
        let frozen = ReviewSlidePaint(loadState: .hidden, hasSnapshot: false)
        let live = ReviewSlidePaint(loadState: .ready, hasSnapshot: true)
        #expect(frozen != live)
        #expect(frozen.hasSnapshot == false)
        #expect(frozen.loadState == .hidden)
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

    @Test func openingReviewOnFirstTabReachesReadyWithoutSwitchingTabs() async throws {
        let repo = try makeTemporaryGitRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let model = TerminalModel(directory: repo.path)
        let controller = TerminalWindowController(model: model)
        let window = try #require(controller.window)
        defer { controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window)) }
        window.setFrame(NSRect(x: 0, y: 0, width: 960, height: 650), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        ShellPanelAnimation.run { model.reviewVisible = true }
        window.contentView?.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            switch controller.review.loadState {
            case .ready, .noRepository, .noWorkingTree, .unavailable, .error, .noTerminal:
                break
            default:
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            break
        }

        #expect(controller.review.loadState == .ready)
        #expect(controller.review.snapshot != nil)
        #expect(model.tabs.count == 1)
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

    @Test func tallDiffDocumentDoesNotAllocateAFullHeightBackingStore() {
        let file = ChangedFile(
            identityPath: .from("Long.swift"),
            kind: .modified,
            comparisons: [
                ComparisonSummary(
                    kind: .unstaged,
                    additions: 4000,
                    deletions: 0,
                    isBinary: false,
                    oldPath: nil,
                    newPath: .from("Long.swift"),
                    oldMode: nil,
                    newMode: nil,
                    oldOID: nil,
                    newOID: nil
                )
            ],
            oldPath: nil
        )
        let rows: [ReviewDocumentRow] = (0..<4000).map { index in
            .code(
                DiffLine(kind: .addition, oldNumber: nil, newNumber: index + 1, text: "let line\(index) = \(index)", missingNewline: false),
                fileID: file.id,
                comparison: .unstaged,
                revision: "rev",
                hunkIndex: 0,
                lineIndex: index
            )
        }
        let contentHeight = ReviewDocumentBuilder.contentHeight(of: rows)
        #expect(contentHeight > 10_000)

        // Production geometry: the pane is the full file, and the file list
        // clips it to the viewport. Vertical scrolling belongs to that list.
        let pane = ReviewDiffPane(frame: NSRect(x: 0, y: 0, width: 420, height: contentHeight))
        pane.reload(rows: rows, highlights: [:], showWhitespace: false, file: file)

        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        outer.drawsBackground = false
        outer.hasVerticalScroller = false
        outer.hasHorizontalScroller = false
        outer.automaticallyAdjustsContentInsets = false
        // The file list is a flipped scroller: y = 0 is the top of the file.
        let content = FlippedReviewListDocument(frame: NSRect(x: 0, y: 0, width: 420, height: contentHeight))
        pane.frame = NSRect(x: 0, y: 0, width: 420, height: contentHeight)
        content.addSubview(pane)
        outer.documentView = content

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        root.wantsLayer = true
        window.contentView = root
        outer.frame = root.bounds
        root.addSubview(outer)

        let scrolled: CGFloat = 1800
        outer.contentView.scroll(to: NSPoint(x: 0, y: scrolled))
        outer.reflectScrolledClipView(outer.contentView)
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let document = documentView(in: pane)
        let documentHeight = document?.frame.height ?? 0
        #expect(documentHeight > 10_000)
        #expect(abs(documentHeight - contentHeight) < 1)

        let slice = pane.diffDrawingSliceFrame
        #expect(slice.height > 40)
        #expect(slice.height < 400)
        #expect(abs(slice.minY - scrolled) < 2)
        #expect(pane.diffVisibleOrigin.y == 0)
        #expect(pane.stickyGutterFrame.minX == 0)
        let tall = fullHeightBackingStores(in: root, tallerThan: 2_000)
        #expect(tall.isEmpty, "full-height backing stores: \(tall.joined(separator: "; "))")
        #expect(sliceHasPaint(document?.subviews.first { $0.frame.height > 40 && $0.frame.height < 400 }))
        #expect(layerTreeHasPaint(root))
    }

    @Test func maskedTallDiffStillPaintsWithoutAFullHeightBackingStore() {
        let file = ChangedFile(
            identityPath: .from("Long.swift"),
            kind: .modified,
            comparisons: [
                ComparisonSummary(
                    kind: .unstaged,
                    additions: 4000,
                    deletions: 0,
                    isBinary: false,
                    oldPath: nil,
                    newPath: .from("Long.swift"),
                    oldMode: nil,
                    newMode: nil,
                    oldOID: nil,
                    newOID: nil
                )
            ],
            oldPath: nil
        )
        let rows: [ReviewDocumentRow] = (0..<4000).map { index in
            .code(
                DiffLine(kind: .addition, oldNumber: nil, newNumber: index + 1, text: "let line\(index) = \(index)", missingNewline: false),
                fileID: file.id,
                comparison: .unstaged,
                revision: "rev",
                hunkIndex: 0,
                lineIndex: index
            )
        }
        let contentHeight = ReviewDocumentBuilder.contentHeight(of: rows)
        let host = NSHostingView(rootView: MaskedDiffProbe(rows: rows, file: file, height: contentHeight))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 280)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let tall = fullHeightBackingStores(in: host, tallerThan: 2_000)
        #expect(tall.isEmpty, "full-height backing stores: \(tall.joined(separator: "; "))")
        #expect(layerTreeHasPaint(host))
    }

    private func documentView(in view: NSView) -> NSView? {
        if let scroll = view as? NSScrollView { return scroll.documentView }
        for subview in view.subviews {
            if let found = documentView(in: subview) { return found }
        }
        return nil
    }

    /// Layers taller than the viewport are fine as containers. A backing store
    /// (drawn contents, or a rasterized layer) of that height is the leak.
    private func fullHeightBackingStores(in root: NSView, tallerThan: CGFloat) -> [String] {
        var found: [String] = []
        func visit(_ view: NSView) {
            if let layer = view.layer {
                visitLayer(layer, viewName: String(describing: type(of: view)), into: &found, tallerThan: tallerThan)
            }
            for subview in view.subviews {
                visit(subview)
            }
        }
        visit(root)
        return found
    }

    private func visitLayer(_ layer: CALayer, viewName: String, into found: inout [String], tallerThan: CGFloat) {
        let height = layer.bounds.height
        if height > tallerThan {
            let pixels = contentsPixelHeight(layer.contents)
            let largeBitmap = (pixels ?? 0) > Int(tallerThan * 2)
            let unknownContents = layer.contents != nil && pixels == nil
            if largeBitmap || unknownContents || (layer.shouldRasterize && height > tallerThan) {
                found.append("\(viewName) \(Int(height))pt \(describeContents(layer.contents)) rasterize=\(layer.shouldRasterize)")
            }
        }
        for sublayer in layer.sublayers ?? [] {
            visitLayer(sublayer, viewName: viewName, into: &found, tallerThan: tallerThan)
        }
    }

    private func layerTreeHasPaint(_ view: NSView) -> Bool {
        guard let layer = view.layer else { return false }
        let width = max(Int(view.bounds.width.rounded(.down)), 1)
        let height = max(Int(view.bounds.height.rounded(.down)), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        layer.render(in: context)
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let x = min(width - 1, max(width / 2, 0))
        let y = min(height - 1, max(height / 2, 0))
        return pixels[(y * width + x) * 4 + 3] > 10
    }

    private func sliceHasPaint(_ slice: NSView?) -> Bool {
        guard let slice, slice.bounds.width > 2, slice.bounds.height > 2,
              let rep = slice.bitmapImageRepForCachingDisplay(in: slice.bounds) else { return false }
        slice.cacheDisplay(in: slice.bounds, to: rep)
        let x = max(rep.pixelsWide - 2, 0)
        let y = max(rep.pixelsHigh / 2, 0)
        guard let color = rep.colorAt(x: x, y: y) else { return false }
        return color.alphaComponent > 0.05
    }

    private func describeContents(_ contents: Any?) -> String {
        guard let contents else { return "nil" }
        if let pixels = contentsPixelHeight(contents) {
            return "\(pixels)px \(type(of: contents))"
        }
        let object = contents as AnyObject
        return "\(NSStringFromClass(type(of: object))) \(String(describing: contents).prefix(160))"
    }

    private func contentsPixelHeight(_ contents: Any?) -> Int? {
        guard let contents else { return nil }
        let typeID = CFGetTypeID(contents as CFTypeRef)
        if typeID == CGImage.typeID {
            return (contents as! CGImage).height
        }
        if let image = contents as? NSImage {
            return image.representations.first?.pixelsHigh
        }
        return nil
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

    /// A view between the diff and the list swallows `scrollWheel`. Reaching the
    /// list anyway means the gesture was delivered to that scroll view directly,
    /// which is what keeps elastic overscroll tracking.
    @Test func verticalDiffWheelReachesTheListScrollView() {
        let list = ListScrollRecorder(frame: NSRect(x: 0, y: 0, width: 220, height: 160))
        let content = FlippedReviewListDocument(frame: NSRect(x: 0, y: 0, width: 220, height: 800))
        let swallow = WheelSwallowingView(frame: content.bounds)
        let pane = ReviewDiffPane(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        pane.reload(rows: wideDiffRows(), highlights: [:], showWhitespace: false, file: wideDiffFile())
        content.addSubview(swallow)
        swallow.addSubview(pane)
        list.documentView = content

        pane.scrollDiffWheel(reviewWheelEvent(dx: 0, dy: 0, phase: ReviewWheelPhase.began))
        pane.scrollDiffWheel(reviewWheelEvent(dx: 0, dy: 24, phase: ReviewWheelPhase.changed))
        pane.scrollDiffWheel(reviewWheelEvent(dx: 1, dy: 18, phase: ReviewWheelPhase.changed))
        pane.scrollDiffWheel(reviewWheelEvent(dx: 0, dy: 0, phase: ReviewWheelPhase.ended))
        pane.scrollDiffWheel(reviewWheelEvent(dx: 0, dy: 12, phase: 0, momentum: ReviewWheelPhase.momentumBegan))
        pane.scrollDiffWheel(reviewWheelEvent(dx: 6, dy: 4, phase: 0, momentum: ReviewWheelPhase.momentumChanged))
        pane.scrollDiffWheel(reviewWheelEvent(dx: 0, dy: 0, phase: 0, momentum: ReviewWheelPhase.momentumEnded))

        #expect(list.wheels.map(\.phase.rawValue) == [
            NSEvent.Phase.began.rawValue,
            NSEvent.Phase.changed.rawValue,
            NSEvent.Phase.changed.rawValue,
            NSEvent.Phase.ended.rawValue,
            0, 0, 0
        ])
        #expect(list.wheels.map(\.momentum.rawValue) == [
            0, 0, 0, 0,
            NSEvent.Phase.began.rawValue,
            NSEvent.Phase.changed.rawValue,
            NSEvent.Phase.ended.rawValue
        ])
        #expect(list.wheels[1].dy == 24)
        #expect(pane.diffVisibleOrigin.y == 0)
    }

    @Test func horizontalDiffWheelStaysOutOfTheList() {
        let list = ListScrollRecorder(frame: NSRect(x: 0, y: 0, width: 220, height: 160))
        let content = FlippedReviewListDocument(frame: NSRect(x: 0, y: 0, width: 220, height: 800))
        let pane = ReviewDiffPane(frame: NSRect(x: 0, y: 0, width: 220, height: 140))
        pane.reload(rows: wideDiffRows(), highlights: [:], showWhitespace: false, file: wideDiffFile())
        content.addSubview(pane)
        list.documentView = content

        pane.scrollDiffWheel(reviewWheelEvent(dx: 0, dy: 0, phase: ReviewWheelPhase.began))
        pane.scrollDiffWheel(reviewWheelEvent(dx: 40, dy: 2, phase: ReviewWheelPhase.changed))
        pane.scrollDiffWheel(reviewWheelEvent(dx: 0, dy: 0, phase: ReviewWheelPhase.ended))

        #expect(list.wheels.isEmpty)
        #expect(pane.stickyGutterFrame.minX == 0)
    }

    @Test func reviewListPreservesTopOverscrollDuringLayout() async throws {
        let repo = try makeTemporaryGitRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        for index in 0..<24 {
            let lines = (0..<(8 + index * 73 % 240)).map { "let line\($0) = \($0)" }
            try (lines.joined(separator: "\n") + "\n").write(
                to: repo.appendingPathComponent(String(format: "File%02d.swift", index)),
                atomically: true,
                encoding: .utf8
            )
        }
        let session = TerminalSession(descriptor: TabDescriptor(directory: repo.path))
        let model = CodeReviewModel(expandByDefault: true)
        model.bind(visible: true, windowID: UUID(), session: session)
        defer { model.bind(visible: false, windowID: UUID(), session: session) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (model.loadState != .ready || model.diffs.count != 24), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.loadState == .ready)
        #expect(model.diffs.count == 24)

        let host = NSHostingView(rootView: CodeReviewPanel(model: model, visible: true))
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 420, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        func diffPanes(in view: NSView) -> [ReviewDiffPane] {
            (view as? ReviewDiffPane).map { [$0] } ?? view.subviews.flatMap { diffPanes(in: $0) }
        }
        let list = try #require(scrollViews(in: host).first)
        #expect((list.documentView?.frame.height ?? 0) > list.bounds.height * 3)
        var heights = [list.documentView?.frame.height ?? 0]
        for y: CGFloat in [2_000, 12_000, 24_000, 1_000_000, 0] {
            var bounds = list.contentView.bounds
            bounds.origin = NSPoint(x: 0, y: y)
            list.contentView.scroll(to: list.contentView.constrainBoundsRect(bounds).origin)
            list.reflectScrolledClipView(list.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            heights.append(list.documentView?.frame.height ?? 0)
            let document = try #require(list.documentView)
            let visible = list.documentVisibleRect
            let paneRects = diffPanes(in: host).map { $0.convert($0.bounds, to: document) }
            #expect(paneRects.contains { $0.intersects(visible) }, "No diff at scroll offset \(y): \(paneRects)")
            if y == 1_000_000 {
                #expect(paneRects.contains { abs($0.maxY - document.bounds.maxY + ShellMetrics.sidebarInset) < 1 }, "The last diff must reach the bottom of the document")
            }
        }
        var proposed = list.contentView.bounds
        proposed.origin = NSPoint(x: 0, y: -1_000_000)
        list.contentView.scroll(to: list.contentView.constrainBoundsRect(proposed).origin)
        list.reflectScrolledClipView(list.contentView)
        try await Task.sleep(for: .milliseconds(50))
        let top = list.contentView.bounds.minY
        var offsets: [CGFloat] = []
        for step in 1...12 {
            // AppKit's elastic scrolling moves the clip beyond its constrained
            // top. The next SwiftUI layout must preserve that native offset.
            list.contentView.scroll(to: NSPoint(x: 0, y: top - CGFloat(step) * 8))
            list.reflectScrolledClipView(list.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
            offsets.append(list.contentView.bounds.minY - top)
        }
        let expected = (1...12).map { -CGFloat($0) * 8 }
        print("REVIEW_TOP_BOUNCE heights=\(heights) offsets=\(offsets)")
        #expect(heights.max()! - heights.min()! < 1, "Scrolling changed the document height: \(heights)")
        #expect(zip(offsets, expected).allSatisfy { abs($0 - $1) < 1 }, "Layout cancelled the elastic offsets: \(offsets)")
    }

    @Test func diffSliceFollowsListOverscrollOrigin() {
        let rows = (0..<80).map { index in
            ReviewDocumentRow.code(
                DiffLine(kind: .addition, oldNumber: nil, newNumber: index + 1, text: "let line\(index) = \(index)", missingNewline: false),
                fileID: "Overscroll.swift",
                comparison: .unstaged,
                revision: "rev",
                hunkIndex: 0,
                lineIndex: index
            )
        }
        let contentHeight = ReviewDocumentBuilder.contentHeight(of: rows)
        #expect(contentHeight > 400)
        let file = ChangedFile(
            identityPath: .from("Overscroll.swift"),
            kind: .modified,
            comparisons: [
                ComparisonSummary(
                    kind: .unstaged,
                    additions: 80,
                    deletions: 0,
                    isBinary: false,
                    oldPath: nil,
                    newPath: .from("Overscroll.swift"),
                    oldMode: nil,
                    newMode: nil,
                    oldOID: nil,
                    newOID: nil
                )
            ],
            oldPath: nil
        )

        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 220))
        let clip = OverscrollClipView(frame: outer.bounds)
        outer.contentView = clip
        outer.hasVerticalScroller = false
        outer.hasHorizontalScroller = false
        outer.automaticallyAdjustsContentInsets = false
        let content = FlippedReviewListDocument(frame: NSRect(x: 0, y: 0, width: 240, height: contentHeight))
        let pane = ReviewDiffPane(frame: NSRect(x: 0, y: 0, width: 240, height: contentHeight))
        pane.reload(rows: rows, highlights: [:], showWhitespace: false, file: file)
        content.addSubview(pane)
        outer.documentView = content

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 220),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = outer
        outer.layoutSubtreeIfNeeded()

        let overscroll: CGFloat = -48
        outer.contentView.setBoundsOrigin(NSPoint(x: 0, y: overscroll))
        #expect(outer.contentView.bounds.origin.y < -20)
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        pane.scrollDiffDocument(to: .zero)

        let slice = pane.diffDrawingSliceFrame
        #expect(slice.minY < -20)
        #expect(slice.height > 180)
        #expect(slice.height < 400)
        #expect(pane.stickyGutterFrame.minX == 0)
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

private final class FlippedReviewListDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class ListScrollRecorder: NSScrollView {
    struct Wheel: Equatable {
        var phase: NSEvent.Phase
        var momentum: NSEvent.Phase
        var dx: CGFloat
        var dy: CGFloat
    }

    var wheels: [Wheel] = []

    override func scrollWheel(with event: NSEvent) {
        wheels.append(Wheel(
            phase: event.phase,
            momentum: event.momentumPhase,
            dx: event.scrollingDeltaX,
            dy: event.scrollingDeltaY
        ))
    }
}

/// Stops the responder chain so a vertical wheel only reaches the list if the
/// diff scroll view forwards it to that scroll view directly.
private final class WheelSwallowingView: NSView {
    override func scrollWheel(with event: NSEvent) {}
}

/// Lets a test place the clip origin above the document, the way a rubber-band does.
private final class OverscrollClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        proposedBounds
    }
}

private enum ReviewWheelPhase {
    static let began: Int64 = 1
    static let changed: Int64 = 2
    static let ended: Int64 = 4
    static let momentumBegan: Int64 = 1
    static let momentumChanged: Int64 = 2
    static let momentumEnded: Int64 = 3
}

private func reviewWheelEvent(dx: Int32, dy: Int32, phase: Int64, momentum: Int64 = 0) -> NSEvent {
    let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 2,
        wheel1: dy,
        wheel2: dx,
        wheel3: 0
    )!
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
    return NSEvent(cgEvent: event)!
}

private func wideDiffFile() -> ChangedFile {
    ChangedFile(
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
}

private func wideDiffRows() -> [ReviewDocumentRow] {
    let file = wideDiffFile()
    let long = String(repeating: "let value = 1234567890; ", count: 12)
    return [
        .code(DiffLine(kind: .deletion, oldNumber: 40, newNumber: nil, text: long, missingNewline: false), fileID: file.id, comparison: .unstaged, revision: "rev", hunkIndex: 0, lineIndex: 0),
        .code(DiffLine(kind: .addition, oldNumber: nil, newNumber: 41, text: long, missingNewline: false), fileID: file.id, comparison: .unstaged, revision: "rev", hunkIndex: 0, lineIndex: 1),
        .code(DiffLine(kind: .context, oldNumber: 41, newNumber: 42, text: long, missingNewline: false), fileID: file.id, comparison: .unstaged, revision: "rev", hunkIndex: 0, lineIndex: 2)
    ]
}

private struct MaskedDiffProbe: View {
    var rows: [ReviewDocumentRow]
    var file: ChangedFile
    var height: CGFloat

    var body: some View {
        ScrollView(.vertical) {
            ProbePane(rows: rows, file: file)
                .frame(height: height, alignment: .top)
                .compositingGroup()
                .mask(alignment: .top) {
                    Rectangle().padding(.top, 12)
                }
        }
        .frame(width: 420, height: 280)
    }
}

private struct ProbePane: NSViewRepresentable {
    var rows: [ReviewDocumentRow]
    var file: ChangedFile

    func makeNSView(context: Context) -> ReviewDiffPane {
        ReviewDiffPane()
    }

    func updateNSView(_ nsView: ReviewDiffPane, context: Context) {
        nsView.reload(rows: rows, highlights: [:], showWhitespace: false, file: file)
    }
}

private func makeTemporaryGitRepository() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("prestel-review-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "init.defaultBranch=main", "init"]
    process.currentDirectoryURL = url
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "PrestelTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git init failed"])
    }
    return url
}
