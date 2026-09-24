import XCTest

/// Drag, focus, and lifecycle sequences that are easy to get stuck in.
/// Each test launches Prestel.app. Screenshots are kept so a failed gesture
/// can be inspected without rerunning the job.
final class PrestelEdgeCaseUITests: PrestelUITestCase {
    func testDraggingABackgroundTabOntoTheVisibleTerminalSplitsThem() {
        retitleFrontWindow("QAVISIBLE")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QADRAG")
        tabRow("QAVISIBLE").click()
        XCTAssertTrue(window(titled: "QAVISIBLE").waitForExistence(timeout: 8))

        dragTab("QADRAG", to: CGVector(dx: 0.86, dy: 0.58))
        capture("split-background-onto-visible")

        XCTAssertTrue(terminal("QAVISIBLE"), "Visible tab disappeared after the drop")
        XCTAssertTrue(terminal("QADRAG"), "Dragging the background tab onto the terminal did not open it beside the visible tab")
        XCTAssertTrue(menuItem("View", "Unsplit Tabs").isEnabled, "Split was not created; Unsplit Tabs stayed disabled")
        dismissMenus()
    }

    func testDraggingTheVisibleTabOntoItsOwnPanelTriesToSplitWithItself() {
        retitleFrontWindow("QAOTHER")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QASELF")
        XCTAssertTrue(window(titled: "QASELF").waitForExistence(timeout: 8))

        dragTab("QASELF", to: CGVector(dx: 0.86, dy: 0.58))
        capture("split-visible-tab-onto-itself")

        let splitTheOtherTab = terminal("QAOTHER") && menuItem("View", "Unsplit Tabs").isEnabled
        dismissMenus()
        XCTAssertTrue(
            splitTheOtherTab,
            "Dragging the visible tab onto its own panel did not split it with the other tab. The content stayed on the dragged tab, so the drop targeted itself and the gesture could not finish."
        )
    }

