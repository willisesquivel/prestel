import XCTest

/// Scripted messy sessions. Each test launches Prestel.app and does what a
/// person does when they change their mind: abandon a rename, drag a tab and
/// drop it back, spam split, and type into whichever shell is left.
final class PrestelExploratoryUITests: PrestelUITestCase {
    func testAbandonRenameThenTypeInTheShell() {
        retitleFrontWindow("QAREN")
        rightClickTab("QAREN")
        clickContext("Rename Tab")
        let editor = app.textViews.matching(NSPredicate(format: "value == %@", "QAREN")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 4), "Rename did not open an editor")
        editor.typeText("NOPE")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(window(titled: "QAREN").waitForExistence(timeout: 6), "Escape renamed the tab anyway")
        XCTAssertFalse(window(titled: "NOPE").exists)
        expectMarker("ABANDON", named: "abandon-rename")
        capture("abandon-rename")
    }

    func testDragATabAndDropItBackThenType() {
        retitleFrontWindow("QAHOLD")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QAMOVE")
        let row = tabRow("QAMOVE")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let origin = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.5, thenDragTo: origin)
        XCTAssertFalse(menuItem("View", "Unsplit Tabs").isEnabled, "Dropping a tab back on itself created a split")
        dismissMenus()
        XCTAssertTrue(window(titled: "QAMOVE").waitForExistence(timeout: 5))
        expectMarker("DROPPED_BACK", named: "drag-cancel")
        capture("drag-dropped-back")
    }

    func testRapidOpenAndCloseLeavesTheSurvivingShellUsable() {
        retitleFrontWindow("QASTAY")
        for _ in 0..<3 {
            clickMenu("File", "New Tab")
            clickMenu("File", "Close Tab")
        }
        XCTAssertTrue(window(titled: "QASTAY").waitForExistence(timeout: 8), "Rapid close did not return to the first tab")
        expectMarker("SURVIVED", named: "rapid-close")
    }

    func testSplitUnsplitSpamStillAcceptsShellInput() {
        retitleFrontWindow("QASPA")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QASPB")
        rightClickTab("QASPA")
        clickContext("Split with Active")
        if menuItem("View", "Unsplit Tabs").isEnabled {
            menuItem("View", "Unsplit Tabs").click()
        }
        dismissMenus()
        rightClickTab("QASPA")
        if app.menuItems["Split with Active"].firstMatch.waitForExistence(timeout: 2),
           app.menuItems["Split with Active"].firstMatch.isEnabled {
            app.menuItems["Split with Active"].firstMatch.click()
            if menuItem("View", "Unsplit Tabs").isEnabled {
                menuItem("View", "Unsplit Tabs").click()
            }
        }
        dismissMenus()
        expectMarker("AFTER_SPLIT_SPAM", named: "split-spam")
        capture("after-split-spam")
    }

    func testSearchThenShellDoesNotEatTheCommand() {
        retitleFrontWindow("QASEARCH")
        let search = searchField()
        search.click()
        search.typeText("zzz")
        focusTerminal(in: prestelWindows.firstMatch)
        expectMarker("LEFT_SEARCH", named: "search-then-shell")
        let query = (search.value as? String) ?? ""
        XCTAssertFalse(query.contains("LEFT_SEARCH"), "The shell command was typed into search")
    }

    func testTwoWindowsBothAcceptInputThenOneCloses() {
        let first = retitleFrontWindow("QAW1")
        clickMenu("File", "New Window")
        let appeared = expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: prestelWindows)
        wait(for: [appeared], timeout: 10)
        focusWindow(notTitled: first)
        retitleFrontWindow("QAW2")
        expectMarker("WIN2", named: "window-two")
        // Close the front window while it is key. A click aimed at the window
        // behind it is delivered to this window, and that point can be Close.
        let second = window(titled: "QAW2")
        XCTAssertTrue(second.waitForExistence(timeout: 4))
        second.buttons["Close"].firstMatch.click()
        focusWindow(notTitled: "QAW2")
        expectMarker("WIN1", named: "window-one")
        XCTAssertTrue(window(titled: "QAW1").waitForExistence(timeout: 6))
        XCTAssertFalse(window(titled: "QAW2").exists)
        expectMarker("WIN1_STILL", named: "window-one-after")
        capture("two-windows")
    }

    func testSettingsThenBackToTheTerminal() {
        retitleFrontWindow("QABACK")
        clickMenu("Prestel", "Settings…")
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 8))
        app.buttons["Dark"].click()
        app.buttons["System"].click()
        tabRow("QABACK").click()
        XCTAssertTrue(window(titled: "QABACK").waitForExistence(timeout: 8), "Leaving Settings did not restore the terminal")
        expectMarker("BACK_FROM_SETTINGS", named: "settings-back")
        capture("settings-then-terminal")
    }

    func testSwitchAwayFromARunningJobAndKeepTheOtherShell() {
        retitleFrontWindow("QAIDLE")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QAWORK")
        let started = markerURL("work")
        defer { try? FileManager.default.removeItem(at: started) }
        typeLine("printf WORK > \(shellQuoted(started.path)); sleep 20")
        waitForMarker(started, containing: "WORK")
        clickMenu("View", "Previous Tab")
        XCTAssertTrue(window(titled: "QAIDLE").waitForExistence(timeout: 8))
        expectMarker("IDLE_OK", named: "idle-while-job")
        capture("switch-away-from-job")
    }

    private func expectMarker(_ needle: String, named name: String) {
        let url = markerURL(name)
        defer { try? FileManager.default.removeItem(at: url) }
        typeLine("printf \(needle) > \(shellQuoted(url.path))")
        waitForMarker(url, containing: needle)
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
