import XCTest

/// Code Review panel: empty directory, a clean repository, and a dirty file.
/// Each test launches Prestel.app.
final class PrestelReviewUITests: PrestelUITestCase {
    func testReviewOfANonRepositoryExplainsThatState() {
        typeLine("cd /tmp")
        XCTAssertTrue(directoryLabel("/tmp").waitForExistence(timeout: 8), "cd /tmp did not update the toolbar directory")
        showReview()
        XCTAssertTrue(
            app.staticTexts["The current terminal is not inside a Git repository."].waitForExistence(timeout: 12),
            "Code Review did not explain a non-repository directory"
        )
        XCTAssertEqual(app.buttons["Code Review"].firstMatch.value as? String, "on")
    }

    func testReviewOfACleanRepositoryShowsNoChanges() throws {
        let root = try makeGitRepository()
        openReview(at: root)
        XCTAssertTrue(app.staticTexts["No uncommitted changes."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[root.lastPathComponent].exists)
    }

    func testReviewOfADirtyRepositoryListsTheFile() throws {
        let root = try makeGitRepository(dirtyFile: "notes.txt")
        openReview(at: root)
        XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 15), "Dirty file was not listed")
        XCTAssertTrue(app.staticTexts["Uncommitted changes"].exists)
    }

    func testHideCodeReviewRemovesThePanel() {
        showReview()
        XCTAssertTrue(app.staticTexts["Code Review"].firstMatch.waitForExistence(timeout: 8) || app.buttons["Code Review"].firstMatch.exists)
        clickMenu("View", "Hide Code Review")
        let toggle = app.buttons["Code Review"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "off")
        XCTAssertTrue(menuItem("View", "Show Code Review").exists)
        dismissMenus()
    }

    func testCommandRTogglesCodeReview() {
        app.typeKey("r", modifierFlags: .command)
        let toggle = app.buttons["Code Review"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertEqual(toggle.value as? String, "on")
        app.typeKey("r", modifierFlags: .command)
        XCTAssertEqual(toggle.value as? String, "off")
    }

    private func showReview() {
        clickMenu("View", "Show Code Review")
    }

    private func openReview(at root: URL) {
        typeLine("cd \(shellQuoted(root.path))")
        XCTAssertTrue(directoryLabel(root.lastPathComponent).waitForExistence(timeout: 10), "Shell did not enter \(root.path)")
        showReview()
    }

    private func directoryLabel(_ fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'terminal-directory' AND (label CONTAINS %@ OR label CONTAINS %@)", fragment, fragment == "/tmp" ? "tmp" : fragment)
        ).firstMatch
    }
}
