import Darwin
import Foundation

final class GitProcessRunner: GitCommandExecuting, @unchecked Sendable {
    static let shared = GitProcessRunner()

    private let lock = NSLock()
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var processes: [UUID: Process] = [:]
    private var gitExecutable: String?
    private var gitProbeError: String?

    func run(_ request: GitCommandRequest) async throws -> GitCommandResult {
        try Task.checkCancellation()
        let executable = try resolvedGit()
        try await acquireSlot()
        defer { releaseSlot() }
        try Task.checkCancellation()
        return try await execute(request, executable: executable)
    }

    func resolvedGit() throws -> String {
        lock.lock()
        if let gitExecutable {
            lock.unlock()
            return gitExecutable
        }
        if let gitProbeError {
            lock.unlock()
            throw GitRunnerError.gitUnavailable(gitProbeError)
        }
        lock.unlock()
        do {
            let path = try Self.locateGit()
            let version = try probe(path)
            guard Self.isSupported(version: version) else {
                let message = "Git \(version) is too old for Code Review."
                lock.lock()
                gitProbeError = message
                lock.unlock()
                throw GitRunnerError.gitUnavailable(message)
            }
            lock.lock()
            gitExecutable = path
            lock.unlock()
            return path
        } catch let error as GitRunnerError {
            if case .gitUnavailable(let message) = error {
                lock.lock()
                gitProbeError = message
                lock.unlock()
            }
            throw error
        }
    }

    private func acquireSlot() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if inFlight < ReviewBudgets.gitConcurrency {
                inFlight += 1
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func releaseSlot() {
        lock.lock()
        if waiters.isEmpty {
            inFlight = max(0, inFlight - 1)
            lock.unlock()
            return
        }
        let waiter = waiters.removeFirst()
        lock.unlock()
        waiter.resume()
    }

    private func execute(_ request: GitCommandRequest, executable: String) async throws -> GitCommandResult {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: GitCommandResult.self) { group in
                group.addTask {
                    try self.syncRun(request, executable: executable)
                }
                group.addTask {
                    try await Task.sleep(for: request.timeout)
                    throw GitRunnerError.timeout
                }
                do {
                    guard let result = try await group.next() else { throw GitRunnerError.cancelled }
                    group.cancelAll()
                    return result
                } catch {
                    self.cancel(request.identifier)
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            self.cancel(request.identifier)
        }
    }

    private func syncRun(_ request: GitCommandRequest, executable: String) throws -> GitCommandResult {
        if Task.isCancelled { throw GitRunnerError.cancelled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = request.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: request.directory, isDirectory: true)
        process.environment = Self.environment()
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        lock.lock()
        processes[request.identifier] = process
        lock.unlock()
        defer {
            lock.lock()
            processes[request.identifier] = nil
            lock.unlock()
        }
        do {
            try process.run()
        } catch {
            throw GitRunnerError.launchFailed(error.localizedDescription)
        }
        if process.processIdentifier > 0 {
            _ = setpgid(process.processIdentifier, process.processIdentifier)
        }
        let stdoutData: Data
        let stderrData: Data
        do {
            (stdoutData, stderrData) = try Self.read(stdout: stdout, stderr: stderr, limit: request.outputLimit, abort: { [self] in
                self.cancel(request.identifier)
            })
        } catch {
            if process.processIdentifier > 0 { kill(-process.processIdentifier, SIGTERM) }
            process.terminate()
            throw error
        }
        process.waitUntilExit()
        if Task.isCancelled { throw GitRunnerError.cancelled }
        let status = process.terminationStatus
        if status == 0 || (request.treatDiffExitAsSuccess && (status == 1 || status == 0)) {
            return GitCommandResult(exitStatus: status, stdout: stdoutData, stderr: stderrData)
        }
        throw GitRunnerError.failed(status: status, stderr: String(data: stderrData, encoding: .utf8) ?? "")
    }

    private func cancel(_ identifier: UUID) {
        lock.lock()
        let process = processes[identifier]
        lock.unlock()
        guard let process else { return }
        let pid = process.processIdentifier
        if pid > 0 { kill(-pid, SIGTERM) }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            if process.isRunning {
                if pid > 0 { kill(-pid, SIGKILL) }
                process.terminate()
            }
        }
    }

    private func probe(_ path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw GitRunnerError.timeout
        }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func read(stdout: Pipe, stderr: Pipe, limit: Int, abort: @escaping @Sendable () -> Void) throws -> (Data, Data) {
        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        var stdoutError: Error?
        var stderrError: Error?
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            do { stdoutData = try read(stdout.fileHandleForReading, limit: limit, abort: abort) } catch { stdoutError = error }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            do { stderrData = try read(stderr.fileHandleForReading, limit: limit, abort: abort) } catch { stderrError = error }
            group.leave()
        }
        group.wait()
        if let stdoutError { throw stdoutError }
        if let stderrError { throw stderrError }
        return (stdoutData, stderrData)
    }

    private static func read(_ handle: FileHandle, limit: Int, abort: @Sendable () -> Void) throws -> Data {
        var data = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > limit {
                abort()
                throw GitRunnerError.outputLimitExceeded
            }
        }
        return data
    }

    private static func locateGit() throws -> String {
        let candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let path = which("git") { return path }
        throw GitRunnerError.gitUnavailable("Git could not be executed.")
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    private static func isSupported(version: String) -> Bool {
        let digits = version.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map(String.init) ?? ""
        let parts = digits.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return false }
        let minor = parts.count > 1 ? parts[1] : 0
        return major > 2 || (major == 2 && minor >= 17)
    }

    static func environment() -> [String: String] {
        var values = ProcessInfo.processInfo.environment
        for key in [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_PREFIX",
            "GIT_EXTERNAL_DIFF", "GIT_DIFF_OPTS"
        ] {
            values.removeValue(forKey: key)
        }
        values["GIT_TERMINAL_PROMPT"] = "0"
        values["GIT_OPTIONAL_LOCKS"] = "0"
        values["GIT_PAGER"] = "cat"
        values["PAGER"] = "cat"
        values["GIT_ASKPASS"] = ""
        values["SSH_ASKPASS"] = ""
        values["GCM_INTERACTIVE"] = "never"
        values["GIT_LITERAL_PATHSPECS"] = "1"
        return values
    }
}
