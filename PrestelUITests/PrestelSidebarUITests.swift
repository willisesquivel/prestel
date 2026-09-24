import XCTest

/// Sidebar search, archive, folders, rename, and back/forward. Each test launches Prestel.app.
final class PrestelSidebarUITests: PrestelUITestCase {
    func testSearchHidesNonMatchingTabsAndEscapeClearsIt() {
        retitleFrontWindow("QAFIND")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QAHIDE")
        let search = searchField()
        search.click()
        search.typeText("QAFIND")
        XCTAssertTrue(tabRow("QAFIND").waitForExistence(timeout: 4))
        XCTAssertFalse(tabRow("QAHIDE").exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(tabRow("QAHIDE").waitForExistence(timeout: 4), "Escape did not clear sidebar search")
    }

    func testSearchWithNoMatchShowsAnEmptyTabList() {
        retitleFrontWindow("QAPRESENT")
        let search = searchField()
        search.click()
        search.typeText("zzzznomatch")
        XCTAssertFalse(tabRow("QAPRESENT").waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Archived"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(tabRow("QAPRESENT").waitForExistence(timeout: 4))
    }

    func testArchiveMovesATabOutOfTheLiveListAndUnarchiveRestoresIt() {
        retitleFrontWindow("QAKEEP")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QAARCH")
        rightClickTab("QAARCH")
        clickContext("Archive")
        XCTAssertFalse(tabRow("QAARCH").waitForExistence(timeout: 2))
        XCTAssertTrue(window(titled: "QAKEEP").waitForExistence(timeout: 5))
        app.buttons["Archived"].firstMatch.click()
        XCTAssertTrue(tabRow("QAARCH").waitForExistence(timeout: 5), "Archived list did not show the archived tab")
        rightClickTab("QAARCH")
        clickContext("Unarchive")
        XCTAssertTrue(tabRow("QAARCH").waitForExistence(timeout: 5))
        XCTAssertTrue(window(titled: "QAARCH").waitForExistence(timeout: 5))
    }

    func testNewFolderGroupsTheTabAndCollapseHidesIt() {
        retitleFrontWindow("QAFOLDER")
        rightClickTab("QAFOLDER")
        clickContext("New Folder")
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Folder' AND label CONTAINS 'folder'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5), "New Folder did not add a folder row")
        XCTAssertTrue(tabRow("QAFOLDER").exists)
        folder.click()
        XCTAssertFalse(tabRow("QAFOLDER").waitForExistence(timeout: 2))
        folder.click()
        XCTAssertTrue(tabRow("QAFOLDER").waitForExistence(timeout: 4))
    }

    func testRenameTabUpdatesTheWindowTitle() {
        retitleFrontWindow("QARENAME")
        rightClickTab("QARENAME")
        clickContext("Rename Tab")
        let editor = app.textViews.matching(NSPredicate(format: "value == %@", "QARENAME")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 4), "Rename did not open an editor for QARENAME")
        editor.typeText("QACUSTOM\n")
        XCTAssertTrue(window(titled: "QACUSTOM").waitForExistence(timeout: 8), "Rename did not change the window title")
        XCTAssertTrue(tabRow("QACUSTOM").waitForExistence(timeout: 4))
    }

    func testBackAndForwardWalkTabHistory() {
        XCTAssertFalse(app.buttons["Back"].firstMatch.isEnabled)
        XCTAssertFalse(app.buttons["Forward"].firstMatch.isEnabled)
        retitleFrontWindow("QAHIST1")
        clickMenu("File", "New Tab")
        retitleFrontWindow("QAHIST2")
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.isEnabled)
        back.click()
        XCTAssertTrue(window(titled: "QAHIST1").waitForExistence(timeout: 8))
        let forward = app.buttons["Forward"].firstMatch
        XCTAssertTrue(forward.isEnabled)
        forward.click()
        XCTAssertTrue(window(titled: "QAHIST2").waitForExistence(timeout: 8))
    }

    func testToggleSidebarHidesAndShowsTheSearchField() {
        XCTAssertTrue(searchField().exists)
        clickMenu("View", "Toggle Sidebar")
        XCTAssertTrue(app.buttons["Show sidebar"].waitForExistence(timeout: 4))
        XCTAssertFalse(searchField(require: false).exists)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Hide sidebar"].waitForExistence(timeout: 4))
        XCTAssertTrue(searchField().waitForExistence(timeout: 4))
    }

}
