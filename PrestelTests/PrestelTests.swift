import AppKit
import Darwin
import QuartzCore
import SwiftTerm
import SwiftUI
import Testing
@testable import Prestel

@Suite(.serialized)
@MainActor
struct PrestelTests {
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

    @Test func numberedTabSelectionUsesBrowserPositionsAndCurrentOrder() {
        let model = TerminalModel()
        for _ in 0..<9 { model.newTab() }
        let ids = model.tabs.map(\.id)

        for number in 1...8 {
            model.selectTab(number: number)
            #expect(model.selectedID == ids[number - 1])
        }
        model.selectTab(number: 9)
        #expect(model.selectedID == ids[9])
        model.moveTab(ids[9], to: 0)
        model.selectTab(number: 1)
        #expect(model.selectedID == ids[9])
        model.selectTab(number: 9)
        #expect(model.selectedID == ids[8])
        model.navigate(-1)
        #expect(model.selectedID == ids[9])
    }

    @Test func numberedTabSelectionIgnoresUnavailablePositionsAndArchivedTabs() {
        let model = TerminalModel()
        let first = model.selectedID!
        let archived = model.newTab().id
        model.archiveTab(archived)
        model.select(archived)
        for number in [0, 2, 8, 10] {
            model.selectTab(number: number)
            #expect(model.selectedID == archived)
        }
        model.selectTab(number: 9)
        #expect(model.selectedID == first)
        #expect(!model.showingArchive)
        model.showSettings()
        let settings = model.selectedID
        model.selectTab(number: 1)
        #expect(model.selectedID == first)
        model.selectTab(number: 9)
        #expect(model.selectedID == settings)
        #expect(model.selectedTab?.kind == .settings)
    }

    @Test func numberedTabSelectionKeepsFolderOrderDuringSearchAndCollapse() throws {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let d = model.newTab().id
        model.select(a)
        let folder = try #require(model.makeFolder(containing: a))
        model.add(c, to: folder.id)
        model.toggleFolder(folder.id)
        model.select(d)
        model.searchText = "no-match"

        model.selectTab(number: 2)
        #expect(model.selectedID == c)
        #expect(model.selectedTabIDs == [c])
        model.selectTab(number: 3)
        #expect(model.selectedID == b)
        model.selectTab(number: 9)
        #expect(model.selectedID == d)
        #expect(model.searchText == "no-match")
        #expect(model.folders.first?.collapsed == true)
    }

    @Test func numberedTabSelectionFocusesBothSplitPanes() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        model.select(first)
        model.split(with: second, on: .trailing)

