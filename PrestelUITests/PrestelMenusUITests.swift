import XCTest

/// Menu bar commands and the shortcuts wired in PrestelCommands. Each test launches Prestel.app.
final class PrestelMenusUITests: PrestelUITestCase {
    func testSingleTabDisablesTabCyclingAndReopen() {
        XCTAssertFalse(menuItem("View", "Next Tab").isEnabled)
        XCTAssertFalse(menuItem("View", "Previous Tab").isEnabled)
        XCTAssertFalse(menuItem("File", "Reopen Closed Tab").isEnabled)
        XCTAssertFalse(menuItem("View", "Unsplit Tabs").isEnabled)
        XCTAssertTrue(menuItem("View", "Clear Scrollback").isEnabled)
        XCTAssertTrue(menuItem("View", "Toggle Sidebar").isEnabled)
        XCTAssertFalse(menuItem("View", "Actual Size").isEnabled)
        dismissMenus()
    }

    func testReopenClosedTabRestoresASession() {
        retitleFrontWindow("QAREOPEN")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QACLOSEME")
        clickMenu("File", "Close Tab")
        XCTAssertTrue(window(titled: "QAREOPEN").waitForExistence(timeout: 8))
        XCTAssertTrue(menuItem("File", "Reopen Closed Tab").isEnabled)
        menuItem("File", "Reopen Closed Tab").click()
        XCTAssertTrue(window(titled: "QACLOSEME").waitForExistence(timeout: 8), "Reopen Closed Tab did not select the closed session")
        XCTAssertTrue(menuItem("View", "Next Tab").isEnabled)
        dismissMenus()
    }

    func testKeyboardShortcutsCreateSwitchAndCloseTabs() {
        retitleFrontWindow("QAKEY1")
        app.typeKey("t", modifierFlags: .command)
        retitleFrontWindow("QAKEY2")
        XCTAssertTrue(menuItem("View", "Next Tab").isEnabled)
        dismissMenus()

        app.typeKey(.tab, modifierFlags: .control)
        XCTAssertTrue(window(titled: "QAKEY1").waitForExistence(timeout: 8), "Control-Tab did not cycle tabs")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window(titled: "QAKEY2").waitForExistence(timeout: 8), "Command-W did not close the selected tab")
        XCTAssertFalse(window(titled: "QAKEY1").exists)
    }

    func testCommandNOpensASecondWindow() {
        retitleFrontWindow("QAKEYWIN")
        app.typeKey("n", modifierFlags: .command)
        let appeared = expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: prestelWindows)
        wait(for: [appeared], timeout: 10)
        XCTAssertTrue(window(titled: "QAKEYWIN").exists)
    }

    func testZoomCommandsLeaveDefaultAndReturn() {
        XCTAssertFalse(menuItem("View", "Actual Size").isEnabled)
        dismissMenus()
        clickMenu("View", "Zoom In")
        XCTAssertTrue(menuItem("View", "Actual Size").isEnabled)
        menuItem("View", "Actual Size").click()
        XCTAssertFalse(menuItem("View", "Actual Size").isEnabled)
        dismissMenus()
        clickMenu("View", "Zoom Out")
        XCTAssertTrue(menuItem("View", "Actual Size").isEnabled)
        dismissMenus()
    }

    func testClearScrollbackIsDisabledOnTheSettingsTab() {
        clickMenu("Prestel", "Settings…")
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 8))
        XCTAssertFalse(menuItem("View", "Clear Scrollback").isEnabled)
        dismissMenus()
    }

    func testQuitWithARunningJobCanBeCancelled() {
        retitleFrontWindow("QAQUIT")
        let started = markerURL("quit")
        defer { try? FileManager.default.removeItem(at: started) }
        typeLine("printf QUITJOB > \(shellQuoted(started.path)); sleep 45")
        waitForMarker(started, containing: "QUITJOB")
        app.typeKey("q", modifierFlags: .command)
        let alert = blockingDialog(titled: "Quit Prestel?")
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "Quit with a live job did not ask for confirmation")
        alert.buttons["Cancel"].click()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(window(titled: "QAQUIT").exists)
        app.typeKey("c", modifierFlags: .control)
    }
}
