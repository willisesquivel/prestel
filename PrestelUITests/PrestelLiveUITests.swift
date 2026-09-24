import XCTest

/// Windows, tabs, and a live PTY. Each test launches Prestel.app.
final class PrestelLiveUITests: PrestelUITestCase {
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
        waitForMarker(marker, containing: "PRESTEL_QA_OK")

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
        waitForMarker(marker, containing: "No such file")
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

    func testEachWindowHasItsOwnShell() {
        let firstMarker = markerURL("win-a")
        let secondMarker = markerURL("win-b")
        defer {
            try? FileManager.default.removeItem(at: firstMarker)
            try? FileManager.default.removeItem(at: secondMarker)
        }
        let first = retitleFrontWindow("QASHELLA")
        typeLine("printf SHELL_A > \(shellQuoted(firstMarker.path))")
        waitForMarker(firstMarker, containing: "SHELL_A")

        clickMenu("File", "New Window")
        let appeared = expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: prestelWindows)
        wait(for: [appeared], timeout: 15)
        focusWindow(notTitled: first)
        retitleFrontWindow("QASHELLB")
        typeLine("printf SHELL_B > \(shellQuoted(secondMarker.path))")
        waitForMarker(secondMarker, containing: "SHELL_B")
        XCTAssertTrue(window(titled: first).exists)
        XCTAssertTrue(window(titled: "QASHELLB").exists)
    }

    func testShellAdvertisesPrestelEnvironment() {
        let marker = markerURL("env")
        defer { try? FileManager.default.removeItem(at: marker) }
        typeLine("printf %s \"$TERM_PROGRAM $COLORTERM\" > \(shellQuoted(marker.path))")
        waitForMarker(marker, containing: "Prestel")
        waitForMarker(marker, containing: "truecolor")
    }

    func testClosingTheOnlyWindowLeavesTheAppRunning() {
        clickMenu("File", "Close Window")
        let gone = expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: prestelWindows)
        wait(for: [gone], timeout: 8)
        XCTAssertEqual(app.state, .runningForeground)
        clickMenu("File", "New Window")
        XCTAssertTrue(prestelWindows.firstMatch.waitForExistence(timeout: 10))
    }
}
