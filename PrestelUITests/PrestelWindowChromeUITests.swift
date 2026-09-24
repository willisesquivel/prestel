import XCTest

/// Split panes, clipboard paste into the PTY, window resize, and traffic lights.
/// Each test launches Prestel.app.
final class PrestelWindowChromeUITests: PrestelUITestCase {
    func testSplitWithActiveShowsBothTerminalsAndUnsplitRemovesThePair() {
        retitleFrontWindow("QASPLIT1")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QASPLIT2")
        rightClickTab("QASPLIT1")
        clickContext("Split with Active")
        XCTAssertTrue(app.staticTexts["QASPLIT1 terminal"].waitForExistence(timeout: 6) || app.otherElements["QASPLIT1 terminal"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts["QASPLIT2 terminal"].exists
                || app.otherElements["QASPLIT2 terminal"].exists
                || app.groups["QASPLIT2 terminal"].exists
        )
        XCTAssertTrue(menuItem("View", "Unsplit Tabs").isEnabled)
        menuItem("View", "Unsplit Tabs").click()
        XCTAssertFalse(menuItem("View", "Unsplit Tabs").isEnabled)
        dismissMenus()
    }

    func testPasteDeliversClipboardTextToTheShell() {
        let marker = markerURL("paste")
        defer { try? FileManager.default.removeItem(at: marker) }
        let line = "printf PASTE_OK > \(shellQuoted(marker.path))"
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString(line, forType: .string))
        focusTerminal(in: prestelWindows.firstMatch)
        clickMenu("Edit", "Paste")
        app.typeKey(.return, modifierFlags: [])
        waitForMarker(marker, containing: "PASTE_OK")
    }

    func testSelectAllInSearchSelectsTheQuery() {
        retitleFrontWindow("QAPASTESEARCH")
        let search = searchField()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("QAPASTE")
        clickMenu("Edit", "Select All")
        app.typeText("Q")
        XCTAssertTrue(tabRow("QAPASTESEARCH").waitForExistence(timeout: 3))
    }

    func testResizeChangesTheWindowFrame() {
        let window = prestelWindows.firstMatch
        let before = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -3, dy: -3))
        let end = corner.withOffset(CGVector(dx: -180, dy: -140))
        corner.press(forDuration: 0.3, thenDragTo: end)
        let after = window.frame
        XCTAssertNotEqual(after.size.width, before.size.width)
        XCTAssertNotEqual(after.size.height, before.size.height)
        XCTAssertGreaterThanOrEqual(after.size.width, 700)
        XCTAssertGreaterThanOrEqual(after.size.height, 500)
    }

    func testZoomTrafficLightChangesTheFrameAndZoomAgainRestoresIt() {
        let window = prestelWindows.firstMatch
        let before = window.frame
        let zoom = window.buttons["Zoom"].firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 4))
        zoom.click()
        XCTAssertNotEqual(window.frame, before)
        zoom.click()
        XCTAssertEqual(window.frame.size.width, before.size.width, accuracy: 2)
        XCTAssertEqual(window.frame.size.height, before.size.height, accuracy: 2)
    }

    func testCloseTrafficLightClosesOnlyThatWindow() {
        let first = retitleFrontWindow("QACLOSEWIN")
        clickMenu("File", "New Window")
        let appeared = expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: prestelWindows)
        wait(for: [appeared], timeout: 10)
        focusWindow(notTitled: first)
        retitleFrontWindow("QASTAY")
        window(titled: "QASTAY").buttons["Close"].firstMatch.click()
        XCTAssertTrue(window(titled: first).waitForExistence(timeout: 6))
        XCTAssertFalse(window(titled: "QASTAY").exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testMinimizeTrafficLightAndWindowMenuRestoresTheWindow() {
        retitleFrontWindow("QAMINI")
        window(titled: "QAMINI").buttons["Minimize"].firstMatch.click()
        let windowMenu = app.menuBars.menuBarItems["Window"]
        windowMenu.click()
        let item = windowMenu.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "QAMINI")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 4), "Minimized window is missing from the Window menu")
        item.click()
        let window = window(titled: "QAMINI")
        XCTAssertTrue(window.waitForExistence(timeout: 6), "Window menu did not restore the minimized window")
        XCTAssertTrue(window.isHittable)
    }
}
