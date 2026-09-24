import XCTest

/// Settings tab: appearance, terminal text size, session defaults, and review preference.
/// Each test launches Prestel.app.
final class PrestelSettingsUITests: PrestelUITestCase {
    func testSettingsTabShowsEveryPreferenceSection() {
        openSettings()
        for title in [
            "Appearance",
            "Interface appearance",
            "Terminal",
            "Text size",
            "Use Option as Meta",
            "New sessions",
            "Starting folder",
            "Windows",
            "Open sidebar in new windows",
            "Code review",
            "Expand files by default",
        ] {
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), "Settings is missing \(title)")
        }
        XCTAssertTrue(app.buttons["System"].exists)
        XCTAssertTrue(app.buttons["Light"].exists)
        XCTAssertTrue(app.buttons["Dark"].exists)
        XCTAssertTrue(app.buttons["Choose Folder…"].exists)
        XCTAssertTrue(window(titled: "Settings").waitForExistence(timeout: 5))
    }

    func testAppearancePickerSelectsLightAndDark() {
        openSettings()
        let dark = app.buttons["Dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        dark.click()
        XCTAssertTrue(dark.isSelected)
        let light = app.buttons["Light"]
        light.click()
        XCTAssertTrue(light.isSelected)
        XCTAssertFalse(dark.isSelected)
        app.buttons["System"].click()
        XCTAssertTrue(app.buttons["System"].isSelected)
    }

    func testTextSizeStepperChangesTheShownPointSize() {
        openSettings()
        let stepper = app.steppers.firstMatch
        XCTAssertTrue(stepper.waitForExistence(timeout: 5), "Text size stepper did not appear")
        let original = stepper.label
        XCTAssertTrue(original.contains("pt"), "Text size stepper label was \(original)")
        stepper.buttons["Increment"].click()
        XCTAssertNotEqual(stepper.label, original)
        stepper.buttons["Decrement"].click()
        XCTAssertEqual(stepper.label, original)
    }

    func testOptionAsMetaAndWindowTogglesFlip() {
        openSettings()
        let meta = labeledControl("Use Option as Meta")
        let sidebar = labeledControl("Open sidebar in new windows")
        let expand = labeledControl("Expand files by default")
        XCTAssertTrue(meta.waitForExistence(timeout: 5))
        XCTAssertTrue(sidebar.exists)
        XCTAssertTrue(expand.exists)
        let metaWas = meta.value as? String
        meta.click()
        XCTAssertNotEqual(meta.value as? String, metaWas)
        meta.click()
        XCTAssertEqual(meta.value as? String, metaWas)

        let sidebarWas = sidebar.value as? String
        sidebar.click()
        XCTAssertNotEqual(sidebar.value as? String, sidebarWas)
        sidebar.click()

        let expandWas = expand.value as? String
        expand.click()
        XCTAssertNotEqual(expand.value as? String, expandWas)
        expand.click()
    }

    func testChooseStartingFolderCancelLeavesThePath() {
        openSettings()
        let path = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Starting folder:'")
        ).firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        let before = path.label
        app.buttons["Choose Folder…"].click()
        let cancel = cancelButton()
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertEqual(path.label, before)
        XCTAssertTrue(app.staticTexts["Starting folder"].exists)
    }

    func testSettingsDoesNotReplaceTheTerminalTab() {
        let title = retitleFrontWindow("QATERM")
        openSettings()
        XCTAssertTrue(window(titled: "Settings").waitForExistence(timeout: 5))
        tabRow(title).click()
        XCTAssertTrue(window(titled: title).waitForExistence(timeout: 8), "Selecting the terminal row did not leave Settings")
    }

    private func labeledControl(_ name: String) -> XCUIElement {
        let named = NSPredicate(format: "label == %@ OR identifier == %@", name, name)
        let toggle = app.switches.matching(named).firstMatch
        if toggle.waitForExistence(timeout: 2) { return toggle }
        let checkbox = app.checkBoxes.matching(named).firstMatch
        if checkbox.exists { return checkbox }
        return toggle
    }

    private func openSettings() {
        clickMenu("Prestel", "Settings…")
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 8), "Settings tab did not open")
    }
}
