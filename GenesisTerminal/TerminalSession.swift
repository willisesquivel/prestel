import AppKit
import Combine
import Darwin
import SwiftTerm

enum ShellConfiguration {
    static var loginShell: String {
        if let shell = getpwuid(getuid())?.pointee.pw_shell {
            let path = String(cString: shell)
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/sh"
    }
    static var defaultDirectory: String { validDirectory(UserDefaults.standard.string(forKey: "startingDirectory")) }
    static func validDirectory(_ path: String?) -> String {
        if let path, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue { return expanded }
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
    static var environment: [String] {
        var values = ProcessInfo.processInfo.environment
        for key in ["XPC_SERVICE_NAME", "XPC_FLAGS", "TERM_SESSION_ID", "SHLVL", "_", "PWD", "OLDPWD"] { values.removeValue(forKey: key) }
        // Universal TUI transparency contract (same pattern as OpenCode `system`):
        // Genesis renders default-background cells transparently so the glass
        // shows through (SwiftTerm skips filling default-bg runs; see
        // AppleTerminalView). TUIs only inherit the glass when they paint
        // `none`/default backgrounds. These vars let every TUI opt in:
        // - TERM=xterm-256color: widely-recognized 256-color entry.
        // - COLORTERM=truecolor: advertises 24-bit color (OpenCode/Gemini docs
        //   check `echo $COLORTERM` for `truecolor`/`24bit`).
        // - TERM_PROGRAM=Genesis (+ version): lets shells/TUIs detect us
        //   (e.g. zsh disables Apple's OSC 7 hook; Gemini/Claude auto-themes
        //   use OSC 11, which SwiftTerm already answers from our native colors).
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        values["TERM_PROGRAM"] = "Genesis"
        values["TERM_PROGRAM_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        values["SHELL"] = loginShell
        values["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        if values["LANG"] == nil { values["LANG"] = "en_US.UTF-8" }
        return values.map { "\($0.key)=\($0.value)" }
    }
    static func escapedPath(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func displayDirectory(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
    static func localDirectory(fromOSC value: String) -> String? {
        guard let url = URL(string: value), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" || url.host == ProcessInfo.processInfo.hostName,
              url.path.hasPrefix("/") else { return nil }
        return url.path
    }
}

/// Feeds incremental bytes on the serial I/O queue. Only metadata/exit crosses to AppKit.
private final class ProcessAdapter: LocalProcessDelegate, @unchecked Sendable {
    weak var surface: GenesisTerminalView?
    private let lock = NSLock()
    private var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    var onExit: (@MainActor @Sendable (Int32?) -> Void)?
    var onFailure: (@MainActor @Sendable (String) -> Void)?
    var onActivity: (@MainActor @Sendable () -> Void)?
    private let activityLock = NSLock()
    private var lastActivityForward = Date.distantPast
    func updateSize(columns: Int, rows: Int) -> winsize {
        lock.lock()
        defer { lock.unlock() }
        size.ws_col = UInt16(clamping: columns)
        size.ws_row = UInt16(clamping: rows)
        return size
    }
    func getWindowSize() -> winsize { lock.lock(); defer { lock.unlock() }; return size }
    func dataReceived(slice: ArraySlice<UInt8>) {
        surface?.feed(byteArray: slice)
        // Throttled leading edge (at most one hop per 200ms): the session
        // debounces these into a trailing cwd refresh, so `cd` shows up in
        // ~150ms instead of waiting for the backup poll.
        activityLock.lock()
        let now = Date()
        let shouldForward = now.timeIntervalSince(lastActivityForward) >= 0.2
        if shouldForward { lastActivityForward = now }
        activityLock.unlock()
        if shouldForward, let callback = onActivity { Task { @MainActor in callback() } }
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let callback = onExit
        Task { @MainActor in callback?(exitCode) }
    }
    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        let callback = onFailure
        let message = String(describing: error)
        Task { @MainActor in callback?(message) }
    }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, TerminalViewDelegate {
    enum State: Equatable { case ready, running, exited(Int32?), failed(String), closed }
    let id: UUID
    let kind: TabKind
    @Published private(set) var title: String
    @Published private(set) var directory: String
    @Published private(set) var state: State = .ready
    private(set) var surface: GenesisTerminalView?
    private(set) var process: LocalProcess?
    private var adapter: ProcessAdapter?
    private var cwdPollTimer: Timer?
    private var cwdDebounceTask: Task<Void, Never>?

    init(descriptor: TabDescriptor) {
        id = descriptor.id
        kind = descriptor.kind
        title = descriptor.title.isEmpty ? "Local" : descriptor.title
        directory = ShellConfiguration.validDirectory(descriptor.directory)
        super.init()
    }
    var currentDirectory: String {
        guard let process, process.running, let actual = ProcessInspection.directory(pid: process.shellPid) else { return directory }
        return actual
    }
    var descriptor: TabDescriptor { TabDescriptor(id: id, kind: kind, title: title, directory: currentDirectory) }
    var hasActiveJobs: Bool {
        guard let process, process.running else { return false }
        let foreground = tcgetpgrp(process.childfd)
        return (foreground > 0 && foreground != process.shellPid) || !ProcessInspection.children(of: process.shellPid).isEmpty
    }
    func start() {
        guard kind == .terminal, state == .ready else { return }
        let surface = GenesisTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 500),
                                          options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 10_000))
        surface.terminalDelegate = self
        surface.applyPreferences()
        surface.setAccessibilityLabel("\(title) terminal")
        let adapter = ProcessAdapter()
        adapter.surface = surface
        adapter.onExit = { [weak self] code in
            guard let self, self.state != .closed else { return }
            self.state = .exited(code)
        }
        adapter.onFailure = { [weak self] message in
            guard let self, self.state != .closed else { return }
            self.state = .failed(message)
            self.surface?.feed(text: "\r\nUnable to start shell: \(message)\r\n")
        }
        adapter.onActivity = { [weak self] in self?.scheduleCwdRefresh() }
        _ = adapter.updateSize(columns: surface.terminalDimensions.cols, rows: surface.terminalDimensions.rows)
        let process = LocalProcess(delegate: adapter, directDelivery: true)
        process.killEscalationDelay = 0.7
        self.surface = surface
        self.adapter = adapter
        self.process = process
        state = .running
        let shell = ShellConfiguration.loginShell
        process.startProcess(executable: shell, args: [], environment: ShellConfiguration.environment,
                             execName: "-" + URL(fileURLWithPath: shell).lastPathComponent, currentDirectory: directory)
        startCwdPolling()
    }
    func close() {
        guard state != .closed else { return }
        cwdPollTimer?.invalidate()
        cwdPollTimer = nil
        cwdDebounceTask?.cancel()
        cwdDebounceTask = nil
        directory = currentDirectory
        state = .closed
        if let process, process.running { ProcessInspection.hangupJobs(shell: process.shellPid) }
        surface?.terminalDelegate = nil
        surface?.removeFromSuperview()
        surface = nil
        // LocalProcess's reaper guards PID reuse and escalates after its grace period.
        let retiringProcess = process
        let retiringAdapter = adapter
        process = nil
        adapter = nil
        // Give the shell a turn to reap hung-up jobs before its own teardown.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withExtendedLifetime(retiringProcess) {}
            withExtendedLifetime(retiringAdapter) {}
        }
    }
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { process?.send(data: data) }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        guard var size = adapter?.updateSize(columns: newCols, rows: newRows) else { return }
        _ = process?.updateWindowSize(&size)
    }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
        self.title = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(256))
        if self.title.isEmpty { self.title = "Local" }
        // Titles are usually sent alongside a prompt redraw, so the shell cwd
        // has likely just changed too. Opportunistically re-read it: shells
        // that don't emit OSC 7 (e.g. zsh with TERM_PROGRAM=Genesis, which
        // disables Apple's precmd hook) would otherwise leave the header stale.
        refreshDirectoryFromProcess()
    }
    /// Kernel truth for the shell's cwd. Used as a fallback when the shell
    /// doesn't report OSC 7, otherwise the header keeps showing the tab's
    /// starting directory (e.g. ~/terminals after cd ~/genesis).
    func refreshDirectoryFromProcess() {
        guard state == .running, let process, process.running,
              let actual = ProcessInspection.directory(pid: process.shellPid),
              actual != directory else { return }
        directory = actual
    }
    private func startCwdPolling() {
        cwdPollTimer?.invalidate()
        // Lightweight backup: one proc_pidinfo per tick per tab. The primary
        // path is activity-driven (see onActivity/scheduleCwdRefresh), so this
        // only matters for cwd changes with zero pty output.
        cwdPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDirectoryFromProcess() }
        }
    }
    /// Coalesced trailing refresh after pty output. `cd` changes the cwd
    /// before the redrawn prompt arrives, so waiting ~150ms after activity
    /// reads the new directory — without it the echo of the command itself
    /// would trigger a refresh of the still-old cwd.
    func scheduleCwdRefresh() {
        guard state == .running, cwdDebounceTask == nil else { return }
        cwdDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch { return }
            self?.cwdDebounceTask = nil
            self?.refreshDirectoryFromProcess()
        }
    }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        if let directory, let path = ShellConfiguration.localDirectory(fromOSC: directory) { self.directory = path }
    }
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http", "mailto", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
}

