import Testing
@testable import GenesisTerminal

@MainActor
struct GenesisTerminalTests {
    @Test func startsWithExactlyOneSession() {
        let model = TerminalModel()
        #expect(model.sessions.count == 1)
        #expect(model.selectedSession != nil)
        #expect(!model.isShowingSettings)
    }

    @Test func navigationHistoryTracksSelections() {
        let model = TerminalModel()
        let second = model.addSession(kind: .terminal, title: "Dev", cwd: "~/Lume", gitRef: "6ed58ac4")
        model.select(.session(second.id))
        #expect(model.selection == .session(second.id))
        #expect(model.canGoBack)

        model.goBack()
        #expect(model.selectedSession?.id == model.sessions.first?.id)
        #expect(model.canGoForward)

        model.goForward()
        #expect(model.selection == .session(second.id))
    }

    @Test func submittingKeepsUniformSession() {
        let model = TerminalModel()
        let before = model.selectedSession
        model.submit(command: "codex")
        #expect(model.selectedSession?.id == before?.id)
        #expect(model.selectedSession?.kind == .terminal)
        #expect(model.selectedSession?.title == before?.title)
    }

    @Test func confirmedMetricsRemainExact() {
        #expect(ShellMetrics.searchHeight == 30)
        #expect(ShellMetrics.searchCornerRadius == 15)
        #expect(ShellMetrics.sidebarRowHeight == 28)
        #expect(ShellMetrics.navigationWidth == 92)
        #expect(ShellMetrics.navigationHeight == 32)
        #expect(ShellMetrics.trafficLightDiameter == 12)
        #expect(ShellMetrics.detailInset == 10)
        #expect(ShellMetrics.detailCornerRadius == 20)
        #expect(ShellMetrics.sidebarDefaultWidth == 172)
        #expect(ShellMetrics.sessionRowHeight == 62)
        #expect(ShellMetrics.sessionIconSize == 32)
    }

    @Test func sidebarResizeClampsToItsSupportedRange() {
        let model = TerminalModel()

        model.resizeSidebar(to: 220, availableWidth: 960)
        #expect(model.sidebarWidth == 220)

        model.resizeSidebar(to: 100, availableWidth: 960)
        #expect(model.sidebarWidth == ShellMetrics.sidebarMinimumWidth)

        model.resizeSidebar(to: 400, availableWidth: 960)
        #expect(model.sidebarWidth == ShellMetrics.sidebarMaximumWidth)
    }

    @Test func ansiParserHandlesBasicSGR() {
        let segments = AnsiParser.parse("\u{1B}[32mgreen\u{1B}[0m plain")
        #expect(segments.count == 2)
        #expect(segments[0].text == "green")
        #expect(segments[0].color == .green)
        #expect(segments[1].text == " plain")
        #expect(segments[1].color == .default)
    }

    @Test func mockEngineEchoesUnknownCommands() {
        let out = MockTerminalEngine.response(for: "foobar --x", kind: .terminal)
        #expect(out.count == 1)
        #expect(out[0].contains("foobar --x"))
    }

    @Test func searchFiltersByTitleCwdAndBranch() {
        let model = TerminalModel()
        model.searchText = "lume"
        #expect(model.filteredSessions().count == 1)
        model.searchText = "6ed58ac4"
        #expect(model.filteredSessions().count == 1)
        model.searchText = "no-match-xyz"
        #expect(model.filteredSessions().isEmpty)
        #expect(!model.isSettingsVisibleInFilter)
        model.searchText = "sett"
        #expect(model.isSettingsVisibleInFilter)
    }
}
