import AppKit
import Testing
@testable import GenesisTerminal

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
}