        model.selectTab(number: 2)
        #expect(model.selectedID == second)
        #expect(model.visibleSplit?.focusedID == second)
        model.selectTab(number: 1)
        #expect(model.selectedID == first)
        #expect(model.visibleSplit?.focusedID == first)
        model.selectTab(number: 9)
        #expect(model.selectedID == third)
        #expect(model.visibleSplit == nil)
        #expect(model.splits.count == 1)
    }

    @Test func archiveRemovesTabWithoutClosingTheSession() {
        let model = TerminalModel()
        let first = model.selectedTab!
        let second = model.newTab()
        model.select(first.id)
        model.archiveTab(first.id)
        #expect(model.tabs.map(\.id) == [second.id])
        #expect(model.archived.map(\.id) == [first.id])
        #expect(model.archived.first === first)
        #expect(model.selectedID == second.id)
        #expect(model.recentlyClosed.isEmpty)
        #expect(first.state == .ready)
        model.unarchiveTab(first.id)
        #expect(model.tabs.map(\.id) == [second.id, first.id])
        #expect(model.archived.isEmpty)
        #expect(model.selectedID == first.id)
        #expect(model.tabs.last === first)
        #expect(!model.showingArchive)
    }

    @Test func archivingTheLastTabOpensAReplacement() {
        let model = TerminalModel()
        let first = model.selectedTab!
        model.archiveTab(first.id)
        #expect(model.archived.map(\.id) == [first.id])
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].id != first.id)
        #expect(model.selectedID == model.tabs[0].id)
    }

    @Test func archiveDissolvesASplitPair() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        model.select(first)
        model.split(with: second, on: .trailing)
        #expect(model.visibleSplit != nil)
        model.archiveTab(second)
        #expect(model.visibleSplit == nil)
        #expect(model.archived.map(\.id) == [second])
        #expect(model.tabs.map(\.id) == [first])
        #expect(model.selectedID == first)
    }

    @Test func archivedTabsRestoreAndLegacyWindowsDecode() throws {
        let model = TerminalModel()
        let keep = model.selectedID!
        let archived = model.newTab(directory: "/private/tmp")
        model.archiveTab(archived.id)
        let encoded = try JSONEncoder().encode(model.descriptor)
        let descriptor = try JSONDecoder().decode(WindowDescriptor.self, from: encoded)
        #expect(descriptor.archivedTabs.map(\.id) == [archived.id])
        #expect(descriptor.tabs.map(\.id) == [keep])
        let restored = TerminalModel(restoration: descriptor)
        #expect(restored.tabs.map(\.id) == [keep])
        #expect(restored.archived.map(\.id) == [archived.id])
        #expect(restored.archived[0].directory == "/private/tmp")
        #expect(restored.archived[0].process == nil)
        #expect(restored.selectedID == keep)

        let legacy = try JSONDecoder().decode(
            WindowDescriptor.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","tabs":[{"id":"00000000-0000-0000-0000-000000000002","kind":"terminal","title":"Local","directory":"/tmp"}],"selectedID":"00000000-0000-0000-0000-000000000002","sidebarVisible":true,"sidebarWidth":172}"#.utf8)
        )
        #expect(legacy.archivedTabs.isEmpty)
        #expect(legacy.folders.isEmpty)
    }

    @Test func closeArchivedTabRecordsRecentlyClosed() {
        let model = TerminalModel()
        let first = model.selectedTab!
        let second = model.newTab()
        model.archiveTab(second.id)
        model.closeArchivedTab(second.id)
        #expect(model.archived.isEmpty)
        #expect(model.recentlyClosed.last?.directory == second.directory)
        #expect(second.state == .closed)
        #expect(model.tabs.map(\.id) == [first.id])
    }

    @Test func tabContextMenuIncludesArchive() {
        let hit = TabRowHitNSView(frame: .zero)
        hit.onArchive = {}
        hit.onClose = {}
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        let titles = hit.menu(for: event)?.items.map(\.title) ?? []
        #expect(titles.contains("Rename Tab"))
        #expect(titles.contains("New Folder"))
        #expect(titles.contains("Archive"))
        #expect(titles.contains("Close Tab"))
    }

    @Test func archiveListSearchAndShowingArchive() {
        let model = TerminalModel()
        let keep = model.selectedID!
        let tmp = model.newTab(directory: "/private/tmp")
        model.archiveTab(tmp.id)
        model.showingArchive = true
        #expect(model.filteredArchived.map(\.id) == [tmp.id])
        model.searchText = "tmp"
        #expect(model.filteredArchived.map(\.id) == [tmp.id])
        model.searchText = "no-such-tab"
        #expect(model.filteredArchived.isEmpty)
        model.searchText = ""
        model.select(keep)
        #expect(!model.showingArchive)
    }

    @Test func selectingAnArchivedTabDoesNotUnarchiveIt() {
        let model = TerminalModel()
        let keep = model.selectedID!
        let archived = model.newTab()
        model.archiveTab(archived.id)
        model.showingArchive = true
        model.select(archived.id)
        #expect(model.archived.map(\.id) == [archived.id])
        #expect(model.tabs.map(\.id) == [keep])
        #expect(model.selectedID == archived.id)
        #expect(model.selectedTab === archived)
        #expect(model.showingArchive)
        model.unarchiveTab(archived.id)
        #expect(model.archived.isEmpty)
        #expect(model.tabs.map(\.id) == [keep, archived.id])
        #expect(model.selectedID == archived.id)
        #expect(!model.showingArchive)
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
        let descriptor = WindowDescriptor(id: UUID(), tabs: [TabDescriptor(id: id, directory: "/missing-prestel-folder"), TabDescriptor(id: id)], selectedID: UUID(), sidebarVisible: true, sidebarWidth: 900)
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
        // Universal TUI glass contract: truecolor advertisement + identity so
        // every TUI (not just OpenCode `system`) can inherit the terminal bg.
        #expect(ShellConfiguration.environment.contains("COLORTERM=truecolor"))
        #expect(ShellConfiguration.environment.contains("TERM_PROGRAM=Prestel"))
    }

    @Test func parserHandlesFragmentedUTF8AndAlternateScreen() {
        let view = PrestelView(frame: NSRect(x: 0, y: 0, width: 640, height: 420), options: TerminalOptions(scrollback: 100))
        let bytes = Array("Aé文🙂e\u{301}".utf8)
        for byte in bytes { view.feed(byteArray: [byte][...]) }
        #expect(view.terminalStateSnapshot().visibleRows.first?.text.contains("Aé文🙂e\u{301}") == true)
        for byte in Array("\u{1b}[?1049hALT\u{1b}[?1049l".utf8) { view.feed(byteArray: [byte][...]) }
        let primary = view.terminalStateSnapshot().visibleRows.map(\.text).joined(separator: "\n")
        #expect(primary.contains("Aé文🙂"))
        #expect(!primary.contains("ALT"))
    }

    @Test func appearanceChangeRefreshesTerminalAndGlass() {
        let view = PrestelView(frame: NSRect(x: 0, y: 0, width: 640, height: 420), options: TerminalOptions(scrollback: 100))
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

    @Test func terminalFontSizeClampsAndStepsWithoutLeavingTheRange() {
        withTerminalFontSize(nil) {
            #expect(TerminalFontSize.current == 13)
            #expect(TerminalFontSize.clamp(8 as CGFloat) == 9)
            #expect(TerminalFontSize.clamp(40 as CGFloat) == 32)
            #expect(TerminalFontSize.clamp(CGFloat.nan) == 13)
            #expect(TerminalFontSize.increase() == 14)
            #expect(TerminalFontSize.decrease() == 13)
            #expect(TerminalFontSize.set(32) == 32)
            #expect(TerminalFontSize.increase() == 32)
            #expect(!TerminalFontSize.canIncrease)
            #expect(TerminalFontSize.set(9) == 9)
            #expect(TerminalFontSize.decrease() == 9)
            #expect(!TerminalFontSize.canDecrease)
            #expect(TerminalFontSize.reset() == 13)
            #expect(TerminalFontSize.isDefault)
        }
    }

    @Test func commandPlusAndMinusAreTerminalScaleShortcuts() {
        func event(characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )!
        }
        #expect(TerminalFontSize.shortcut(for: event(characters: "=", keyCode: 24, flags: .command)) == .increase)
        #expect(TerminalFontSize.shortcut(for: event(characters: "+", keyCode: 24, flags: [.command, .shift])) == .increase)
        #expect(TerminalFontSize.shortcut(for: event(characters: "-", keyCode: 27, flags: .command)) == .decrease)
        #expect(TerminalFontSize.shortcut(for: event(characters: "0", keyCode: 29, flags: .command)) == .reset)
        #expect(TerminalFontSize.shortcut(for: event(characters: "+", keyCode: 69, flags: .command)) == .increase)
        #expect(TerminalFontSize.shortcut(for: event(characters: "-", keyCode: 78, flags: .command)) == .decrease)
        #expect(TerminalFontSize.shortcut(for: event(characters: "=", keyCode: 24, flags: [.command, .option])) == nil)
        #expect(TerminalFontSize.shortcut(for: event(characters: "=", keyCode: 24, flags: [])) == nil)
        #expect(TerminalFontSize.shortcut(for: event(characters: "k", keyCode: 40, flags: .command)) == nil)
    }

    @Test func applyingALargerFontPreservesGridByResizingWindow() async throws {
        try await withTerminalFontSize(13) {
            let model = TerminalModel()
            let controller = TerminalWindowController(model: model)
            let window = try #require(controller.window)
            defer {
                window.orderOut(nil)
                controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
            }
            window.orderFrontRegardless()
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            window.contentView?.layoutSubtreeIfNeeded()

            let surface = try #require(model.selectedTab?.surface)
            surface.applyPreferences()
            window.contentView?.layoutSubtreeIfNeeded()
            let windowSize = window.frame.size
            let cols = surface.terminalDimensions.cols
            let rows = surface.terminalDimensions.rows
            #expect(surface.font.pointSize == 13)
            #expect(cols > 0 && rows > 0)

            // Grow: same grid, bigger window, no animation.
            TerminalFontSize.increase()
            surface.applyPreferences()
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(surface.font.pointSize == 14)
            #expect(surface.terminalDimensions.cols == cols)
            #expect(surface.terminalDimensions.rows == rows)
            #expect(window.frame.width > windowSize.width)
            #expect(window.frame.height > windowSize.height)
            #expect(surface.layer?.animationKeys()?.isEmpty != false)
            let grownSize = window.frame.size

            TerminalFontSize.set(16)
            surface.applyPreferences()
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(surface.font.pointSize == 16)
            #expect(surface.terminalDimensions.cols == cols)
            #expect(surface.terminalDimensions.rows == rows)
            #expect(window.frame.width > grownSize.width)

            // Shrink: same grid, smaller window.
            let preShrinkWin = window.frame.size
            TerminalFontSize.decrease()
            surface.applyPreferences()
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(surface.font.pointSize == 15)
            #expect(surface.terminalDimensions.cols == cols)
            #expect(surface.terminalDimensions.rows == rows)
            #expect(window.frame.width < preShrinkWin.width)
            #expect(window.frame.height < preShrinkWin.height)
        }
    }

    @Test func terminalFontSizeChangesAreNotAnimated() {
        var durationIsZero = false
        var implicitAnimationDisabled = false
        var layerActionsDisabled = false
        TerminalFontSize.withoutAnimations {
            durationIsZero = NSAnimationContext.current.duration == 0
            implicitAnimationDisabled = NSAnimationContext.current.allowsImplicitAnimation == false
            layerActionsDisabled = CATransaction.disableActions()
        }
        #expect(durationIsZero)
        #expect(implicitAnimationDisabled)
        #expect(layerActionsDisabled)
    }

    @Test func markedTextIsNotSentBeforeCommitAndClipboardIsWriteOnly() async throws {
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
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        session.clipboardCopy(source: view, content: Data("from-osc52".utf8))
        #expect(NSPasteboard.general.string(forType: .string) == "from-osc52")
        #expect(session.clipboardRead(source: view) == nil)
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
        // ~/terminals) after `cd ~/prestel` because zsh with
        // TERM_PROGRAM=Prestel never sends OSC 7. The session must fall back
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

    @Test func toolbarsFitNarrowPanesAndLongTitles() {
        let model = TerminalModel(directory: "/private/tmp")
        model.selectedTab?.setDisplayTitle(String(repeating: "Long title ", count: 20))
        for sidebar in [false, true] {
            model.sidebarVisible = sidebar
            for (navigation, review, widths) in [(true, false, [160, 240, 320]),
                                                  (false, true, [160, 240, 320]),
                                                  (true, true, [320, 480, 640])] {
                let hosting = NSHostingController(rootView: TerminalToolbar(model: model,
                    showsNavigation: navigation, showsReviewToggle: review))
                for width in widths {
                    let fitted = hosting.sizeThatFits(in: CGSize(width: CGFloat(width), height: 100))
                    #expect(fitted.width <= CGFloat(width), "Toolbar exceeds its pane")
                    #expect(fitted.height <= 60, "Toolbar grows into the terminal")
                }
            }
        }
    }

    @Test func narrowSplitKeepsTerminalContentInsideItsCards() async throws {
        try await withTerminalFontSize(13) {
            let model = TerminalModel(directory: "/private/tmp")
            let first = model.tabs[0]
            let second = model.newTab(directory: "/private/tmp")
            model.sidebarVisible = false
            model.reviewVisible = true
            model.select(first.id)
            model.split(with: second.id, on: .trailing)
            model.tabs.forEach { $0.start() }
            let controller = TerminalWindowController(model: model)
            let window = try #require(controller.window)
            defer { controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window)) }
            window.setContentSize(NSSize(width: 760, height: 540))
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            try await Task.sleep(for: .milliseconds(500))
            window.contentView?.layoutSubtreeIfNeeded()
            let root = try #require(window.contentView)
            let layout = ShellLayout.resolve(.init(windowWidth: root.bounds.width,
                sidebarVisible: false, reviewVisible: true,
                preferredSidebarWidth: model.sidebarWidth, preferredReviewWidth: model.reviewWidth))
            let cards = SplitCardLayout.cards(in: CGSize(width: layout.detailWidth, height: root.bounds.height - 20),
                                             axis: .horizontal, fraction: 0.5, gap: ShellMetrics.splitCardGap)
            for (session, card) in [(first, cards.primary), (second, cards.secondary)] {
                let surface = try #require(session.surface)
                let frame = surface.convert(surface.bounds, to: root)
                let left = layout.detailOriginX + card.minX + 12
                let right = layout.detailOriginX + card.maxX - 12
                print("NARROW_LAYOUT expected=\(left)...\(right) actual=\(frame.minX)...\(frame.maxX)")
                #expect(frame.width > 0)
                #expect(frame.minX >= left - 1)
                #expect(frame.maxX <= right + 1)
            }
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                if let image = bitmap.representation(using: .png, properties: [:]) {
                    Attachment.record(image, named: "narrow-split.png")
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(3))) func sustainedOutputSurvivesLayoutAndSessionChanges() async throws {
        try await withTerminalFontSize(13) {
            let model = TerminalModel(directory: "/private/tmp")
            let controller = TerminalWindowController(model: model)
            let window = try #require(controller.window)
            defer {
                window.orderOut(nil)
                controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
            }
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            for _ in 0..<2 { model.newTab(directory: "/private/tmp") }
            let sessions = model.tabs
            let progress = ReliabilityProgress()
            let observations = try sessions.map { session in
                session.start()
                let surface = try #require(session.surface)
                return surface.observeOscEvents { event in
                    guard event.code == 777 else { return }
                    let marker = String(decoding: event.payload, as: UTF8.self)
                    Task { @MainActor in progress.received.insert(marker) }
                }
            }
            defer { withExtendedLifetime(observations) {} }
            let pids = try sessions.map { try #require($0.process?.shellPid) }
            let logs = FileManager.default.temporaryDirectory.appendingPathComponent("prestel-stress-\(UUID().uuidString)")
            for (index, session) in sessions.enumerated() {
                let directory = logs.appendingPathComponent(String(index))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                session.process?.setHostLogging(directory: directory.path)
            }
            defer {
                sessions.forEach { $0.process?.setHostLogging(directory: nil) }
                try? FileManager.default.removeItem(at: logs)
            }
            var heartbeatDelays: [Double] = []
            let heartbeat = Task { @MainActor in
                var previous = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(20)) }
                    catch { return }
                    let now = ContinuousClock.now
                    let elapsed = previous.duration(to: now).components
                    heartbeatDelays.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                    previous = now
                }
            }
            defer { heartbeat.cancel() }

            for (index, session) in sessions.enumerated() {
                session.run("printf '\\033]777;READY_%s\\007' \(index)")
            }
            let startupDeadline = ContinuousClock.now + .seconds(30)
            while !sessions.indices.allSatisfy({ progress.received.contains("READY_\($0)") }),
                  ContinuousClock.now < startupDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(sessions.indices.allSatisfy { progress.received.contains("READY_\($0)") },
                         "The stress-test shells did not finish starting")

            for round in 0..<24 {
                let previousRenders = sessions.reduce(0) { $0 + ($1.surface?.diagnostics.renders ?? 0) }
                for (index, session) in sessions.enumerated() {
                    session.run("/usr/bin/awk 'BEGIN { for (i=0; i<3000; i++) printf \"\\033[38;5;%dmrow %06d abcdefghijklmnopqrstuvwxyz 0123456789\\033[0m\\n\", i%16, i; printf \"RELIABILITY_%s_%s_DONE\\n\\033]777;RELIABILITY_%s_%s_DONE\\007\", \"\(round)\", \"\(index)\", \"\(round)\", \"\(index)\" }'")
                }
                model.select(sessions[round % sessions.count].id)
                model.unsplit()
                model.split(with: sessions[(round + 1) % sessions.count].id,
                            on: round.isMultiple(of: 2) ? .trailing : .bottom)
                controller.toggleSidebar(nil)
                controller.toggleCodeReview(nil)
                window.setContentSize(NSSize(width: round.isMultiple(of: 2) ? 760 : 1240,
                                             height: round.isMultiple(of: 3) ? 540 : 800))
                TerminalFontSize.set(round.isMultiple(of: 2) ? 12 : 16)
                sessions.forEach { $0.surface?.applyPreferences() }
                window.contentView?.layoutSubtreeIfNeeded()

                let deadline = ContinuousClock.now + .seconds(15)
                var completed = Set<Int>()
                while completed.count < sessions.count, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                    for (index, session) in sessions.enumerated() where !completed.contains(index) {
                        if progress.received.contains("RELIABILITY_\(round)_\(index)_DONE") {
                            completed.insert(index)
                        }
                    }
                }
                for (index, session) in sessions.enumerated() where !completed.contains(index) {
                    let output = buffer(session)
                    print("MISSING_OUTPUT round=\(round) session=\(index) running=\(session.process?.running ?? false) dimensions=\(String(describing: session.surface?.terminalDimensions)) frame=\(String(describing: session.surface?.frame)) bytes=\(session.surface?.diagnostics.bytesFed ?? 0)")
                    print("MISSING_OUTPUT tail=\(output.suffix(1500))")
                    Attachment.record(output, named: "missing-output-\(round)-\(index).txt")
                    let files = try FileManager.default.contentsOfDirectory(at: logs.appendingPathComponent(String(index)),
                        includingPropertiesForKeys: nil).sorted {
                            (Int($0.lastPathComponent.dropFirst(4)) ?? 0) < (Int($1.lastPathComponent.dropFirst(4)) ?? 0)
                        }
                    let raw = try files.suffix(16).reduce(into: Data()) { $0.append(try Data(contentsOf: $1)) }
                    let rawText = String(decoding: raw, as: UTF8.self)
                    print("RAW_OUTPUT markerReceived=\(rawText.contains("RELIABILITY_\(round)_\(index)_DONE")) tail=\(String(reflecting: rawText.suffix(1800)))")
                    Attachment.record(raw, named: "raw-output-\(round)-\(index).bin")
                }
                try #require(completed.count == sessions.count, "Missing terminal output in round \(round)")
                #expect(sessions.allSatisfy {
                    buffer($0).replacingOccurrences(of: "\n", with: "").contains("row 002998")
                })
                sessions.forEach { $0.surface?.display() }
                CATransaction.flush()
                try await eventually {
                    sessions.reduce(0) { $0 + ($1.surface?.diagnostics.renders ?? 0) } > previousRenders
                }
                #expect(sessions.map { $0.process?.shellPid } == pids.map(Optional.some))
                #expect(sessions.allSatisfy { $0.process?.running == true })

                let transient = model.newTab(directory: "/private/tmp")
                transient.start()
                let transientPID = try #require(transient.process?.shellPid)
                transient.run("printf 'TRANSIENT_%s_READY\\n' \(round)")
                try await eventually { buffer(transient).contains("TRANSIENT_\(round)_READY") }
                model.closeTab(transient.id)
                try await eventually { kill(transientPID, 0) == -1 && errno == ESRCH }
                model.select(sessions[round % sessions.count].id)
                window.contentView?.layoutSubtreeIfNeeded()
                try await eventually { model.selectedTab?.surface?.window === window }
            }

            let diagnostics = sessions.compactMap { $0.surface?.diagnostics }
            let bytes = diagnostics.reduce(0) { $0 + $1.bytesFed }
            let renders = diagnostics.reduce(0) { $0 + $1.renders }
            let worstDelay = heartbeatDelays.max() ?? 0
            print("RELIABILITY rounds=24 outputLines=216000 transientSessions=24 bytes=\(bytes) renders=\(renders) maxHeartbeatSeconds=\(worstDelay)")
            #expect(bytes > 10_000_000)
            #expect(renders > 0)
            #expect(worstDelay < 2, "Main actor stopped responding during output and layout changes")
            model.closeAll()
            try await eventually { pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        }
    }

    @MainActor private final class ReliabilityProgress {
        var received: Set<String> = []
    }

    private func buffer(_ session: TerminalSession) -> String {
        session.surface.map { String(decoding: $0.getBufferAsData(), as: UTF8.self) } ?? ""
    }

    private func withTerminalFontSize(_ size: CGFloat?, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: TerminalFontSize.defaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: TerminalFontSize.defaultsKey)
            } else {
                defaults.removeObject(forKey: TerminalFontSize.defaultsKey)
            }
        }
        if let size {
            defaults.set(Double(size), forKey: TerminalFontSize.defaultsKey)
        } else {
            defaults.removeObject(forKey: TerminalFontSize.defaultsKey)
        }
        try body()
    }

    private func withTerminalFontSize(_ size: CGFloat?, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: TerminalFontSize.defaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: TerminalFontSize.defaultsKey)
            } else {
                defaults.removeObject(forKey: TerminalFontSize.defaultsKey)
            }
        }
        if let size {
            defaults.set(Double(size), forKey: TerminalFontSize.defaultsKey)
        } else {
            defaults.removeObject(forKey: TerminalFontSize.defaultsKey)
        }
        try await body()
    }
    @Test func searchFieldTabDoesNotInsertGlyph() {
        let textView = SearchEditorTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        textView.string = "ab"
        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(!textView.string.contains("\t"), "Tab inserted a glyph into the one-line field")
        #expect(textView.string == "ab")
    }

    @Test func searchFieldAcceptsTabFocusBeforeEditing() {
        // A permanently-editable field must accept first responder while
        // still idle, or Tab can never enter it (catch-22 with an
        // editing-gated acceptsFirstResponder).
        let textView = SearchEditorTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        #expect(!textView.isEditingMode)
        #expect(textView.acceptsFirstResponder, "idle search editor refuses Tab focus")
    }

    @Test func closingEarlierTabPreservesBackAndForwardHistory() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        model.navigate(-1)
        #expect(model.selectedID == second)
        model.closeTab(first)
        #expect(!model.canGoBack)
        #expect(model.canGoForward)
        model.navigate(1)
        #expect(model.selectedID == third)
        model.navigate(-1)
        #expect(model.selectedID == second)
    }

    @Test func tabReorderUsesStableIdentityAndFixesDownwardIndex() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let d = model.newTab().id
        model.select(c)
        // A B C D, move B between C and D → A C B D
        model.moveTab(b, to: 3)
        #expect(model.tabs.map(\.id) == [a, c, b, d])
        #expect(model.selectedID == c)
        model.moveTab(d, to: 0)
        #expect(model.tabs.map(\.id) == [d, a, c, b])
        #expect(model.selectedID == c)
        model.moveTab(d, to: 4)
        #expect(model.tabs.map(\.id) == [a, c, b, d])
        model.moveTab(b, to: 2)
        model.moveTab(b, to: 3)
        #expect(model.tabs.map(\.id) == [a, c, b, d])
    }

    @Test func shiftTabSelectionUsesAnInclusiveStableRange() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let d = model.newTab().id

        model.select(b)
        model.select(d, shift: true, command: false)
        #expect(model.selectedTabIDs == Set([b, c, d]))
        #expect(model.selectedID == d)

        // Shift keeps the original plain-click anchor, matching Lume.
        model.select(a, shift: true, command: false)
        #expect(model.selectedTabIDs == Set([a, b]))
        #expect(model.selectedID == a)

        model.select(c)
        #expect(model.selectedTabIDs == [c])
    }

    @Test func newFolderTakesEveryTabInTheSelection() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let d = model.newTab().id

        model.select(b)
        model.select(c, shift: true, command: false)
        let folder = model.makeFolder(containing: c)!
        #expect(Set(folder.tabIDs) == Set([b, c]))
        #expect(model.folderContaining(a) == nil)
        #expect(model.folderContaining(d) == nil)

        // A tab outside the selection only takes itself.
        let other = model.makeFolder(containing: d)!
        #expect(other.tabIDs == [d])
    }

    @Test func emptyingAFolderLeavesItInPlace() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let d = model.newTab().id
        model.select(b)
        model.select(c, shift: true, command: false)
        let folder = model.makeFolder(containing: c)!

        model.moveTabs([b, c], to: model.tabs.count, folderID: nil, assignsFolder: true)

        let order = model.sidebarSections.map { section -> UUID in
            switch section {
            case .loose(let item): return item.id
            case .folder(let group): return group.folder.id
            }
        }
        // a, then the (now empty) folder where it was, then d, then the tabs that left.
        #expect(order.first == a)
        #expect(order[1] == folder.id)
        #expect(order[2] == d)
        #expect(Array(order.suffix(2)) == [b, c])
    }

    @Test func shiftRangeSkipsTabsHiddenInCollapsedFolders() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let d = model.newTab().id
        let folder = model.makeFolder(containing: b)!
        model.add(c, to: folder.id)
        model.toggleFolder(folder.id)

        model.select(a)
        model.select(d, shift: true, command: false)
        #expect(model.selectedTabIDs == Set([a, d]))
    }

    @Test func shiftRangeSkipsSearchHiddenTabs() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        model.tab(id: a)?.setDisplayTitle("alpha one")
        model.tab(id: b)?.setDisplayTitle("beta")
        model.tab(id: c)?.setDisplayTitle("alpha two")

        model.searchText = "alpha"
        model.select(a)
        model.select(c, shift: true, command: false)
        #expect(model.selectedTabIDs == Set([a, c]))
    }

    @Test func commandDeselectingBackgroundTabKeepsActiveTab() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        model.select(a)
        model.select(b, shift: false, command: true)
        model.select(c, shift: false, command: true)
        #expect(model.selectedID == c)

        model.select(a, shift: false, command: true)
        #expect(model.selectedTabIDs == Set([b, c]))
        #expect(model.selectedID == c)
    }

    @Test func commandDeselectingActiveTabHandsOffToASelectedOne() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        model.select(a)
        model.select(b, shift: false, command: true)
        model.select(b, shift: false, command: true)
        #expect(model.selectedTabIDs == [a])
        #expect(model.selectedID == a)

        // The last selected tab stays selected.
        model.select(a, shift: false, command: true)
        #expect(model.selectedTabIDs == [a])
        #expect(model.selectedID == a)
    }

    @Test func selectedTabsReorderAsOneRigidBlock() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let d = model.newTab().id
        let e = model.newTab().id

        model.select(b)
        model.select(d, shift: true, command: false)
        let moving = model.orderedDraggedTabIDs(grabbed: c)
        #expect(moving == [b, c, d])
        #expect(!model.tabMoveWouldChange(moving, to: 1, folderID: nil))
        #expect(!model.tabMoveWouldChange(moving, to: 4, folderID: nil))

        model.moveTabs(moving, to: 5)
        #expect(model.tabs.map(\.id) == [a, e, b, c, d])
        #expect(model.selectedTabIDs == Set([b, c, d]))

        model.moveTabs(moving, to: 1)
        #expect(model.tabs.map(\.id) == [a, b, c, d, e])
    }

    @Test func draggingAnUnselectedTabCollapsesTheSelection() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        model.select(first)
        model.select(second, shift: true, command: false)
        #expect(model.selectedTabIDs == Set([first, second]))

        model.prepareSelectionForDrag(third)
        #expect(model.selectedTabIDs == [third])
        #expect(model.orderedDraggedTabIDs(grabbed: third) == [third])
    }

    @Test func batchTabTransferPreservesOrderSessionsAndSelection() {
        let source = TerminalModel()
        let destination = TerminalModel()
        let a = source.selectedID!
        let b = source.newTab()
        let c = source.newTab()
        let d = source.newTab().id
        let destinationFirst = destination.selectedID!
        let destinationLast = destination.newTab().id

        source.select(b.id)
        source.select(c.id, shift: true, command: false)
        let extracted = source.detachTabs(source.orderedDraggedTabIDs(grabbed: b.id))
        #expect(extracted.count == 2)
        #expect(extracted[0] === b)
        #expect(extracted[1] === c)
        #expect(source.tabs.map(\.id) == [a, d])

        destination.adopt(extracted, at: 1, selecting: c.id)
        #expect(destination.tabs.map(\.id) == [destinationFirst, b.id, c.id, destinationLast])
        #expect(destination.tabs[1] === b)
        #expect(destination.tabs[2] === c)
        #expect(destination.selectedID == c.id)
        #expect(destination.selectedTabIDs == Set([b.id, c.id]))
    }

    @Test func draggingOneSplitMemberCarriesTheWholePair() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        model.select(first)
        model.split(with: second, on: .trailing)

        #expect(model.orderedDraggedTabIDs(grabbed: second) == [first, second])
    }

    @Test func tabTransferMovesTheSameSessionWithoutClosingIt() {
        let source = TerminalModel()
        let destination = TerminalModel()
        let kept = source.selectedID!
        let moving = source.newTab()
        let destFirst = destination.selectedID!
        let destSecond = destination.newTab().id
        source.select(kept)
        let extracted = source.detachTab(moving.id)
        #expect(extracted === moving)
        #expect(moving.state != .closed)
        #expect(source.tabs.map(\.id) == [kept])
        #expect(source.selectedID == kept)
        destination.adopt(moving, at: 1, selecting: true)
        #expect(destination.tabs.map(\.id) == [destFirst, moving.id, destSecond])
        #expect(destination.tabs[1] === moving)
        #expect(destination.selectedID == moving.id)
        #expect(!source.tabs.contains { $0.id == moving.id })
    }

    @Test func detachingSelectedTabSelectsANeighbor() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        model.select(second)
        _ = model.detachTab(second)
        #expect(model.selectedID == third)
        #expect(model.tabs.map(\.id) == [first, third])
    }

    @Test func adoptingInitOwnsTheExistingTabAlone() {
        let source = TerminalModel()
        source.newTab()
        let tab = source.tabs[1]
        _ = source.detachTab(tab.id)
        let adopted = TerminalModel(adopting: tab)
        #expect(adopted.tabs.count == 1)
        #expect(adopted.tabs[0] === tab)
        #expect(adopted.selectedID == tab.id)
        #expect(tab.state != .closed)
    }

    @Test func filteredInsertionMapsOntoCanonicalOrder() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let visible = [a, c, d]
        let canonical = [a, b, c, d]
        #expect(TabInsertionGeometry.canonicalInsertionIndex(visibleInsertion: 0, visibleIDs: visible, canonicalIDs: canonical) == 0)
        #expect(TabInsertionGeometry.canonicalInsertionIndex(visibleInsertion: 1, visibleIDs: visible, canonicalIDs: canonical) == 2)
        #expect(TabInsertionGeometry.canonicalInsertionIndex(visibleInsertion: 2, visibleIDs: visible, canonicalIDs: canonical) == 3)
        #expect(TabInsertionGeometry.canonicalInsertionIndex(visibleInsertion: 3, visibleIDs: visible, canonicalIDs: canonical) == 4)
        let moving = c
        #expect(TabInsertionGeometry.isNoOpInsertion(movingID: moving, visibleInsertion: 1, visibleIDs: visible))
        #expect(TabInsertionGeometry.isNoOpInsertion(movingID: moving, visibleInsertion: 2, visibleIDs: visible))
        #expect(!TabInsertionGeometry.isNoOpInsertion(movingID: moving, visibleInsertion: 0, visibleIDs: visible))
        #expect(!TabInsertionGeometry.isNoOpInsertion(movingID: moving, visibleInsertion: 3, visibleIDs: visible))
    }

    @Test func codeReviewToggleStaysOnTheTopRightSplitPane() {
        let size = CGSize(width: 800, height: 600)
        for axis in [SplitAxis.horizontal, SplitAxis.vertical] {
            let layout = SplitCardLayout.cards(in: size, axis: axis, fraction: 0.35, gap: 8)
            let frames = [layout.primary, layout.secondary]
            let primary = SplitChromePlacement.showsReviewToggle(frame: layout.primary, among: frames)
            let secondary = SplitChromePlacement.showsReviewToggle(frame: layout.secondary, among: frames)
            switch axis {
            case .horizontal:
                #expect(!primary)
                #expect(secondary)
            case .vertical:
                #expect(primary)
                #expect(!secondary)
            }
        }
    }

    @Test func tabCloseButtonSitsInsideTheRow() {
        let row = CGRect(x: 0, y: 0, width: 160, height: ShellMetrics.sidebarRowHeight)
        let button = TabCloseMetrics.frame(in: row)
        #expect(row.contains(button))
        #expect(button.width == TabCloseMetrics.side)
        #expect(button.height == TabCloseMetrics.side)
        #expect(button.maxX == row.maxX - TabCloseMetrics.trailingInset)
        #expect(button.midY == row.midY)
        let narrow = CGRect(x: 0, y: 0, width: 64, height: ShellMetrics.sidebarRowHeight)
        #expect(narrow.contains(TabCloseMetrics.frame(in: narrow)))
    }

    @Test func closeButtonStaysHiddenUntilTheRowIsHovered() async throws {
        let model = TerminalModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 172, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: SidebarView(model: model, width: 172, closeTab: { _ in }).ignoresSafeArea())
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 172, height: 400)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        defer {
            host.removeFromSuperview()
            TabDragCoordinator.shared.setHoveredRow(nil)
        }

        func hitRows(in view: NSView) -> [TabRowHitNSView] {
            if let row = view as? TabRowHitNSView { return [row] }
            return view.subviews.flatMap { hitRows(in: $0) }
        }
        let row = try #require(hitRows(in: host).first { $0.tabID != nil })
        #expect(!row.isShowingCloseButton)
        TabDragCoordinator.shared.setHoveredRow(row.tabID)
        #expect(row.isShowingCloseButton)
        TabDragCoordinator.shared.setHoveredRow(nil)
        #expect(!row.isShowingCloseButton)
    }

    @Test func closeButtonClickClosesAndDoesNotSelect() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hit = TabRowHitNSView(frame: NSRect(x: 0, y: 0, width: 160, height: ShellMetrics.sidebarRowHeight))
        hit.tabID = UUID()
        window.contentView?.addSubview(hit)
        defer {
            hit.removeFromSuperview()
            TabDragCoordinator.shared.setHoveredRow(nil)
        }
        var closed = 0
        var selected = 0
        hit.onClose = { closed += 1 }
        hit.onSelect = { selected += 1 }

        func click(_ local: CGPoint) {
            let point = hit.convert(local, to: nil)
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            )!
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            )!
            hit.mouseDown(with: down)
            hit.mouseUp(with: up)
        }

        let closeFrame = TabCloseMetrics.frame(in: hit.bounds)
        click(CGPoint(x: closeFrame.midX, y: closeFrame.midY))
        #expect(closed == 1)
        #expect(selected == 0)

        click(CGPoint(x: 50, y: hit.bounds.midY))
        #expect(closed == 1)
        #expect(selected == 1)

        let downPoint = hit.convert(CGPoint(x: closeFrame.midX, y: closeFrame.midY), to: nil)
        let upPoint = hit.convert(CGPoint(x: 50, y: hit.bounds.midY), to: nil)
        hit.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown, location: downPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        )!)
        hit.mouseUp(with: NSEvent.mouseEvent(
            with: .leftMouseUp, location: upPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        )!)
        #expect(closed == 1)
        #expect(selected == 1)
    }

    @Test func splitPairsASecondTabAndCapsAtTwoPanes() {
        let model = TerminalModel()
        let current = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        model.select(current)
        model.split(with: current, on: .trailing)
        #expect(model.visibleSplit == nil, "splitting a tab with itself is a no-op")

        model.split(with: second, on: .trailing)
        #expect(model.visibleSplit?.leadingID == current)
        #expect(model.visibleSplit?.trailingID == second)
        #expect(model.visibleSplit?.axis == .horizontal)
        #expect(model.splits.count == 1)
        #expect(model.selectedID == second)

        model.split(with: second, on: .leading)
        #expect(model.visibleSplit?.leadingID == second)
        #expect(model.visibleSplit?.trailingID == current)

        model.split(with: third, on: .trailing)
        #expect(model.visibleSplit?.leadingID == second)
        #expect(model.visibleSplit?.trailingID == third)
        #expect(model.tabs.map(\.id) == [current, second, third])
        #expect(model.selectedID == third)
    }

    @Test func selectingATabOutsideTheSplitKeepsThePair() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        model.select(first)
        model.split(with: second, on: .trailing)
        model.select(second)
        #expect(model.splits.count == 1)
        #expect(model.visibleSplit != nil)
        model.select(third)
        #expect(model.splits.count == 1)
        #expect(model.split(containing: first)?.leadingID == first)
        #expect(model.split(containing: first)?.trailingID == second)
        #expect(model.visibleSplit == nil)
        #expect(model.selectedID == third)
        model.select(first)
        #expect(model.visibleSplit?.leadingID == first)
        #expect(model.selectedID == first)
    }

    @Test func multipleSplitPairsCanCoexist() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        let fourth = model.newTab().id
        model.select(first)
        model.split(with: second, on: .trailing)
        model.select(third)
        model.split(with: fourth, on: .trailing)
        #expect(model.splits.count == 2)
        #expect(model.sidebarItems.count == 2)
        #expect(model.sidebarItems.allSatisfy { $0.isPair })
        model.select(first)
        #expect(model.visibleSplit?.leadingID == first)
        model.select(third)
        #expect(model.visibleSplit?.leadingID == third)
    }

    @Test func movingASplitPairKeepsBothTabsAdjacent() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        model.select(first)
        model.split(with: second, on: .trailing)
        model.moveTab(first, to: 3)
        #expect(model.tabs.map(\.id) == [third, first, second])
        #expect(model.split(containing: first)?.trailingID == second)
    }

    @Test func closingASplitPaneKeepsThePartnerSelected() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        model.select(first)
        model.split(with: second, on: .trailing)
        model.closeTab(second)
        #expect(model.splits.isEmpty)
        #expect(model.selectedID == first)
        #expect(model.tabs.map(\.id) == [first])
    }

    @Test func detachingASplitPaneCollapsesAndSelectsThePartner() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab()
        model.select(first)
        model.split(with: second.id, on: .leading)
        #expect(model.visibleSplit?.leadingID == second.id)
        let extracted = model.detachTab(second.id)
        #expect(extracted === second)
        #expect(model.splits.isEmpty)
        #expect(model.selectedID == first)
        #expect(second.state != .closed)
    }

    @Test func splitStateRoundTripsThroughWindowDescriptor() throws {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        model.select(first)
        model.split(with: second, on: .trailing)
        model.resizeSplit(to: 0.35, along: 640)
        let encoded = try JSONEncoder().encode(model.descriptor)
        let restored = TerminalModel(restoration: try JSONDecoder().decode(WindowDescriptor.self, from: encoded))
        #expect(restored.splits.count == 1)
        #expect(restored.splits[0].leadingID == first)
        #expect(restored.splits[0].trailingID == second)
        #expect(restored.splits[0].fraction == TabSplitGeometry.clampFraction(0.35, along: 640))
        #expect(restored.splits[0].axis == .horizontal)
        #expect(restored.selectedID == second)
    }

    @Test func verticalSplitStateRoundTripsThroughWindowDescriptor() throws {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        model.select(first)
        model.split(with: second, on: .bottom)
        #expect(model.visibleSplit?.axis == .vertical)
        #expect(model.visibleSplit?.leadingID == first)
        #expect(model.visibleSplit?.trailingID == second)
        let encoded = try JSONEncoder().encode(model.descriptor)
        let restored = TerminalModel(restoration: try JSONDecoder().decode(WindowDescriptor.self, from: encoded))
        #expect(restored.splits.count == 1)
        #expect(restored.splits[0].axis == .vertical)
        #expect(restored.splits[0].leadingID == first)
        #expect(restored.splits[0].trailingID == second)
    }

    @Test func missingSplitKeysLeaveWindowsUnsplit() throws {
        let old = WindowDescriptor(
            id: UUID(),
            tabs: [TabDescriptor(directory: FileManager.default.homeDirectoryForCurrentUser.path)],
            selectedID: nil,
            sidebarVisible: true,
            sidebarWidth: 172
        )
        var payload = try JSONEncoder().encode(old)
        var json = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        json.removeValue(forKey: "splitLeadingID")
        json.removeValue(forKey: "splitTrailingID")
        json.removeValue(forKey: "splitFraction")
        json.removeValue(forKey: "splitAxis")
        payload = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(WindowDescriptor.self, from: payload)
        #expect(decoded.splits.isEmpty)
        #expect(decoded.splitLeadingID == nil)
        #expect(decoded.splitTrailingID == nil)
        #expect(decoded.splitFraction == 0.5)
        #expect(decoded.splitAxis == .horizontal)
    }

    @Test func splitDropSideUsesClosestEdgeAndTheCurrentAxis() {
        let detail = CGRect(x: 200, y: 100, width: 400, height: 300)
        #expect(TabSplitGeometry.side(at: CGPoint(x: 250, y: 250), in: detail, split: nil) == .leading)
        #expect(TabSplitGeometry.side(at: CGPoint(x: 550, y: 250), in: detail, split: nil) == .trailing)
        #expect(TabSplitGeometry.side(at: CGPoint(x: 400, y: 360), in: detail, split: nil) == .top)
        #expect(TabSplitGeometry.side(at: CGPoint(x: 400, y: 140), in: detail, split: nil) == .bottom)
        #expect(TabSplitGeometry.side(at: CGPoint(x: 10, y: 200), in: detail, split: nil) == nil)

        let horizontal = SplitState(leadingID: UUID(), trailingID: UUID(), fraction: 0.25, focusedID: UUID())
        #expect(TabSplitGeometry.side(at: CGPoint(x: 250, y: 200), in: detail, split: horizontal) == .leading)
        #expect(TabSplitGeometry.side(at: CGPoint(x: 450, y: 200), in: detail, split: horizontal) == .trailing)
        #expect(TabSplitGeometry.side(at: CGPoint(x: 350, y: 200), in: detail, split: horizontal) == .trailing)

        let vertical = SplitState(
            leadingID: UUID(),
            trailingID: UUID(),
            fraction: 0.5,
            focusedID: UUID(),
            axis: .vertical
        )
        #expect(TabSplitGeometry.side(at: CGPoint(x: 400, y: 300), in: detail, split: vertical) == .top)
        #expect(TabSplitGeometry.side(at: CGPoint(x: 400, y: 200), in: detail, split: vertical) == .bottom)

        #expect(TabSplitGeometry.isNoOp(movingID: UUID(), side: .leading, selectedID: nil, split: nil) == false)
        let tab = UUID()
        #expect(TabSplitGeometry.isNoOp(movingID: tab, side: .trailing, selectedID: tab, split: nil))
        let split = SplitState(leadingID: tab, trailingID: UUID(), fraction: 0.5, focusedID: tab)
        #expect(TabSplitGeometry.isNoOp(movingID: tab, side: .leading, selectedID: tab, split: split))
        #expect(!TabSplitGeometry.isNoOp(movingID: tab, side: .trailing, selectedID: tab, split: split))
        #expect(TabSplitGeometry.isNoOp(movingID: tab, side: .top, selectedID: tab, split: split))
        let outsider = UUID()
        #expect(TabSplitGeometry.isNoOp(movingID: outsider, side: .trailing, selectedID: outsider, split: split))
        #expect(!TabSplitGeometry.isNoOp(movingID: tab, side: .trailing, selectedID: outsider, split: split))
    }

    @Test func splitPairCollapsesToOneSidebarItem() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        model.select(first)
        #expect(model.sidebarItems.map(\.id) == [first, second, third])
        model.split(with: second, on: .trailing)
        #expect(model.sidebarItems.count == 2)
        #expect(model.sidebarItems[0].members == [first, second])
        #expect(model.sidebarItems[1].id == third)
        model.unsplit()
        #expect(model.sidebarItems.map(\.id) == [first, second, third])
    }

    @Test func splitCycleForwardFollowsVisualOrder() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        let fourth = model.newTab().id
        model.select(second)
        model.split(with: third, on: .trailing)

        model.select(first)
        model.cycle(1)
        #expect(model.selectedID == second)
        model.cycle(1)
        #expect(model.selectedID == third)
        model.cycle(1)
        #expect(model.selectedID == fourth)
        model.cycle(1)
        #expect(model.selectedID == first)

        model.select(third)
        model.cycle(1)
        #expect(model.selectedID == fourth)
        model.cycle(-1)
        #expect(model.selectedID == third)
    }

    @Test func splitCycleBackwardFollowsVisualOrder() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        let fourth = model.newTab().id
        model.select(second)
        model.split(with: third, on: .trailing)

        model.select(fourth)
        model.cycle(-1)
        #expect(model.selectedID == third)
        model.cycle(-1)
        #expect(model.selectedID == second)
        model.cycle(-1)
        #expect(model.selectedID == first)
        model.cycle(-1)
        #expect(model.selectedID == fourth)
    }

    @Test func splitCycleVisitsEveryTabWhenPairMembersAreNotAdjacentInTabsArray() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        model.select(second)
        model.split(with: third, on: .trailing)
        // Dragging a paired tab moves the whole pair, so moving the pair onto
        // its current slot is a no-op and keeps both tabs adjacent.
        model.moveTab(third, to: 1)
        #expect(model.tabs.map(\.id) == [first, second, third])
        // Move a singleton between the pair members so the pair is truly
        // non-adjacent in the canonical array while staying one sidebar row.
        model.moveTab(first, to: 2)
        #expect(model.tabs.map(\.id) == [second, first, third])

        model.select(third)
        model.cycle(-1)
        #expect(model.selectedID == second)
        model.cycle(1)
        #expect(model.selectedID == third)
        model.cycle(1)
        #expect(model.selectedID == first)

        let visited = Set((0..<3).map { _ in
            let id = model.selectedID!
            model.cycle(1)
            return id
        })
        #expect(visited == Set([first, second, third]))
    }

    @Test func splitCycleAcrossMultiplePairsVisitsEveryTab() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        let fourth = model.newTab().id
        let fifth = model.newTab().id
        model.select(first)
        model.split(with: second, on: .trailing)
        model.select(third)
        model.split(with: fourth, on: .trailing)

        let expectedOrder = [first, second, third, fourth, fifth]
        model.select(first)
        for next in expectedOrder.dropFirst() {
            model.cycle(1)
            #expect(model.selectedID == next)
        }
        model.cycle(1)
        #expect(model.selectedID == first)

        model.select(fifth)
        for next in expectedOrder.reversed().dropFirst() {
            model.cycle(-1)
            #expect(model.selectedID == next)
        }
        model.cycle(-1)
        #expect(model.selectedID == fifth)
    }

    @Test func insertionIndexUsesRowMidpointsNotHitRow() {
        let rows = [
            CGRect(x: 0, y: 200, width: 160, height: 28),
            CGRect(x: 0, y: 171, width: 160, height: 28),
            CGRect(x: 0, y: 142, width: 160, height: 28)
        ]
        #expect(TabInsertionGeometry.insertionIndex(at: 230, rows: rows) == 0)
        #expect(TabInsertionGeometry.insertionIndex(at: 215, rows: rows) == 0)
        #expect(TabInsertionGeometry.insertionIndex(at: 200, rows: rows) == 1)
        #expect(TabInsertionGeometry.insertionIndex(at: 156, rows: rows) == 2)
        #expect(TabInsertionGeometry.insertionIndex(at: 100, rows: rows) == 3)
        #expect(TabInsertionGeometry.insertionIndex(at: 0, rows: []) == 0)
    }

    @Test func detachedWindowOriginStaysInsideTheVisibleFrame() {
        let visible = CGRect(x: 100, y: 80, width: 800, height: 500)
        let size = CGSize(width: 960, height: 650)
        let origin = TabInsertionGeometry.clampedOrigin(size: size, drop: CGPoint(x: 120, y: 90), visible: visible)
        #expect(origin.x == visible.minX)
        #expect(origin.y == visible.minY)
        let inset = CGRect(x: 0, y: 0, width: 1800, height: 1200)
        let placed = TabInsertionGeometry.clampedOrigin(
            size: CGSize(width: 960, height: 650),
            drop: CGPoint(x: 400, y: 700),
            visible: inset
        )
        #expect(placed.x >= inset.minX)
        #expect(placed.y >= inset.minY)
        #expect(placed.x + 960 <= inset.maxX)
        #expect(placed.y + 650 <= inset.maxY)
    }

    @Test func liveSessionSurvivesReorderAndWindowTransfer() async throws {
        let source = TerminalModel(directory: "/private/tmp")
        let destination = TerminalModel(directory: "/")
        let moving = source.selectedTab!
        source.newTab()
        moving.start()
        destination.tabs[0].start()
        defer { source.closeAll(); destination.closeAll() }
        let pid = try #require(moving.process?.shellPid)
        moving.process?.send(data: Array("printf 'MOVE_%s\\n' READY\r".utf8)[...])
        try await eventually { buffer(moving).contains("MOVE_READY") }
        source.moveTab(moving.id, to: 2)
        #expect(source.tabs[1] === moving)
        #expect(moving.process?.shellPid == pid)
        #expect(moving.process?.running == true)
        let extracted = try #require(source.detachTab(moving.id))
        destination.adopt(extracted, at: 0, selecting: true)
        #expect(destination.tabs[0] === moving)
        #expect(moving.process?.shellPid == pid)
        moving.process?.send(data: Array("printf 'STILL_%s\\n' HERE\r".utf8)[...])
        try await eventually { buffer(moving).contains("STILL_HERE") }
        #expect(moving.currentDirectory == "/private/tmp")
        let adopted = TerminalModel(adopting: try #require(destination.detachTab(moving.id)))
        defer { adopted.closeAll() }
        #expect(adopted.tabs[0] === moving)
        #expect(moving.process?.shellPid == pid)
        #expect(buffer(moving).contains("MOVE_READY"))
    }

    @Test func searchEditingPublishesSingleLineInputAndEscapeClearsFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let box = SearchTextBoxView(frame: NSRect(x: 0, y: 0, width: 180, height: 20))
        window.contentView?.addSubview(box)
        var query = ""
        let coordinator = SearchTextBox.Coordinator(text: Binding(get: { query }, set: { query = $0 }))
        box.textView.delegate = coordinator
        #expect(window.makeFirstResponder(box.textView))
        box.textView.insertText("日本\nhello\tworld", replacementRange: NSRange(location: 0, length: 0))
        #expect(box.stringValue == "日本 hello world")
        #expect(query == box.stringValue)
        box.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(query == "日本 hello world")
        box.textView.doCommand(by: #selector(NSStandardKeyBindingResponding.complete(_:)))
        #expect(query.isEmpty)
        #expect(box.stringValue.isEmpty)
        #expect(!box.textView.isEditingMode)
        #expect(window.firstResponder !== box.textView)
    }

    @Test func longSearchScrollsWithoutGrowingCapsuleAndRewindsOnBlur() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let box = SearchTextBoxView(frame: NSRect(x: 0, y: 0, width: 140, height: 20))
        window.contentView?.addSubview(box)
        box.layoutSubtreeIfNeeded()
        window.makeFirstResponder(box.textView)
        let longQuery = String(repeating: "long query 文 ", count: 30)
        box.textView.insertText(longQuery, replacementRange: NSRange(location: 0, length: 0))
        #expect(box.frame.width == 140)
        #expect(box.textView.frame.width > box.contentSize.width)
        #expect(box.textView.frame.height == box.contentSize.height)
        #expect(box.contentView.bounds.minX > 0)
        window.makeFirstResponder(nil)
        #expect(!box.textView.isEditingMode)
        #expect(box.contentView.bounds.minX == 0)
        #expect(box.textView.selectedRange().length == 0)
    }

    @Test func searchSelectsAllOnEntryAndDoesNotReselectAfterBlur() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let box = SearchTextBoxView(frame: NSRect(x: 0, y: 0, width: 180, height: 20))
        window.contentView?.addSubview(box)
        box.stringValue = "文🙂 search"
        window.makeFirstResponder(box.textView)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(box.textView.selectedRange() == NSRange(location: 0, length: (box.stringValue as NSString).length))
        window.makeFirstResponder(nil)
        window.makeFirstResponder(box.textView)
        window.makeFirstResponder(nil)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(box.textView.selectedRange().length == 0)
        #expect(!box.textView.isEditable)
    }

    @Test func terminalColorsResolveAgainstTheViewsAppearance() throws {
        let view = PrestelView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            view.appearance = NSAppearance(named: name)
            view.refreshColorsForCurrentAppearance()
            let color = try #require(view.nativeForegroundColor.usingColorSpace(.deviceRGB))
            let background = try #require(view.nativeBackgroundColor.usingColorSpace(.deviceRGB))
            #expect(name == .darkAqua ? color.redComponent > background.redComponent : color.redComponent < background.redComponent)
            #expect(view.backgroundOpacity == (NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0))
        }
    }

    @Test func sidebarKeepsRowsBelowSearchAtRest() async throws {
        let model = TerminalModel()
        for _ in 0..<30 { model.newTab() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 172, height: 650),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SidebarView(model: model, width: 172, closeTab: { _ in }).ignoresSafeArea())
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 172, height: 650)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let list = try #require(scrollViews(in: host).first { !($0 is SearchTextBoxView) })
        #expect(list.contentInsets.top >= 72)
        #expect(list.contentInsets.bottom >= 40)
    }

    @Test func searchCompositionAndUndoPublishOnlyCommittedText() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let box = SearchTextBoxView(frame: NSRect(x: 0, y: 0, width: 180, height: 20))
        window.contentView?.addSubview(box)
        var query = ""
        let coordinator = SearchTextBox.Coordinator(text: Binding(get: { query }, set: { query = $0 }))
        let editor = box.textView
        editor.delegate = coordinator
        window.makeFirstResponder(editor)
        let undo = try #require(editor.undoManager)
        // The test calls input APIs directly, so model separate input events explicitly.
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(query.isEmpty)
        editor.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        #expect(query == "日本", "Committed IME text must reach the binding")
        undo.endUndoGrouping()
        editor.breakUndoCoalescing()
        undo.beginUndoGrouping()
        editor.insertText(" test", replacementRange: NSRange(location: 2, length: 0))
        #expect(query == "日本 test")
        undo.endUndoGrouping()
        undo.undo()
        #expect(query == "日本", "Undo should remove only the later edit")
        window.makeFirstResponder(nil)
    }

    @Test func hidingSidebarReleasesSearchFocus() async throws {
        let model = TerminalModel()
        let controller = TerminalWindowController(model: model)
        let window = try #require(controller.window)
        defer { controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window)) }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(model.selectedTab?.surface?.window === window)
        let box = SearchTextBoxView(frame: NSRect(x: 0, y: 0, width: 180, height: 20))
        window.contentView?.addSubview(box)
        window.makeFirstResponder(box.textView)
        #expect(box.textView.isEditingMode)
        model.sidebarVisible = false
        #expect(window.firstResponder === model.selectedTab?.surface)
        #expect(!box.textView.isEditingMode)
    }

    @Test func crossWindowDragMoveKeepsSurfaceHosted() async throws {
        let app = try #require(AppDelegate.current)
        let coordinator = TabDragCoordinator.shared
        coordinator.resetForTests()
        let sourceController = app.createWindow()
        let destController = app.createWindow()
        let sourceWindow = try #require(sourceController.window)
        let destWindow = try #require(destController.window)
        defer {
            sourceWindow.orderOut(nil)
            destWindow.orderOut(nil)
            sourceController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: sourceWindow))
            destController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: destWindow))
            coordinator.resetForTests()
        }
        sourceController.model.newTab()
        try await Task.sleep(for: .milliseconds(600))
        sourceWindow.contentView?.layoutSubtreeIfNeeded()
        destWindow.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        let moving = try #require(sourceController.model.selectedTab)
        let windowCountBefore = app.controllers.count
        // Aim at the middle of the destination sidebar tab list.
        let destFrame = destWindow.frame
        let target = CGPoint(x: destFrame.minX + 86, y: destFrame.midY)

        coordinator.begin(payload: TabDragPayload(dragID: UUID(), tabID: moving.id, sourceWindowID: sourceController.model.id), at: target, session: nil)
        coordinator.updatePointer(target)
        coordinator.finish(at: target)
        try await Task.sleep(for: .milliseconds(600))
        destWindow.contentView?.layoutSubtreeIfNeeded()

        let inSource = sourceController.model.tabs.contains { $0.id == moving.id }
        let inDest = destController.model.tabs.contains { $0.id == moving.id }
        #expect(!inSource, "moving tab still in source")
        #expect(inDest, "moving tab never arrived in destination (windows: \(app.controllers.count) before \(windowCountBefore))")
        #expect(destController.model.selectedID == moving.id)
        func contains(_ root: NSView, _ target: NSView) -> Bool {
            if root === target { return true }
            return root.subviews.contains { contains($0, target) }
        }
        let surface = moving.surface
        var inDestHierarchy = false
        var inSourceHierarchy = false
        if let surface, let destRoot = destWindow.contentView {
            inDestHierarchy = contains(destRoot, surface)
        }
        if let surface, let sourceRoot = sourceWindow.contentView {
            inSourceHierarchy = contains(sourceRoot, surface)
        }
        var chain: [String] = []
        var cursor: NSView? = surface?.superview
        while let view = cursor, chain.count < 6 {
            chain.append("\(type(of: view)) frame=\(view.frame) window=\(view.window == nil ? "nil" : "set")")
            cursor = view.superview
        }
        #expect(inDestHierarchy, "surface not under dest contentView; inSourceHierarchy=\(inSourceHierarchy); superview chain: \(chain); surface frame: \(String(describing: surface?.frame)); dest selected: \(String(describing: destController.model.selectedTab?.id))")
        #expect(moving.surface?.window === destWindow)
    }

    @Test func adoptedLiveTabAttachesSurfaceInDestinationWindow() async throws {
        let sourceModel = TerminalModel()
        let destModel = TerminalModel()
        let sourceController = TerminalWindowController(model: sourceModel)
        let destController = TerminalWindowController(model: destModel)
        let sourceWindow = try #require(sourceController.window)
        let destWindow = try #require(destController.window)
        defer {
            sourceWindow.orderOut(nil)
            destWindow.orderOut(nil)
            sourceController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: sourceWindow))
            destController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: destWindow))
        }
        sourceWindow.orderFrontRegardless()
        destWindow.orderFrontRegardless()
        sourceWindow.contentView?.layoutSubtreeIfNeeded()
        destWindow.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        sourceWindow.contentView?.layoutSubtreeIfNeeded()
        destWindow.contentView?.layoutSubtreeIfNeeded()

        let moving = try #require(sourceModel.selectedTab)
        #expect(moving.state == .running)
        #expect(moving.surface?.window === sourceWindow)

        // Mirror TabDragCoordinator.commit cross-window branch.
        guard let tab = sourceModel.detachTab(moving.id) else {
            Issue.record("detach failed")
            return
        }
        destModel.adopt(tab, at: destModel.tabs.count, selecting: true)
        destController.refresh()
        sourceController.refresh()
        destWindow.makeKeyAndOrderFront(nil)

        try await Task.sleep(for: .milliseconds(600))
        destWindow.contentView?.layoutSubtreeIfNeeded()
        sourceWindow.contentView?.layoutSubtreeIfNeeded()

        #expect(destModel.selectedTab === moving)
        #expect(sourceModel.selectedTab?.id != moving.id)
        let surface = try #require(moving.surface)
        #expect(surface.window === destWindow)
        #expect(surface.frame.height > 10)
        #expect(surface.superview != nil)
    }

    @Test func switchingTabsHostsOnlyTheSelectedSurface() async throws {
        let model = TerminalModel()
        let controller = TerminalWindowController(model: model)
        let window = try #require(controller.window)
        defer {
            window.orderOut(nil)
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        }
        window.orderFrontRegardless()
        model.newTab()
        model.tabs.forEach { $0.start() }
        try await Task.sleep(for: .milliseconds(600))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        let first = model.tabs[0]
        let second = model.tabs[1]
        model.select(second.id)
        try await Task.sleep(for: .milliseconds(400))
        window.contentView?.layoutSubtreeIfNeeded()

        let selectedSurface = try #require(model.selectedTab?.surface)
        #expect(selectedSurface === second.surface)
        #expect(selectedSurface.window === window)
        // The previously selected surface must be evicted, never stacked
        // underneath: piled-up surfaces all render at once and switching
        // appears to do nothing.
        #expect(first.surface?.superview == nil)
        let hostedCount = selectedSurface.superview?.subviews.filter { $0 is PrestelView }.count ?? -1
        #expect(hostedCount == 1)

        model.select(first.id)
        try await Task.sleep(for: .milliseconds(400))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(first.surface?.window === window)
        #expect(second.surface?.superview == nil)
    }

    @Test func splitViewHostsBothSurfacesAtOnce() async throws {
        let model = TerminalModel()
        let controller = TerminalWindowController(model: model)
        let window = try #require(controller.window)
        defer {
            window.orderOut(nil)
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        }
        window.orderFrontRegardless()
        let first = model.tabs[0]
        let second = model.newTab()
        model.select(first.id)
        model.tabs.forEach { $0.start() }
        try await Task.sleep(for: .milliseconds(600))
        window.contentView?.layoutSubtreeIfNeeded()

        model.split(with: second.id, on: .trailing)
        controller.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually {
            first.surface?.window === window && second.surface?.window === window
                && first.surface?.superview != nil && second.surface?.superview != nil
                && first.surface?.superview !== second.surface?.superview
        }

        let leading = try #require(first.surface)
        let trailing = try #require(second.surface)
        #expect(model.visibleSplit?.leadingID == first.id)
        #expect(model.visibleSplit?.trailingID == second.id)

        model.select(first.id)
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually { leading.window === window && trailing.window === window }

        model.unsplit()
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually {
            model.selectedTab?.surface?.window === window && second.surface?.superview == nil
        }
    }

    @Test func optionArrowInterceptSendsReadlineWordJumpsInTheShell() {
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 123, flags: .option, applicationKeyboard: false) == [0x1b, 0x62])
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 124, flags: .option, applicationKeyboard: false) == [0x1b, 0x66])
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 123, flags: .control, applicationKeyboard: false) == [0x1b, 0x62])
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 124, flags: .command, applicationKeyboard: false) == [0x05])
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 49, flags: .shift, applicationKeyboard: false) == nil)
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 36, flags: .shift, applicationKeyboard: false) == nil)
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 36, flags: .option, applicationKeyboard: false) == nil)
    }

    @Test func optionArrowInterceptSendsOneModifiedCSISequenceInATui() {
        // OpenCode binds both alt+b and alt+left to word-back. Sending ESC-b
        // AND Alt+Left (the old monitor coalescing bug) jumped two words.
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 123, flags: .option, applicationKeyboard: true) == Array("\u{1b}[1;3D".utf8))
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 124, flags: .option, applicationKeyboard: true) == Array("\u{1b}[1;3C".utf8))
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 123, flags: .control, applicationKeyboard: true) == Array("\u{1b}[1;5D".utf8))
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 126, flags: .option, applicationKeyboard: true) == Array("\u{1b}[1;3A".utf8))
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 125, flags: .option, applicationKeyboard: true) == Array("\u{1b}[1;3B".utf8))
        // Cursor-key mode is not the Kitty keyboard protocol. CSI-u here is
        // ignored, so the newline chord has to wait for an explicit kitty flag.
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 36, flags: .shift, applicationKeyboard: true) == nil)
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 36, flags: .option, applicationKeyboard: true) == nil)
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 49, flags: .shift, applicationKeyboard: true) == nil)
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 49, flags: [], applicationKeyboard: true) == nil)
    }

    @Test func modifiedEnterInsertsANewline() {
        let altReturn: [UInt8] = [0x1b, 0x0d]
        // Full-screen app, no Kitty protocol: ESC CR is Alt+Return.
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 36, flags: .shift, applicationKeyboard: true, legacyNewline: true) == altReturn)
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 36, flags: .option, applicationKeyboard: false, legacyNewline: true) == altReturn)
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 76, flags: [.shift, .option], applicationKeyboard: false, legacyNewline: true) == altReturn)
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 36, flags: [.shift, .command], applicationKeyboard: false, legacyNewline: true) == nil)
        // Kitty protocol on the active screen.
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 36, flags: .shift, applicationKeyboard: true, kittyKeyboard: true, legacyNewline: true) == Array("\u{1b}[13;2u".utf8))
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 36, flags: .option, applicationKeyboard: true, kittyKeyboard: true) == Array("\u{1b}[13;3u".utf8))
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 76, flags: [.shift, .option], applicationKeyboard: false, kittyKeyboard: true) == Array("\u{1b}[13;4u".utf8))
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 36, flags: .control, applicationKeyboard: true, kittyKeyboard: true) == Array("\u{1b}[13;5u".utf8))
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 49, flags: .shift, applicationKeyboard: true, kittyKeyboard: true) == Array("\u{1b}[32;2u".utf8))
        #expect(TerminalKeyIntercept.bytesToSend(keyCode: 49, flags: [], applicationKeyboard: true, kittyKeyboard: true) == nil)
    }

    @Test func applicationCursorAndKittyProtocolEnableTuiKeyMode() {
        let view = PrestelView(frame: NSRect(x: 0, y: 0, width: 640, height: 420), options: TerminalOptions(scrollback: 100))
        #expect(!view.usesApplicationKeyboard)
        #expect(!view.usesKittyKeyboard)
        #expect(!view.needsLegacyNewline)
        view.feed(byteArray: Array("\u{1b}[?1h".utf8)[...])
        #expect(view.usesApplicationKeyboard)
        #expect(!view.usesKittyKeyboard)
        #expect(view.needsLegacyNewline)
        view.feed(byteArray: Array("\u{1b}[?1l".utf8)[...])
        #expect(!view.usesApplicationKeyboard)
        #expect(!view.needsLegacyNewline)
        view.feed(byteArray: Array("\u{1b}[>1u".utf8)[...])
        #expect(view.usesApplicationKeyboard)
        #expect(view.usesKittyKeyboard)
        view.feed(byteArray: Array("\u{1b}[<u".utf8)[...])
        #expect(!view.usesKittyKeyboard)
    }

    @Test func newlineChordsFollowTheActiveScreen() {
        let view = PrestelView(frame: NSRect(x: 0, y: 0, width: 640, height: 420), options: TerminalOptions(scrollback: 100))
        view.feed(byteArray: Array("\u{1b}[>1u".utf8)[...])
        #expect(view.usesKittyKeyboard)
        // The other screen does not inherit the protocol.
        view.feed(byteArray: Array("\u{1b}[?1049h".utf8)[...])
        #expect(view.needsLegacyNewline)
        #expect(!view.usesKittyKeyboard)
        // Option+Left on this screen must stay a shell chord. Kitty flags on
        // the screen we left do not count.
        #expect(!view.usesApplicationKeyboard)
        view.feed(byteArray: Array("\u{1b}[>1u".utf8)[...])
        #expect(view.usesKittyKeyboard)
        #expect(view.usesApplicationKeyboard)
        view.feed(byteArray: Array("\u{1b}[?1049l".utf8)[...])
        #expect(view.usesKittyKeyboard)
        #expect(!view.needsLegacyNewline)
        view.feed(byteArray: Array("\u{1b}=".utf8)[...])
        #expect(view.needsLegacyNewline)
        view.feed(byteArray: Array("\u{1b}>".utf8)[...])
        #expect(!view.needsLegacyNewline)
    }

    @Test func renameChangesTheSidebarNameOnly() {
        let model = TerminalModel()
        let session = model.selectedTab!
        let directory = session.directory
        session.setDisplayTitle("Ship")
        #expect(session.displayTitle == "Ship")
        #expect(session.title == "Local")
        #expect(session.customTitle == "Ship")
        #expect(session.directory == directory)
        #expect(session.process == nil)
        #expect(session.state == .ready)
        model.searchText = "Ship"
        #expect(model.filteredTabs.map(\.id) == [session.id])
        model.searchText = "Local"
        #expect(model.filteredTabs.map(\.id) == [session.id])
        model.searchText = ""

        let surface = PrestelView(frame: NSRect(x: 0, y: 0, width: 80, height: 40), options: TerminalOptions(scrollback: 10))
        session.setTerminalTitle(source: surface, title: "zsh")
        #expect(session.title == "zsh")
        #expect(session.displayTitle == "Ship")
        #expect(session.directory == directory)

        session.setDisplayTitle("   ")
        #expect(session.customTitle == nil)
        #expect(session.displayTitle == "zsh")
    }

    @Test func renamedTabAndFolderSurviveRestoration() throws {
        let model = TerminalModel()
        let kept = model.selectedTab!
        kept.setDisplayTitle("Ship")
        let grouped = model.newTab()
        let folder = model.makeFolder(containing: grouped.id)!
        model.renameFolder(folder.id, to: "Work")
        model.toggleFolder(folder.id)
        let encoded = try JSONEncoder().encode(model.descriptor)
        let restored = TerminalModel(restoration: try JSONDecoder().decode(WindowDescriptor.self, from: encoded))
        let restoredKept = restored.tabs.first { $0.id == kept.id }
        #expect(restoredKept?.displayTitle == "Ship")
        #expect(restoredKept?.title == "Local")
        #expect(restored.folders.count == 1)
        #expect(restored.folders[0].name == "Work")
        #expect(restored.folders[0].collapsed)
        #expect(restored.folders[0].tabIDs == [grouped.id])
        model.renameFolder(folder.id, to: " \n ")
        #expect(model.folders[0].name == "Work")
    }

    @Test func folderOpensInPlaceAndRenameTargetsTheFolder() {
        let model = TerminalModel()
        let loose = model.selectedID!
        let grouped = model.newTab().id
        let after = model.newTab().id
        model.select(loose)
        let folder = model.makeFolder(containing: grouped)!
        #expect(model.selectedID == loose)
        #expect(model.sidebarVisualIDs == [loose, folder.id, grouped, after])
        model.toggleFolder(folder.id)
        #expect(model.selectedID == loose)
        #expect(model.folders[0].collapsed)
        #expect(model.sidebarVisualIDs == [loose, folder.id, after])
        model.renameFolder(folder.id, to: "Work")
        #expect(model.tab(id: grouped)?.displayTitle == "Local")
        #expect(model.folders[0].name == "Work")
        model.toggleFolder(folder.id)
        model.select(grouped)
        let child = model.newTab()
        #expect(model.folderContaining(child.id)?.id == folder.id)
    }

    @Test func emptyFolderKeepsItsPlace() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let folder = model.makeFolder(containing: second)!
        model.removeFromFolder(second)
        #expect(model.folders[0].tabIDs.isEmpty)
        #expect(model.sidebarSections.map(\.id) == [first, folder.id, second])
    }

    @Test func movingAFolderKeepsItsTabsTogetherAmongLooseTabs() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let d = model.newTab().id
        let folder = model.makeFolder(containing: b)!
        model.add(c, to: folder.id)

        model.moveFolder(folder.id, before: nil)
        #expect(model.tabs.map(\.id) == [a, d, b, c])
        #expect(model.sidebarSections.map(\.id) == [a, d, folder.id])
        #expect(model.folders[0].tabIDs == [b, c])

        model.moveFolder(folder.id, before: a)
        #expect(model.tabs.map(\.id) == [b, c, a, d])
        #expect(model.sidebarSections.map(\.id) == [folder.id, a, d])

        model.moveFolder(folder.id, before: d)
        #expect(model.tabs.map(\.id) == [a, b, c, d])
        #expect(model.sidebarSections.map(\.id) == [a, folder.id, d])

        // Collapsed folders move the same way.
        model.toggleFolder(folder.id)
        model.moveFolder(folder.id, before: nil)
        #expect(model.tabs.map(\.id) == [a, d, b, c])
        #expect(model.folders[0].collapsed)
        #expect(model.sidebarVisualIDs == [a, d, folder.id])
    }

    @Test func movingAFolderPastAnotherFolderDoesNotNestIt() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let d = model.newTab().id
        let first = model.makeFolder(containing: a)!
        let second = model.makeFolder(containing: c)!
        model.add(d, to: second.id)

        model.moveFolder(first.id, before: nil)
        #expect(model.sidebarSections.map(\.id) == [b, second.id, first.id])
        #expect(model.tabs.map(\.id) == [b, c, d, a])
        #expect(model.folderContaining(a)?.id == first.id)
        #expect(model.folders.map(\.id) == [second.id, first.id])

        model.moveFolder(first.id, before: second.id)
        #expect(model.sidebarSections.map(\.id) == [b, first.id, second.id])

        model.toggleFolder(second.id)
        model.moveFolder(second.id, before: b)
        #expect(model.sidebarSections.map(\.id) == [second.id, b, first.id])
        #expect(model.tabs.map(\.id) == [c, d, b, a])
        #expect(Set(model.folderContaining(c)?.tabIDs ?? []) == Set([c, d]))
    }

    @Test func movingAFolderGathersMembersScatteredAmongLooseTabs() {
        let model = TerminalModel()
        let a = model.selectedID!
        let x = model.newTab().id
        let b = model.newTab().id
        let y = model.newTab().id
        let folder = model.makeFolder(containing: a)!
        model.add(b, to: folder.id)
        // Sidebar shows the folder first, then the loose tabs.
        #expect(model.sidebarSections.map(\.id) == [folder.id, x, y])

        model.moveFolder(folder.id, before: y)
        #expect(model.sidebarSections.map(\.id) == [x, folder.id, y])
        #expect(model.tabs.map(\.id) == [x, a, b, y])
    }

    @Test func movingAFolderWithASplitPairKeepsThePairAdjacent() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let x = model.newTab().id
        let c = model.newTab().id
        let folder = model.makeFolder(containing: b)!
        model.add(c, to: folder.id)
        model.select(b)
        model.split(with: c, on: .trailing)
        #expect(model.splits.count == 1)

        model.moveFolder(folder.id, before: a)
        #expect(model.tabs.map(\.id) == [b, c, a, x])
        #expect(model.sidebarSections.map(\.id) == [folder.id, a, x])
        let indexes = [b, c].compactMap { id in model.tabs.firstIndex { $0.id == id } }
        #expect(abs(indexes[0] - indexes[1]) == 1)
        #expect(model.splits.count == 1)

        // A loose split pair also moves past the folder as one block.
        let loose = TerminalModel()
        let p = loose.selectedID!
        let q = loose.newTab().id
        let r = loose.newTab().id
        let group = loose.makeFolder(containing: r)!
        loose.select(p)
        loose.split(with: q, on: .trailing)
        loose.moveFolder(group.id, before: p)
        #expect(loose.tabs.map(\.id) == [r, p, q])
        #expect(loose.splits.count == 1)
    }

    @Test func movingAnEmptyFolderKeepsItsPlace() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let folder = model.makeFolder(containing: b)!
        model.removeFromFolder(b)
        #expect(model.sidebarSections.map(\.id) == [a, folder.id, b, c])

        model.moveFolder(folder.id, before: nil)
        #expect(model.sidebarSections.map(\.id) == [a, b, c, folder.id])
        model.moveFolder(folder.id, before: a)
        #expect(model.sidebarSections.map(\.id) == [folder.id, a, b, c])
        model.moveFolder(folder.id, before: c)
        #expect(model.sidebarSections.map(\.id) == [a, b, folder.id, c])
        #expect(model.tabs.map(\.id) == [a, b, c])
    }

    @Test func movingAFolderLeavesTheTabSelectionAlone() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let folder = model.makeFolder(containing: c)!
        model.select(a)
        model.select(b, shift: false, command: true)
        let selection = model.selectedTabIDs
        let selected = model.selectedID

        model.moveFolder(folder.id, before: a)
        #expect(model.selectedTabIDs == selection)
        #expect(model.selectedID == selected)
        #expect(model.tabs.map(\.id) == [c, a, b])
    }

    @Test func folderDropSnapsOutOfFolderInteriors() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let d = model.newTab().id
        let folder = model.makeFolder(containing: b)!
        model.add(c, to: folder.id)
        // Rows: a, folder, b, c, d
        #expect(model.sidebarVisualIDs == [a, folder.id, b, c, d])

        #expect(model.folderMoveTarget(visibleInsertion: 0) == FolderMoveTarget(visibleInsertion: 0, beforeID: a))
        #expect(model.folderMoveTarget(visibleInsertion: 1) == FolderMoveTarget(visibleInsertion: 1, beforeID: folder.id))
        // Under the header and between the children: closer end wins, never the interior.
        #expect(model.folderMoveTarget(visibleInsertion: 2) == FolderMoveTarget(visibleInsertion: 1, beforeID: folder.id))
        #expect(model.folderMoveTarget(visibleInsertion: 3) == FolderMoveTarget(visibleInsertion: 4, beforeID: d))
        #expect(model.folderMoveTarget(visibleInsertion: 4) == FolderMoveTarget(visibleInsertion: 4, beforeID: d))
        #expect(model.folderMoveTarget(visibleInsertion: 5) == FolderMoveTarget(visibleInsertion: 5, beforeID: nil))
        #expect(model.folderMoveTarget(visibleInsertion: 99) == FolderMoveTarget(visibleInsertion: 5, beforeID: nil))

        // Collapsed folders have no interior.
        model.toggleFolder(folder.id)
        #expect(model.folderMoveTarget(visibleInsertion: 2) == FolderMoveTarget(visibleInsertion: 2, beforeID: d))
    }

    @Test func folderMoveIntoItsOwnSlotIsANoOp() {
        let model = TerminalModel()
        let a = model.selectedID!
        let b = model.newTab().id
        let c = model.newTab().id
        let folder = model.makeFolder(containing: b)!

        #expect(!model.folderMoveWouldChange(folder.id, before: folder.id))
        #expect(!model.folderMoveWouldChange(folder.id, before: c))
        #expect(model.folderMoveWouldChange(folder.id, before: a))
        #expect(model.folderMoveWouldChange(folder.id, before: nil))
        let before = model.tabs.map(\.id)
        model.moveFolder(folder.id, before: c)
        #expect(model.tabs.map(\.id) == before)
    }

    @Test func droppingOnAFolderHeaderStaysOutsideTheFolder() {
        let model = TerminalModel()
        let first = model.selectedID!
        let second = model.newTab().id
        let third = model.newTab().id
        let folder = model.makeFolder(containing: second)!
        model.toggleFolder(folder.id)
        let collapsed = model.sidebarVisualIDs
        #expect(collapsed == [first, folder.id, third])
        let beforeFolder = model.dropTarget(visibleInsertion: 1, visibleIDs: collapsed)
        #expect(beforeFolder.index == 1)
        #expect(beforeFolder.folderID == nil)
        let afterFolder = model.dropTarget(visibleInsertion: 2, visibleIDs: collapsed)
        #expect(afterFolder.index == 2)
        #expect(afterFolder.folderID == nil)
        model.toggleFolder(folder.id)
        let expanded = model.sidebarVisualIDs
        let inside = model.dropTarget(visibleInsertion: 2, visibleIDs: expanded)
        #expect(inside.index == 1)
        #expect(inside.folderID == folder.id)
    }

    @Test func folderEdgeMatchesFirefoxVerticalTabOverlap() {
        let model = TerminalModel()
        let above = model.selectedID!
        let inside = model.newTab().id
        let below = model.newTab().id
        let folder = model.makeFolder(containing: inside)!
        let visible = model.sidebarVisualIDs
        let tabIDs = model.tabs.map(\.id)
        #expect(visible == [above, folder.id, inside, below])
        let frames = folderStripFrames(count: visible.count)
        let rows = zip(visible, frames).map { FolderDropRow(id: $0.0, frame: $0.1) }
        let insideFrame = frames[2]
        let belowFrame = frames[3]

        // Dragging down past the last folder tab's midpoint lands below the folder.
        let downY = insideFrame.midY - 1
        let downIndex = TabInsertionGeometry.insertionIndex(at: downY, rows: frames)
        let down = model.dropTarget(
            visibleInsertion: downIndex,
            visibleIDs: visible,
            probe: FolderDropProbe(pointerY: downY, rows: rows, draggingDown: true)
        )
        #expect(down.folderID == nil)
        #expect(down.index == tabIDs.firstIndex(of: below))
        #expect(!SidebarOutline.isStationaryDrop(
            movingVisualID: inside,
            movingTabID: inside,
            visibleInsertion: downIndex,
            visibleIDs: visible,
            tabIDs: tabIDs,
            folders: model.folders,
            probe: FolderDropProbe(pointerY: downY, rows: rows, draggingDown: true)
        ))
        model.moveTab(above, to: down.index, folderID: down.folderID, assignsFolder: true)
        #expect(model.folderContaining(above) == nil)
        #expect(model.folderContaining(inside)?.id == folder.id)
        #expect(model.sidebarVisualIDs == [folder.id, inside, above, below])

        let rejoining = TerminalModel()
        let loose = rejoining.selectedID!
        let member = rejoining.newTab().id
        let parked = rejoining.newTab().id
        let targetFolder = rejoining.makeFolder(containing: member)!
        let parkedVisible = rejoining.sidebarVisualIDs
        let parkedFrames = folderStripFrames(count: parkedVisible.count)
        let parkedRows = zip(parkedVisible, parkedFrames).map { FolderDropRow(id: $0.0, frame: $0.1) }
        let parkedBelow = parkedFrames[3]
        let reach = parkedBelow.height * FolderDrop.joinReachFraction
        let upY = parkedBelow.maxY - reach + 1
        let upIndex = TabInsertionGeometry.insertionIndex(at: upY, rows: parkedFrames)
        let up = rejoining.dropTarget(
            visibleInsertion: upIndex,
            visibleIDs: parkedVisible,
            probe: FolderDropProbe(pointerY: upY, rows: parkedRows, draggingDown: false)
        )
        #expect(up.folderID == targetFolder.id)
        rejoining.moveTab(parked, to: up.index, folderID: up.folderID, assignsFolder: true)
        #expect(rejoining.folderContaining(parked)?.id == targetFolder.id)
        #expect(rejoining.folders[0].tabIDs == [member, parked])
        #expect(rejoining.folderContaining(loose) == nil)

        // Stopping short of that overlap, still on the tab below the folder, stays outside.
        let shortY = belowFrame.midY + 1
        let shortIndex = TabInsertionGeometry.insertionIndex(at: shortY, rows: frames)
        let shortProbe = FolderDropProbe(pointerY: shortY, rows: rows, draggingDown: false)
        let short = SidebarOutline.dropTarget(
            visibleInsertion: shortIndex,
            visibleIDs: visible,
            tabIDs: tabIDs,
            folders: [folder],
            probe: shortProbe
        )
        #expect(short.folderID == nil)
        #expect(SidebarOutline.isStationaryDrop(
            movingVisualID: below,
            movingTabID: below,
            visibleInsertion: shortIndex,
            visibleIDs: visible,
            tabIDs: tabIDs,
            folders: [folder],
            probe: shortProbe
        ))
    }

    @Test func folderEdgeDoesNotFlipOnAOnePixelReversal() {
        let model = TerminalModel()
        let member = model.newTab().id
        let below = model.newTab().id
        let folder = model.makeFolder(containing: member)!
        let visible = model.sidebarVisualIDs
        let frames = folderStripFrames(count: visible.count)
        let rows = zip(visible, frames).map { FolderDropRow(id: $0.0, frame: $0.1) }
        let upper = frames[2].midY
        let lower = frames[3].maxY - frames[3].height * FolderDrop.joinReachFraction
        let gap = (upper + lower) / 2
        var direction: FolderDragDirection?
        func sample(_ y: CGFloat) -> UUID? {
            direction = FolderDrop.direction(after: direction, pointerY: y)
            let index = TabInsertionGeometry.insertionIndex(at: y, rows: frames)
            return model.dropTarget(
                visibleInsertion: index,
                visibleIDs: visible,
                probe: FolderDropProbe(pointerY: y, rows: rows, draggingDown: direction?.draggingDown ?? true)
            ).folderID
        }

        #expect(sample(upper + 8) == folder.id)
        #expect(sample(gap) == nil)
        #expect(sample(gap + 1) == nil)
        let backUp = gap + FolderDrop.directionDeadzone + 1
        #expect(backUp < upper)
        #expect(sample(backUp) == folder.id)
        #expect(visible.contains(below))
    }

    @Test func droppingPastTheLastFolderStaysOutsideUntilTheOverlapReach() {
        let model = TerminalModel()
        let head = model.selectedID!
        let last = model.newTab().id
        let folder = model.makeFolder(containing: last)!
        let visible = model.sidebarVisualIDs
        #expect(visible == [head, folder.id, last])
        let frames = folderStripFrames(count: visible.count)
        let rows = zip(visible, frames).map { FolderDropRow(id: $0.0, frame: $0.1) }
        let lastFrame = frames[2]
        let reach = lastFrame.height * FolderDrop.joinReachFraction

        let outsideY = lastFrame.minY - reach - 1
        let outside = model.dropTarget(
            visibleInsertion: TabInsertionGeometry.insertionIndex(at: outsideY, rows: frames),
            visibleIDs: visible,
            probe: FolderDropProbe(pointerY: outsideY, rows: rows, draggingDown: true)
        )
        #expect(outside.folderID == nil)
        #expect(outside.index == model.tabs.count)

        let insideY = lastFrame.minY - reach + 1
        let rejoined = model.dropTarget(
            visibleInsertion: TabInsertionGeometry.insertionIndex(at: insideY, rows: frames),
            visibleIDs: visible,
            probe: FolderDropProbe(pointerY: insideY, rows: rows, draggingDown: false)
        )
        #expect(rejoined.folderID == folder.id)
        #expect(rejoined.index == model.tabs.firstIndex(where: { $0.id == last })! + 1)

        model.moveTab(head, to: outside.index, folderID: outside.folderID, assignsFolder: true)
        #expect(model.folderContaining(head) == nil)
        #expect(model.sidebarVisualIDs == [folder.id, last, head])
    }

    @Test func collapsedFolderJoinsOnlyAfterTheDwell() {
        let model = TerminalModel()
        let first = model.selectedID!
        let grouped = model.newTab().id
        let folder = model.makeFolder(containing: grouped)!
        model.toggleFolder(folder.id)
        let visible = model.sidebarVisualIDs
        #expect(visible == [first, folder.id])
        let frames = folderStripFrames(count: visible.count)
        let rows = zip(visible, frames).map { FolderDropRow(id: $0.0, frame: $0.1) }
        let belowY = frames[1].minY - 4
        let insertion = TabInsertionGeometry.insertionIndex(at: belowY, rows: frames)
        let quick = model.dropTarget(
            visibleInsertion: insertion,
            visibleIDs: visible,
            probe: FolderDropProbe(pointerY: belowY, rows: rows)
        )
        #expect(quick.folderID == nil)
        #expect(quick.index == model.tabs.count)
        #expect(SidebarOutline.collapsedDwellFolder(pointerY: frames[1].midY, rows: rows, folders: model.folders) == folder.id)
        let held = model.dropTarget(
            visibleInsertion: insertion,
            visibleIDs: visible,
            probe: FolderDropProbe(pointerY: belowY, rows: rows, collapsedJoinID: folder.id)
        )
        #expect(held.folderID == folder.id)
        model.moveTab(first, to: held.index, folderID: held.folderID, assignsFolder: true)
        #expect(model.folderContaining(first)?.id == folder.id)
        #expect(model.folders[0].tabIDs == [grouped, first])
    }

    private func folderStripFrames(count: Int, height: CGFloat = 28, gap: CGFloat = 1) -> [CGRect] {
        (0..<count).map { index in
            let y = CGFloat(count - 1 - index) * (height + gap)
            return CGRect(x: 0, y: y, width: 180, height: height)
        }
    }

    @Test func folderMenuRenamesTheFolderRow() {
        let hit = TabRowHitNSView(frame: .zero)
        hit.isFolder = true
        hit.onRename = {}
        hit.onDeleteFolder = {}
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        let titles = hit.menu(for: event)?.items.map(\.title) ?? []
        #expect(titles == ["Rename Tab", "Delete Folder"])
    }

    private func eventually(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
        #expect(predicate(), sourceLocation: sourceLocation)
    }
}
