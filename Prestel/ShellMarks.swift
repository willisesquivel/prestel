import AppKit
import UserNotifications

/// One OSC 133 action. SwiftTerm already parses these to place prompt rows
/// (that is what "Jump to Previous Prompt" uses), but it drops command start
/// and end, so the session also observes them here for timing and exit codes.
enum ShellMark: Equatable {
    case promptStart
    case promptEnd
    case commandStart
    case commandEnd(exitCode: Int?)

    /// `payload` is the OSC body after `133;`, e.g. `A`, `B`, `C`, `D;0`.
    init?(payload: [UInt8]) {
        guard let first = payload.first else { return nil }
        let fields = String(decoding: payload, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        switch first {
        case UInt8(ascii: "A"), UInt8(ascii: "N"): self = .promptStart
        case UInt8(ascii: "B"): self = .promptEnd
        case UInt8(ascii: "C"): self = .commandStart
        case UInt8(ascii: "D"):
            // Options such as `aid=1` may follow; the exit code is the first bare integer.
            let code = fields.dropFirst().first.flatMap { Int($0) }
            self = .commandEnd(exitCode: code)
        default: return nil
        }
    }
}

struct FinishedCommand: Equatable {
    var duration: TimeInterval
    var exitCode: Int?
}

/// Pairs command start and end marks into finished commands. A new prompt
/// while a command is still open means the shell never reported an end
/// (interrupted integration), so the command is dropped rather than guessed.
struct CommandTracker {
    private var startedAt: Date?
    var isRunning: Bool { startedAt != nil }

    mutating func handle(_ mark: ShellMark, at date: Date) -> FinishedCommand? {
        switch mark {
        case .commandStart:
            startedAt = date
        case .commandEnd(let exitCode):
            guard let start = startedAt else { return nil }
            startedAt = nil
            return FinishedCommand(duration: max(0, date.timeIntervalSince(start)), exitCode: exitCode)
        case .promptStart:
            startedAt = nil
        case .promptEnd:
            break
        }
        return nil
    }
}

/// "Command finished" notifications for long-running commands that end while
/// the user is looking elsewhere. Authorization is requested on first use.
@MainActor
enum CommandNotifier {
    static let defaultsKey = "notifyLongCommands"
    static let minimumDuration: TimeInterval = 10

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    static func shouldNotify(_ command: FinishedCommand, enabled: Bool, isVisible: Bool) -> Bool {
        enabled && !isVisible && command.duration >= minimumDuration
    }

    static func body(for command: FinishedCommand, title: String) -> String {
        let status = command.exitCode.map { $0 == 0 ? "Exit status 0" : "Failed with exit status \($0)" } ?? "Finished"
        return "\(status) in \(title) after \(format(command.duration))"
    }

    static func format(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    static func post(_ command: FinishedCommand, session: TerminalSession) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Command finished"
        content.body = body(for: command, title: session.displayTitle)
        content.sound = .default
        content.userInfo = ["tabID": session.id.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            case .authorized, .provisional:
                center.add(request)
            default:
                break
            }
        }
    }
}
