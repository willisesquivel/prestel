import XCTest

/// Launches the built Prestel.app and drives its menus, windows, tabs, and PTY.
/// These are XCUITests: `XCUIApplication().launch()` starts the real application
/// process. They do not inject the unit-test host, and they do not set
/// `XCTestConfigurationFilePath` on the app (that flag makes Prestel skip
/// creating a window).
final class PrestelLiveUITests: XCTestCase {
    private var app = XCUIApplication()

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        // Fresh windows. Do not pass XCTestConfigurationFilePath: Prestel treats
        // that variable as "unit-test host" and refuses to open a terminal.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 25), "Prestel.app did not reach the foreground")
        let window = prestelWindows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "Prestel.app launched but no window appeared")
        focusTerminal(in: window)
        // Login shells on the runner need a moment before the first line is delivered intact.
        Thread.sleep(forTimeInterval: 2.0)
    }

    override func tearDownWithError() throws {
        if app.state == .runningForeground {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "prestel-after-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
            dismissBlockingDialogs()
            app.terminate()
        }
        try super.tearDownWithError()
    }

    func testLaunchOpensATerminalWindow() {
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertGreaterThanOrEqual(prestelWindows.count, 1)
        let title = prestelWindows.firstMatch.title
        XCTAssertTrue(title.contains("Prestel"), "Expected a Prestel window title, got \(title)")
    }

    func testNewWindowLeavesTheFirstWindowOpen() {
        let first = retitleFrontWindow("QAWIN1")
        clickMenu("File", "New Window")
        let windows = prestelWindows
        let appeared = expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: windows)
        wait(for: [appeared], timeout: 15)
        focusWindow(notTitled: first)
        let second = retitleFrontWindow("QAWIN2")
        XCTAssertTrue(window(titled: first).waitForExistence(timeout: 5), "First window disappeared after New Window")
        XCTAssertTrue(window(titled: second).waitForExistence(timeout: 5))
        XCTAssertNotEqual(first, second)
    }

    func testTabsOpenSwitchAndCloseThroughTheRealShell() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("prestel-qa-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: marker) }

        let first = retitleFrontWindow("QAONE")
        typeLine("printf PRESTEL_QA_OK > \(shellQuoted(marker.path))")
        try waitForMarker(marker, containing: "PRESTEL_QA_OK")

        XCTAssertFalse(menuItem("View", "Next Tab").isEnabled, "Next Tab should be disabled with a single tab")
        dismissMenus()

        clickMenu("File", "New Tab")
        let second = retitleFrontWindow("QATWO")
        XCTAssertNotEqual(first, second)

        clickMenu("View", "Previous Tab")
        XCTAssertTrue(window(titled: first).waitForExistence(timeout: 10), "Previous Tab did not return to \(first)")

        clickMenu("View", "Next Tab")
        XCTAssertTrue(window(titled: second).waitForExistence(timeout: 10), "Next Tab did not select \(second)")

        clickMenu("File", "Close Tab")
        XCTAssertTrue(window(titled: first).waitForExistence(timeout: 10), "Close Tab removed the window instead of the extra tab")
        XCTAssertFalse(window(titled: second).exists)
        XCTAssertFalse(menuItem("View", "Next Tab").isEnabled)
        dismissMenus()
    }

    func testShellReportsAFailedCommand() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("prestel-qa-fail-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: marker) }

        // `ls` fails, the login shell keeps going, and the exit status is recorded.
        // This is a live PTY: the file only appears if the launched app delivered the line.
        typeLine("ls /tmp/prestel-qa-no-such-dir > \(shellQuoted(marker.path)) 2>&1")
        try waitForMarker(marker, containing: "No such file")
    }

    func testCloseWindowWithARunningJobAsksAndCancelKeepsIt() {
        let title = retitleFrontWindow("QAJOB")
        typeLine("sleep 45")
        // Give the child time to become the foreground process group.
        Thread.sleep(forTimeInterval: 1.0)
        clickMenu("File", "Close Window")

        let alert = blockingDialog(titled: "Close Window?")
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "Closing a window with a live job did not ask for confirmation")
        let cancel = alert.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.click()

        XCTAssertTrue(window(titled: title).waitForExistence(timeout: 5), "Cancel closed the window")
        XCTAssertEqual(app.state, .runningForeground)
        // Stop the sleeper so tearDown can quit without another confirmation.
        app.typeKey("c", modifierFlags: .control)
    }

    func testOpenFolderCancelDoesNotCloseTheTerminal() {
        let title = retitleFrontWindow("QAOPEN")
        clickMenu("File", "Open Folder…")
        let cancel = cancelButton()
        XCTAssertTrue(cancel.waitForExistence(timeout: 8), "Open Folder did not present a panel with Cancel")
        cancel.click()
        XCTAssertTrue(window(titled: title).waitForExistence(timeout: 5))
        XCTAssertEqual(prestelWindows.count, 1)
    }

    // MARK: - Driving helpers

    private var prestelWindows: XCUIElementQuery {
        app.windows.matching(NSPredicate(format: "title CONTAINS %@", "Prestel"))
    }

    private func window(titled fragment: String) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title CONTAINS %@", fragment)).firstMatch
    }

    private func focusTerminal(in window: XCUIElement) {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.62)).click()
    }

    /// New Window does not replace the old window. Click the one whose title is not `forbidden`.
    private func focusWindow(notTitled forbidden: String) {
        let other = app.windows.matching(
            NSPredicate(format: "title CONTAINS 'Prestel' AND NOT title CONTAINS %@", forbidden)
        ).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 8), "No second Prestel window besides \(forbidden)")
        focusTerminal(in: other)
    }

    private func cancelButton() -> XCUIElement {
        let candidates = [
            app.sheets.buttons["Cancel"],
            app.dialogs.buttons["Cancel"],
            app.windows.buttons["Cancel"],
        ]
        return candidates.first { $0.exists } ?? app.buttons["Cancel"]
    }

    /// Sets the shell title through the live PTY and returns the fragment the window should show.
    @discardableResult
    private func retitleFrontWindow(_ name: String) -> String {
        typeLine("printf '\\033]0;\(name)\\007'")
        let titled = window(titled: name)
        XCTAssertTrue(titled.waitForExistence(timeout: 15), "Shell did not update the window title to \(name). Front title is \(prestelWindows.firstMatch.title)")
        return name
    }

    private func typeLine(_ line: String) {
        focusTerminal(in: prestelWindows.firstMatch)
        app.typeText(line + "\n")
    }

    private func clickMenu(_ menu: String, _ item: String) {
        let menuItem = menuItem(menu, item)
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Missing menu item \(menu) > \(item)")
        XCTAssertTrue(menuItem.isEnabled, "\(menu) > \(item) is disabled")
        menuItem.click()
    }

    private func menuItem(_ menu: String, _ item: String) -> XCUIElement {
        let bar = app.menuBars.menuBarItems[menu]
        if !bar.menuItems[item].exists {
            bar.click()
        }
        return bar.menuItems[item]
    }

    private func dismissMenus() {
        app.typeKey(.escape, modifierFlags: [])
    }

    private func blockingDialog(titled title: String) -> XCUIElement {
        let sheet = app.sheets[title]
        if sheet.exists { return sheet }
        let dialog = app.dialogs[title]
        if dialog.exists { return dialog }
        return app.dialogs[title]
    }

    private func dismissBlockingDialogs() {
        for container in [app.sheets.firstMatch, app.dialogs.firstMatch] where container.exists {
            if container.buttons["Cancel"].exists {
                container.buttons["Cancel"].click()
            } else if container.buttons["Quit Prestel"].exists {
                container.buttons["Quit Prestel"].click()
            }
        }
    }

    private func waitForMarker(_ url: URL, containing needle: String) throws {
        let deadline = Date().addingTimeInterval(20)
        var last = ""
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                last = text
                if text.contains(needle) { return }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("PTY did not write \(needle) to \(url.path). Contents: \(last)")
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
