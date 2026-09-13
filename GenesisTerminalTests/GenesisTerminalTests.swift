import AppKit
import Darwin
import SwiftTerm
import Testing
@testable import GenesisTerminal

@Suite(.serialized)
@MainActor
struct GenesisTerminalTests {
    @Test func independentModelsAndFilteringPreserveSessions() {
        let a = TerminalModel()
        let b = TerminalModel()
        let first = a.selectedTab!
        a.newTab()
        a.newTab()
        b.newTab()
        b.newTab()
        let bSelection = b.selectedID
        a.select(first.id)
        a.searchText = "no-match"
        #expect(a.filteredTabs.isEmpty)
        #expect(a.tabs.count == 3)
        #expect(b.tabs.count == 3)
        #expect(b.selectedID == bSelection)
        #expect(Set((a.tabs + b.tabs).map(\.id)).count == 6)
        #expect(a.tabs.first === first)
        #expect(first.process == nil)
        a.searchText = ""
        #expect(a.filteredTabs.count == 3)
    }

    @Test func navigationAndRecentlyClosedAreBounded() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab()
        model.cycle(1)
        #expect(model.selectedID == first)
        model.cycle(-1)
        #expect(model.selectedID == second.id)
        model.navigate(-1)
        #expect(model.selectedID == first)
        model.closeTab(second.id)
        model.reopenClosedTab()
        #expect(model.selectedID != second.id)
        #expect(model.tabs.count == 2)
        for _ in 0..<25 {
            let tab = model.newTab()
            model.closeTab(tab.id)
        }
        #expect(model.recentlyClosed.count == 20)
        #expect(model.tabs.allSatisfy { $0.state == .ready })
    }

    @Test func restorationIsOnlyLightweightContext() throws {
        let model = TerminalModel()
        model.newTab(directory: "/private/tmp")
        model.sidebarVisible = false
        let encoded = try JSONEncoder().encode(model.descriptor)
        let descriptor = try JSONDecoder().decode(WindowDescriptor.self, from: encoded)
        let restored = TerminalModel(restoration: descriptor)
        #expect(restored.tabs.map(\.id) == model.tabs.map(\.id))
        #expect(restored.selectedID == model.selectedID)
        #expect(!restored.sidebarVisible)
        #expect(restored.tabs.allSatisfy { $0.process == nil })
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("Pid"))
        #expect(!json.contains("childfd"))
    }

    @Test func invalidRestorationFallsBackSafely() {
        let id = UUID()
        let descriptor = WindowDescriptor(id: UUID(), tabs: [TabDescriptor(id: id, directory: "/missing-genesis-folder"), TabDescriptor(id: id)], selectedID: UUID(), sidebarVisible: true, sidebarWidth: 900)
        let restored = TerminalModel(restoration: descriptor)
        #expect(restored.tabs.count == 1)
        #expect(restored.selectedID == id)
        #expect(restored.sidebarWidth == 300)
        #expect(restored.selectedTab?.directory == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test func shellMetadataAndQuoting() {
        #expect(ShellConfiguration.escapedPath("/tmp/a b's;$(x)文") == "'/tmp/a b'\\''s;$(x)文'")
        #expect(ShellConfiguration.localDirectory(fromOSC: "file://localhost/tmp/a%20b") == "/tmp/a b")
        #expect(ShellConfiguration.localDirectory(fromOSC: "file://remote.invalid/tmp") == nil)
        #expect(ShellConfiguration.localDirectory(fromOSC: "https://example.com/tmp") == nil)
        #expect(ShellConfiguration.loginShell.hasPrefix("/"))
        #expect(ShellConfiguration.environment.contains("TERM=xterm-256color"))
    }

    @Test func parserHandlesFragmentedUTF8AndAlternateScreen() {
        let view = GenesisTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 420), options: TerminalOptions(scrollback: 100))
        let bytes = Array("Aé文🙂e\u{301}".utf8)
        for byte in bytes { view.feed(byteArray: [byte][...]) }
        #expect(view.terminalStateSnapshot().visibleRows.first?.text.contains("Aé文🙂e\u{301}") == true)
        for byte in Array("\u{1b}[?1049hALT\u{1b}[?1049l".utf8) { view.feed(byteArray: [byte][...]) }
        let primary = view.terminalStateSnapshot().visibleRows.map(\.text).joined(separator: "\n")
        #expect(primary.contains("Aé文🙂"))
        #expect(!primary.contains("ALT"))
    }

    @Test func appearanceChangeRefreshesTerminalAndGlass() {
        let view = GenesisTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 420), options: TerminalOptions(scrollback: 100))
        view.applyPreferences()
        view.feed(byteArray: Array("theme".utf8)[...])

        // Simulate macOS flipping light -> dark -> light while running.
        // Background tabs are detached (no window); the refresh must be safe
        // there and must keep the surface usable.
        for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            view.appearance = NSAppearance(named: name)
            view.viewDidChangeEffectiveAppearance()
            view.viewDidMoveToWindow()
            let text = view.terminalStateSnapshot().visibleRows.map(\.text).joined(separator: "\n")
            #expect(text.contains("theme"))
        }

        // Glass tint follows the view's own effective appearance so AppKit
        // and SwiftUI chrome can't diverge into a half-light/half-dark state.
        let glass = ThemedGlassView()
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.refreshTint()
        #expect(abs((glass.tintColor?.cgColor.alpha ?? -1) - 0.18) < 0.001)
        glass.appearance = NSAppearance(named: .aqua)
        glass.viewDidChangeEffectiveAppearance()
        #expect(abs((glass.tintColor?.cgColor.alpha ?? -1) - 0.12) < 0.001)
    }

    @Test func markedTextIsNotSentBeforeCommitAndClipboardIsDenied() async throws {
        let session = TerminalSession(descriptor: TabDescriptor())
        session.start()
        defer { session.close() }
        let view = try #require(session.surface)
        view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(!String(decoding: view.getBufferAsData(), as: UTF8.self).contains("日本"))
        view.unmarkText()
        #expect(!view.hasMarkedText())
        #expect(session.clipboardRead(source: view) == nil)
        let before = NSPasteboard.general.changeCount
        session.clipboardCopy(source: view, content: Data("untrusted".utf8))
        #expect(NSPasteboard.general.changeCount == before)
    }

    @Test func sixLivePTYsSurviveTabAndWindowSwitching() async throws {
        let a = TerminalModel(directory: "/private/tmp")
        let b = TerminalModel(directory: "/")
        for _ in 0..<2 { a.newTab(); b.newTab() }
        let all = a.tabs + b.tabs
        all.forEach { $0.start() }
        defer { a.closeAll(); b.closeAll() }
        let pids = try all.map { try #require($0.process?.shellPid) }
        #expect(Set(pids).count == 6)
        for (i, tab) in all.enumerated() {
            tab.process?.send(data: Array("printf 'GEN_%s_%s\\n' \(i) READY\r".utf8)[...])
        }
        try await eventually { all.enumerated().allSatisfy { index, tab in buffer(tab).contains("GEN_\(index)_READY") } }
        a.select(a.tabs[0].id)
        b.select(b.tabs[2].id)
        a.searchText = "hidden"
        for (i, tab) in all.enumerated() {
            tab.process?.send(data: Array("sleep 0.1; printf 'LIVE_%s_%s\\n' \(i) OK\r".utf8)[...])
        }
        try await eventually { all.enumerated().allSatisfy { index, tab in buffer(tab).contains("LIVE_\(index)_OK") } }
        #expect(all.allSatisfy { $0.process?.running == true })
        #expect(a.tabs[0].currentDirectory == "/private/tmp")
        #expect(b.tabs[0].currentDirectory == "/")
        a.closeAll()
        try await eventually { pids.prefix(3).allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        #expect(b.tabs.allSatisfy { $0.process?.running == true })
    }

    @Test func liveCwdQuotingInterruptAndProcessReaping() async throws {
        let session = TerminalSession(descriptor: TabDescriptor(directory: "/"))
        session.start()
        defer { session.close() }
        let pid = try #require(session.process?.shellPid)
        session.process?.send(data: Array("cd /private/tmp; printf 'PATH_%s\\n' READY\r".utf8)[...])
        try await eventually { buffer(session).contains("PATH_READY") }
        #expect(session.currentDirectory == "/private/tmp")
        session.process?.send(data: Array("sleep 30\r".utf8)[...])
        try await eventually { session.hasActiveJobs }
        session.process?.send(data: [3][...])
        try await eventually { !session.hasActiveJobs }
        session.process?.send(data: Array("sleep 30 &\r".utf8)[...])
        try await eventually { session.hasActiveJobs }
        let children = ProcessInspection.children(of: pid)
        session.close()
        try await eventually { ([pid] + children).allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        #expect(session.state == .closed)
        #expect(session.surface == nil)
    }

    @Test func headerDirectoryFollowsShellWithoutOSC7() async throws {
        // Regression: header showed the tab's starting directory (e.g.
        // ~/terminals) after `cd ~/genesis` because zsh with
        // TERM_PROGRAM=Genesis never sends OSC 7. The session must fall back
        // to kernel truth via proc_pidinfo — and fast, not just via the 2s
        // backup poll.
        let session = TerminalSession(descriptor: TabDescriptor(directory: "/"))
        session.start()
        defer { session.close() }
        session.process?.send(data: Array("cd /private/tmp; printf 'HDR_%s\\n' READY\r".utf8)[...])
        try await eventually { buffer(session).contains("HDR_READY") }
        try await eventually { session.currentDirectory == "/private/tmp" }
        // A follow-up command's output must push the header well before the
        // 2s backup poll would. (Its echo-triggered debounced refresh reads
        // the already-changed cwd.)
        session.process?.send(data: Array("printf 'HDR2_%s\\n' DONE\r".utf8)[...])
        try await eventually { buffer(session).contains("HDR2_DONE") }
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while session.directory != "/private/tmp", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.directory == "/private/tmp")
        #expect(ShellConfiguration.displayDirectory(FileManager.default.homeDirectoryForCurrentUser.path) == "~")
    }

    private func buffer(_ session: TerminalSession) -> String {
        session.surface.map { String(decoding: $0.getBufferAsData(), as: UTF8.self) } ?? ""
    }
    private func eventually(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
        #expect(predicate(), sourceLocation: sourceLocation)
    }
}