enum ProcessInspection {
    static func directory(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0 else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            guard let base = bytes.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
    static func children(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var values = [pid_t](repeating: 0, count: Int(count) + 16)
        let capacity = values.count * MemoryLayout<pid_t>.size
        let actual = proc_listchildpids(pid, &values, Int32(capacity))
        return values.prefix(max(0, min(Int(actual), values.count))).filter { $0 > 0 }
    }
    static func hangupJobs(shell: pid_t) {
        guard shell > 0 else { return }
        var pending = children(of: shell)
        var visited = Set<pid_t>()
        var jobs: [(pid_t, UInt64, UInt64)] = []
        while let pid = pending.popLast(), visited.count < 4096 {
            guard visited.insert(pid).inserted else { continue }
            pending.append(contentsOf: children(of: pid))
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0, getsid(pid) == shell {
                jobs.append((pid, info.pbi_start_tvsec, info.pbi_start_tvusec))
                kill(pid, SIGHUP)
                kill(pid, SIGCONT)
            }
        }
        let identities = jobs
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.9) {
            for (pid, seconds, micros) in identities {
                var info = proc_bsdinfo()
                if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
                   info.pbi_start_tvsec == seconds, info.pbi_start_tvusec == micros { kill(pid, SIGKILL) }
            }
        }
    }
}
