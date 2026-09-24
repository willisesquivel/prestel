import AppKit
import XCTest

/// Base for tests that start the real Prestel.app. `XCUIApplication.launch()`
/// is a separate process from the test runner. Do not set
/// `XCTestConfigurationFilePath` on that process: Prestel treats it as a
/// unit-test host and does not open a window.
@MainActor
class PrestelUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        addUIInterruptionMonitor(withDescription: "System notification") { alert in
            let dismiss = alert.buttons["Close"].exists ? alert.buttons["Close"] : alert.buttons.firstMatch
            if dismiss.exists {
                dismiss.click()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 25), "Prestel.app did not reach the foreground")
        let window = prestelWindows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "Prestel.app launched but no window appeared")
        focusTerminal(in: window)
        _ = searchField(require: false).waitForExistence(timeout: 8)
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
        URL(fileURLWithPath: "/tmp/prestel-qa-\(name)-\(UUID().uuidString).txt")
    }

    func controlValue(_ element: XCUIElement) -> String {
        if let text = element.value as? String, !text.isEmpty { return text }
        if let number = element.value as? NSNumber { return number.stringValue }
        return ""
    }

    func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func searchField(require: Bool = true) -> XCUIElement {
        let named = NSPredicate(format: "identifier == %@ OR label == %@", "Search terminal tabs", "Search terminal tabs")
        let field = app.textViews.matching(named).firstMatch
        if require {
            XCTAssertTrue(field.waitForExistence(timeout: 5), "Sidebar search field is missing")
        }
        return field
    }

    func terminalLabeled(_ title: String) -> XCUIElement {
        let label = "\(title) terminal"
        return app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR identifier == %@", label, label)
        ).firstMatch
    }

    func tabRow(_ title: String) -> XCUIElement {
        let named = NSPredicate(format: "identifier == %@ OR label == %@ OR value == %@", title, title, title)
        let button = app.buttons.matching(named).firstMatch
        if button.waitForExistence(timeout: 2) { return button }
        let text = app.textViews.matching(named).firstMatch
        if text.waitForExistence(timeout: 2) { return text }
        return button
    }

    func rightClickTab(_ title: String) {
        let row = tabRow(title)
        XCTAssertTrue(row.waitForExistence(timeout: 6), "No sidebar row titled \(title)")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    }

    func clickContext(_ title: String) {
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 4), "Context menu is missing \(title)")
        item.click()
    }

    @discardableResult
    func makeGitRepository(dirtyFile: String? = nil) throws -> URL {
        // The test runner is sandboxed. Prestel.app cannot see that container, so the repo lives in /tmp.
        let root = URL(fileURLWithPath: "/tmp/prestel-qa-repo-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw XCTSkip("UI test runner cannot create \(root.path): \(error.localizedDescription)")
        }
        let git = developerGit()
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

    /// `/usr/bin/git` is an `xcrun` shim. The UI-test runner is sandboxed, so that shim fails.
    private func developerGit() -> String {
        let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? (FileManager.default.fileExists(atPath: "/Applications/Xcode_26.6.app")
                ? "/Applications/Xcode_26.6.app/Contents/Developer"
                : "/Applications/Xcode.app/Contents/Developer")
        let candidate = (developer as NSString).appendingPathComponent("usr/bin/git")
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        return "/usr/bin/git"
    }
}
