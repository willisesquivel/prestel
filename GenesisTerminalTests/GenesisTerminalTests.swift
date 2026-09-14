import AppKit
import Darwin
import SwiftTerm
import SwiftUI
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
        // Universal TUI glass contract: truecolor advertisement + identity so
        // every TUI (not just OpenCode `system`) can inherit the terminal bg.
        #expect(ShellConfiguration.environment.contains("COLORTERM=truecolor"))
        #expect(ShellConfiguration.environment.contains("TERM_PROGRAM=Genesis"))
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
        let view = GenesisTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
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
        let hostedCount = selectedSurface.superview?.subviews.filter { $0 is GenesisTerminalView }.count ?? -1
        #expect(hostedCount == 1)

        model.select(first.id)
        try await Task.sleep(for: .milliseconds(400))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(first.surface?.window === window)
        #expect(second.surface?.superview == nil)
    }

    private func eventually(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
        #expect(predicate(), sourceLocation: sourceLocation)
    }
}
