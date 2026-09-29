import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import Prestel

@Suite(.serialized)
struct ShellIntegrationTests {
    private let root = URL(fileURLWithPath: "/tmp/prestel-integration-root")

    @Test func parsesOSC133Marks() {
        #expect(ShellMark(payload: Array("A".utf8)) == .promptStart)
        #expect(ShellMark(payload: Array("A;k=s".utf8)) == .promptStart)
        #expect(ShellMark(payload: Array("B".utf8)) == .promptEnd)
        #expect(ShellMark(payload: Array("C".utf8)) == .commandStart)
        #expect(ShellMark(payload: Array("D;0".utf8)) == .commandEnd(exitCode: 0))
        #expect(ShellMark(payload: Array("D;130;aid=1".utf8)) == .commandEnd(exitCode: 130))
        #expect(ShellMark(payload: Array("D".utf8)) == .commandEnd(exitCode: nil))
        #expect(ShellMark(payload: Array("D;aid=1".utf8)) == .commandEnd(exitCode: nil))
        #expect(ShellMark(payload: Array("Z".utf8)) == nil)
        #expect(ShellMark(payload: []) == nil)
    }

    @Test func trackerPairsStartAndEnd() {
        var tracker = CommandTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(tracker.handle(.promptStart, at: t0) == nil)
        #expect(tracker.handle(.commandEnd(exitCode: 0), at: t0) == nil)
        #expect(tracker.handle(.commandStart, at: t0) == nil)
        #expect(tracker.isRunning)
        let finished = tracker.handle(.commandEnd(exitCode: 2), at: t0.addingTimeInterval(42))
        #expect(finished == FinishedCommand(duration: 42, exitCode: 2))
        #expect(!tracker.isRunning)
        // A prompt while a command is open drops it instead of inventing an end.
        _ = tracker.handle(.commandStart, at: t0)
        _ = tracker.handle(.promptStart, at: t0.addingTimeInterval(1))
        #expect(tracker.handle(.commandEnd(exitCode: 0), at: t0.addingTimeInterval(60)) == nil)
    }