    func testReorderingATabInTheSidebarChangesRowOrder() {
        retitleFrontWindow("QATOP")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QABOTTOM")
        let top = tabRow("QATOP")
        let bottom = tabRow("QABOTTOM")
        XCTAssertTrue(bottom.waitForExistence(timeout: 5))
        XCTAssertLessThan(top.frame.minY, bottom.frame.minY)

        let start = bottom.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        let end = top.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.0))
        start.press(forDuration: 0.5, thenDragTo: end)
        capture("sidebar-reorder")

        let topAfter = tabRow("QATOP")
        let bottomAfter = tabRow("QABOTTOM")
        XCTAssertTrue(topAfter.waitForExistence(timeout: 4))
        XCTAssertTrue(bottomAfter.exists)
        XCTAssertLessThan(bottomAfter.frame.minY, topAfter.frame.minY, "Dragging the lower tab above the upper tab did not reorder the sidebar")
    }

    func testEachTabKeepsItsOwnShellWhileSwitching() {
        let first = markerURL("tab-a")
        let second = markerURL("tab-b")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        retitleFrontWindow("QAPTY1")
        typeLine("printf TAB_A > \(shellQuoted(first.path))")
        waitForMarker(first, containing: "TAB_A")

        clickMenu("File", "New Tab")
        retitleFrontWindow("QAPTY2")
        typeLine("printf TAB_B > \(shellQuoted(second.path))")
        waitForMarker(second, containing: "TAB_B")

        clickMenu("View", "Previous Tab")
        XCTAssertTrue(window(titled: "QAPTY1").waitForExistence(timeout: 8))
        let again = markerURL("tab-a2")
        defer { try? FileManager.default.removeItem(at: again) }
        typeLine("printf TAB_A2 > \(shellQuoted(again.path))")
        waitForMarker(again, containing: "TAB_A2")

        let firstText = (try? String(contentsOf: first, encoding: .utf8)) ?? ""
        let secondText = (try? String(contentsOf: second, encoding: .utf8)) ?? ""
        XCTAssertFalse(firstText.contains("TAB_B"))
        XCTAssertFalse(secondText.contains("TAB_A2"))
    }

    func testClosingTheActiveTabWhileItIsBusyLeavesTheOtherShellUsable() {
        retitleFrontWindow("QALIVE")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QABUSY")
        typeLine("sleep 30")
        Thread.sleep(forTimeInterval: 0.8)
        clickMenu("File", "Close Tab")
        let alert = blockingDialog(titled: "Close Tab?")
        if alert.waitForExistence(timeout: 4) {
            alert.buttons["Close Tab"].click()
        }
        XCTAssertTrue(window(titled: "QALIVE").waitForExistence(timeout: 8), "Closing the busy tab did not return to the other session")
        let marker = markerURL("after-close")
        defer { try? FileManager.default.removeItem(at: marker) }
        typeLine("printf STILL_ALIVE > \(shellQuoted(marker.path))")
        waitForMarker(marker, containing: "STILL_ALIVE")
    }

    func testRapidTabCyclingStillDeliversShellInput() {
        retitleFrontWindow("QACYCLE1")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QACYCLE2")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QACYCLE3")
        for _ in 0..<6 {
            app.typeKey(.tab, modifierFlags: .control)
        }
        let marker = markerURL("cycle")
        defer { try? FileManager.default.removeItem(at: marker) }
        typeLine("printf AFTER_CYCLE > \(shellQuoted(marker.path))")
        waitForMarker(marker, containing: "AFTER_CYCLE")
    }

    func testKeysGoToTheShellAfterLeavingSearch() {
        retitleFrontWindow("QAFOCUS")
        let search = searchField()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("not-the-shell")
        focusTerminal(in: prestelWindows.firstMatch)
        let marker = markerURL("focus")
        defer { try? FileManager.default.removeItem(at: marker) }
        app.typeText("printf FOCUS_OK > \(shellQuoted(marker.path))\n")
        waitForMarker(marker, containing: "FOCUS_OK")
        XCTAssertFalse(((search.value as? String) ?? "").contains("FOCUS_OK"))
    }

    func testShellStillAcceptsInputAfterTheWindowIsResized() {
        let window = prestelWindows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.98))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.75))
        start.press(forDuration: 0.2, thenDragTo: end)
        capture("after-resize")
        let marker = markerURL("resize")
        defer { try? FileManager.default.removeItem(at: marker) }
        typeLine("printf AFTER_RESIZE > \(shellQuoted(marker.path))")
        waitForMarker(marker, containing: "AFTER_RESIZE")
    }

    func testCloseTabOnTheLastSessionClosesTheWindowAndTheAppStaysUp() {
        retitleFrontWindow("QALAST")
        clickMenu("File", "Close Tab")
        let gone = expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: prestelWindows)
        wait(for: [gone], timeout: 8)
        XCTAssertEqual(app.state, .runningForeground)
        clickMenu("File", "New Window")
        XCTAssertTrue(prestelWindows.firstMatch.waitForExistence(timeout: 10))
    }

    func testChromeDoesNotCoverTheSidebarSearchOrTrafficLights() {
        let window = prestelWindows.firstMatch
        let close = window.buttons["Close"].firstMatch
        let search = searchField()
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        XCTAssertTrue(close.isHittable, "Close traffic light is not hittable")
        XCTAssertTrue(search.isHittable, "Sidebar search is not hittable")
        XCTAssertFalse(close.frame.intersects(search.frame), "Close button overlaps the sidebar search field")
        XCTAssertGreaterThanOrEqual(window.frame.width, 760)
        XCTAssertGreaterThanOrEqual(window.frame.height, 540)
        capture("launch-chrome")

        clickMenu("Prestel", "Settings…")
        XCTAssertTrue(app.staticTexts["Text size"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Dark"].isHittable, "Appearance choice is not hittable")
        capture("settings")
    }

    private func dragTab(_ title: String, to point: CGVector) {
        let row = tabRow(title)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "No row titled \(title) to drag")
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = prestelWindows.firstMatch.coordinate(withNormalizedOffset: point)
        start.press(forDuration: 0.6, thenDragTo: end)
    }

    private func terminal(_ title: String) -> Bool {
        app.staticTexts["\(title) terminal"].exists
            || app.otherElements["\(title) terminal"].exists
            || app.groups["\(title) terminal"].exists
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
