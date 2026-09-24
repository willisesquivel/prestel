import AppKit
import XCTest

/// Base for tests that start the real Prestel.app. `XCUIApplication.launch()`
/// is a separate process from the test runner. Do not set
/// `XCTestConfigurationFilePath` on that process: Prestel treats it as a
/// unit-test host and does not open a window.
class PrestelUITestCase: XCTestCase {
    var app = XCUIApplication()

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 25), "Prestel.app did not reach the foreground")
        let window = prestelWindows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "Prestel.app launched but no window appeared")
        focusTerminal(in: window)
        Thread.sleep(forTimeInterval: 2.0)
    }

    override func tearDownWithError() throws {
        attachFailureEvidence()
        if app.state == .runningForeground {
            dismissBlockingDialogs()
            app.terminate()
        }
        try super.tearDownWithError()
    }

    func attachFailureEvidence() {
        let failed = (testRun?.failureCount ?? 0) > 0 || (testRun?.unexpectedExceptionCount ?? 0) > 0
        guard failed else { return }
        if app.state == .runningForeground || app.state == .runningBackground {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "failure-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        let titles = (0..<min(prestelWindows.count, 8)).map { prestelWindows.element(boundBy: $0).title }
        let note = XCTAttachment(string: "Prestel windows: \(titles.joined(separator: " | "))")
        note.name = "windows-\(name)"
        note.lifetime = .keepAlways
        add(note)
    }

    var prestelWindows: XCUIElementQuery {
        app.windows.matching(NSPredicate(format: "title CONTAINS %@", "Prestel"))
    }

    func window(titled fragment: String) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title CONTAINS %@", fragment)).firstMatch
    }

    func focusTerminal(in window: XCUIElement) {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.62)).click()
    }

    func focusWindow(notTitled forbidden: String) {
        let other = app.windows.matching(
            NSPredicate(format: "title CONTAINS 'Prestel' AND NOT title CONTAINS %@", forbidden)
        ).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 8), "No second Prestel window besides \(forbidden)")
        focusTerminal(in: other)
    }

    func cancelButton() -> XCUIElement {
        let candidates = [
            app.sheets.buttons["Cancel"],
            app.dialogs.buttons["Cancel"],
            app.windows.buttons["Cancel"],
        ]
        return candidates.first { $0.exists } ?? app.buttons["Cancel"]
    }

    @discardableResult
    func retitleFrontWindow(_ name: String) -> String {
        typeLine("printf '\\033]0;\(name)\\007'")
        let titled = window(titled: name)
        XCTAssertTrue(
            titled.waitForExistence(timeout: 15),
            "Shell did not update the window title to \(name). Front title is \(prestelWindows.firstMatch.title)"
        )
        return name
    }

    func typeLine(_ line: String) {
        focusTerminal(in: prestelWindows.firstMatch)
        app.typeText(line + "\n")
    }

    func clickMenu(_ menu: String, _ item: String) {
        let menuItem = menuItem(menu, item)
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Missing menu item \(menu) > \(item)")
        XCTAssertTrue(menuItem.isEnabled, "\(menu) > \(item) is disabled")
        menuItem.click()
    }

    func menuItem(_ menu: String, _ item: String) -> XCUIElement {
        let bar = app.menuBars.menuBarItems[menu]
        if !bar.menuItems[item].exists {
            bar.click()
        }
        return bar.menuItems[item]
    }

    func dismissMenus() {
        app.typeKey(.escape, modifierFlags: [])
    }

    func blockingDialog(titled title: String) -> XCUIElement {
        if app.sheets[title].exists { return app.sheets[title] }
        return app.dialogs[title]
    }

    func dismissBlockingDialogs() {
        for container in [app.sheets.firstMatch, app.dialogs.firstMatch] where container.exists {
            if container.buttons["Cancel"].exists {
                container.buttons["Cancel"].click()
            } else if container.buttons["Quit Prestel"].exists {
                container.buttons["Quit Prestel"].click()
            }
        }
    }

    func waitForMarker(_ url: URL, containing needle: String, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
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

    func markerURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("prestel-qa-\(name)-\(UUID().uuidString).txt")
    }

    func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func rightClickTab(_ title: String) {
        let button = app.buttons[title].firstMatch
        if button.waitForExistence(timeout: 4) {
            button.rightClick()
            return
        }
        let text = app.staticTexts[title].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 4), "No sidebar row titled \(title)")
        text.rightClick()
    }

    func clickContext(_ title: String) {
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 4), "Context menu is missing \(title)")
        item.click()
    }

    @discardableResult
    func makeGitRepository(dirtyFile: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prestel-qa-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = "/usr/bin/git"
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: git), "git is not installed")
        func run(_ arguments: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = arguments
            process.currentDirectoryURL = root
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                XCTFail("git \(arguments.joined(separator: " ")) failed to start: \(error)")
                return
            }
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) → \(output)")
        }
        run(["init", "-q", "-b", "main"])
        run(["config", "user.email", "qa@example.com"])
        run(["config", "user.name", "Prestel QA"])
        try "seed\n".write(to: root.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        run(["add", "README"])
        run(["commit", "-q", "-m", "seed"])
        if let dirtyFile {
            try "changed\n".write(to: root.appendingPathComponent(dirtyFile), atomically: true, encoding: .utf8)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