    @MainActor
    @Test func notificationPolicy() {
        let long = FinishedCommand(duration: 12, exitCode: 0)
        let short = FinishedCommand(duration: 9.9, exitCode: 0)
        #expect(CommandNotifier.shouldNotify(long, enabled: true, isVisible: false))
        #expect(!CommandNotifier.shouldNotify(long, enabled: true, isVisible: true))
        #expect(!CommandNotifier.shouldNotify(long, enabled: false, isVisible: false))
        #expect(!CommandNotifier.shouldNotify(short, enabled: true, isVisible: false))
        #expect(CommandNotifier.body(for: FinishedCommand(duration: 75, exitCode: 1), title: "build")
            == "Failed with exit status 1 in build after 1m 15s")
        #expect(CommandNotifier.body(for: long, title: "build") == "Exit status 0 in build after 12s")
    }

    @Test func zshLaunchWrapsZDOTDIRAndKeepsUserValue() {
        let plain = ShellIntegration.launch(shell: "/bin/zsh", environment: ["HOME": "/h"], root: root)
        #expect(plain.arguments.isEmpty)
        #expect(plain.environment["ZDOTDIR"] == root.path + "/zsh")
        #expect(plain.environment["PRESTEL_ORIG_ZDOTDIR"] == nil)
        #expect(plain.environment["PRESTEL_SHELL_INTEGRATION"] == "1")
        #expect(plain.environment["PRESTEL_SHELL_INTEGRATION_DIR"] == root.path)
        let custom = ShellIntegration.launch(shell: "/bin/zsh", environment: ["ZDOTDIR": "/u/zsh"], root: root)
        #expect(custom.environment["PRESTEL_ORIG_ZDOTDIR"] == "/u/zsh")
    }

    @Test func bashLaunchUsesRcfileAsNonLoginShell() {
        let launch = ShellIntegration.launch(shell: "/bin/bash", environment: [:], root: root)
        #expect(launch.arguments == ["--rcfile", root.path + "/bash/prestel.bash"])
        #expect(!launch.isLogin)
        #expect(launch.environment["PRESTEL_SHELL_INTEGRATION"] == "1")
    }

    @Test func fishLaunchPrependsVendorDataDir() {
        let launch = ShellIntegration.launch(shell: "/opt/homebrew/bin/fish", environment: ["XDG_DATA_DIRS": "/x:/y"], root: root)
        #expect(launch.environment["XDG_DATA_DIRS"] == root.path + "/fish-data:/x:/y")
        let bare = ShellIntegration.launch(shell: "/usr/bin/fish", environment: [:], root: root)
        #expect(bare.environment["XDG_DATA_DIRS"]?.hasPrefix(root.path + "/fish-data:") == true)
    }

    @Test func unknownShellOrMissingRootIsUntouched() {
        let env = ["HOME": "/h"]
        #expect(ShellIntegration.launch(shell: "/bin/sh", environment: env, root: root) == .init(environment: env))
        #expect(ShellIntegration.launch(shell: "/bin/zsh", environment: env, root: nil) == .init(environment: env))
    }

    @Test func installWritesScriptsIdempotently() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prestel-si-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ShellIntegration.install(into: dir))
        let zshenv = dir.appendingPathComponent("zsh/.zshenv")
        let before = try FileManager.default.attributesOfItem(atPath: zshenv.path)[.modificationDate] as? Date
        #expect(ShellIntegration.install(into: dir))
        #expect(try FileManager.default.attributesOfItem(atPath: zshenv.path)[.modificationDate] as? Date == before)
        for path in ["zsh/prestel-integration.zsh", "bash/prestel.bash", "fish-data/fish/vendor_conf.d/prestel.fish"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path))
        }
        let zsh = try String(contentsOf: dir.appendingPathComponent("zsh/prestel-integration.zsh"), encoding: .utf8)
        #expect(zsh.contains("133;A") && zsh.contains("133;C") && zsh.contains("133;D") && zsh.contains("]7;file://"))
    }

    // MARK: Live PTY

    /// Runs `commands` in an interactive shell under a scratch HOME and
    /// returns the raw bytes the terminal would receive.
    private func captureZsh(userZshrc: String, commands: [String], workingDirectory: String) async throws -> String {
        try await capture(shell: "/bin/zsh", userRC: userZshrc, commands: commands, workingDirectory: workingDirectory)
    }

    private func capture(shell: String, userRC: String, commands: [String], workingDirectory: String) async throws -> String {
        let isZsh = shell.hasSuffix("zsh")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("prestel-zsh-\(UUID().uuidString)")
        let home = scratch.appendingPathComponent("home")
        let integration = scratch.appendingPathComponent("integration")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try userRC.write(to: home.appendingPathComponent(isZsh ? ".zshrc" : ".bashrc"), atomically: true, encoding: .utf8)
        // zsh reads .zshenv itself; a login bash replayed by the rcfile reads .bash_profile.
        try "export PRESTEL_TEST_ZSHENV=ran\n\(isZsh ? "" : ". ~/.bashrc\n")"
            .write(to: home.appendingPathComponent(isZsh ? ".zshenv" : ".bash_profile"), atomically: true, encoding: .utf8)
        #expect(ShellIntegration.install(into: integration))
        let base = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "TERM_PROGRAM": "Prestel", "LANG": "en_US.UTF-8"]
        let launch = ShellIntegration.launch(shell: shell, environment: base, root: integration)
        let collector = ByteCollector()
        let process = LocalProcess(delegate: collector, directDelivery: true)
        process.startProcess(executable: shell, args: launch.arguments,
                             environment: launch.environment.map { "\($0.key)=\($0.value)" },
                             execName: (launch.isLogin ? "-" : "") + (shell as NSString).lastPathComponent, currentDirectory: workingDirectory)
        defer { process.terminate() }
        try await wait { collector.text.contains("\u{1b}]133;B") }
        for command in commands {
            process.send(data: Array((command + "\r").utf8)[...])
            try await Task.sleep(for: .milliseconds(300))
        }
        try await Task.sleep(for: .milliseconds(400))
        return collector.text
    }

    @Test func zshEmitsCwdAndPromptMarks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prestel dir é \(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = try await captureZsh(
            userZshrc: "PS1='%# '\n",
            commands: ["cd '\(dir.path)'", "false", "echo $PRESTEL_TEST_ZSHENV"],
            workingDirectory: "/private/tmp")
        #expect(output.contains("\u{1b}]133;A\u{7}"))
        #expect(output.contains("\u{1b}]133;B\u{7}"))
        #expect(output.contains("\u{1b}]133;C\u{7}"))
        #expect(output.contains("\u{1b}]133;D;0\u{7}"))
        #expect(output.contains("\u{1b}]133;D;1\u{7}"))
        // The user's own .zshenv still ran through the wrapper.
        #expect(output.contains("\u{1b}]133;C\u{7}ran\r\n"))
        // OSC 7 round-trips through the same parser the session uses, spaces and non-ASCII included.
        let osc7 = output.components(separatedBy: "\u{1b}]7;").dropFirst().compactMap { $0.components(separatedBy: "\u{7}").first }
        #expect(osc7.compactMap(ShellConfiguration.localDirectory(fromOSC:)).contains(where: {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path
        }))
        #expect(osc7.first.flatMap(ShellConfiguration.localDirectory(fromOSC:)) == "/private/tmp")
    }

    @Test func bashEmitsCwdAndPromptMarks() async throws {
        let output = try await capture(shell: "/bin/bash", userRC: "PS1='b$ '\n",
                                       commands: ["cd /private/var", "false", "echo $PRESTEL_TEST_ZSHENV"],
                                       workingDirectory: "/private/tmp")
        #expect(output.contains("\u{1b}]133;A\u{7}b$ \u{1b}]133;B\u{7}"))
        #expect(output.contains("\u{1b}]133;C\u{7}"))
        #expect(output.contains("\u{1b}]133;D;0\u{7}"))
        #expect(output.contains("\u{1b}]133;D;1\u{7}"))
        #expect(output.contains("\u{1b}]133;C\u{7}ran\r\n"))
        #expect(output.contains("\u{1b}]7;file://localhost/private/var\u{7}"))
    }

    @Test func zshStaysOutOfTheWayWhenUserAlreadyEmitsMarks() async throws {
        let output = try await captureZsh(
            userZshrc: "PS1=$'%{\\e]133;A\\a%}%# %{\\e]133;B\\a%}'\n",
            commands: ["true"],
            workingDirectory: "/private/tmp")
        // Only the user's own A marks; the wrapper adds no C/D.
        #expect(!output.contains("\u{1b}]133;C"))
        #expect(!output.contains("\u{1b}]133;D"))
    }

    @Test func zshMarksFeedSwiftTermPromptNavigation() async throws {
        let output = try await captureZsh(userZshrc: "PS1='%# '\n", commands: ["echo one", "echo two"], workingDirectory: "/private/tmp")
        let headless = HeadlessTerminal(queue: .main, onEnd: { _ in })
        headless.terminal.resize(cols: 80, rows: 60)
        headless.terminal.feed(text: output)
        let marks = (0..<60).filter { !headless.terminal.semanticPromptMarks(at: $0).isEmpty }
        #expect(marks.count >= 3)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
        #expect(predicate())
    }
}

private final class ByteCollector: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    func dataReceived(slice: ArraySlice<UInt8>) { lock.lock(); bytes.append(contentsOf: slice); lock.unlock() }
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
}
