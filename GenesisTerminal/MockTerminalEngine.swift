import SwiftUI

// MARK: - Minimal ANSI SGR model (mock phase)

/// One styled run inside a terminal line.
struct TerminalSegment: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let color: TerminalColor
    let bold: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TerminalSegment, rhs: TerminalSegment) -> Bool {
        lhs.id == rhs.id
    }
}

enum TerminalColor: Hashable {
    case `default`
    case black, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite

    func swiftUIColor(isDark: Bool) -> Color {
        switch self {
        case .default: return .primary
        case .black: return Color(white: isDark ? 0.25 : 0.0)
        case .red: return Color(red: 0.95, green: 0.26, blue: 0.21)
        case .green: return Color(red: 0.18, green: 0.80, blue: 0.44)
        case .yellow: return Color(red: 0.95, green: 0.77, blue: 0.06)
        case .blue: return Color(red: 0.20, green: 0.55, blue: 1.0)
        case .magenta: return Color(red: 0.75, green: 0.34, blue: 1.0)
        case .cyan: return Color(red: 0.20, green: 0.80, blue: 0.90)
        case .white: return Color(white: isDark ? 0.92 : 0.35)
        case .brightBlack: return Color(white: 0.55)
        case .brightRed: return Color(red: 1.0, green: 0.42, blue: 0.36)
        case .brightGreen: return Color(red: 0.30, green: 0.90, blue: 0.55)
        case .brightYellow: return Color(red: 1.0, green: 0.85, blue: 0.20)
        case .brightBlue: return Color(red: 0.40, green: 0.68, blue: 1.0)
        case .brightMagenta: return Color(red: 0.85, green: 0.50, blue: 1.0)
        case .brightCyan: return Color(red: 0.40, green: 0.90, blue: 1.0)
        case .brightWhite: return Color(white: isDark ? 1.0 : 0.15)
        }
    }
}

/// A terminal line = ordered styled runs.
struct TerminalLine: Identifiable, Hashable {
    let id = UUID()
    var segments: [TerminalSegment]

    static func plain(_ text: String) -> TerminalLine {
        TerminalLine(segments: [TerminalSegment(text: text, color: .default, bold: false)])
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TerminalLine, rhs: TerminalLine) -> Bool {
        lhs.id == rhs.id
    }
}

enum AnsiParser {
    /// Tiny SGR subset (`\u{1B}[...m`): 0 reset, 1 bold, 30-37 / 90-97 fg.
    static func parse(_ input: String) -> [TerminalSegment] {
        var segments: [TerminalSegment] = []
        var current = ""
        var color: TerminalColor = .default
        var bold = false

        func flush() {
            if !current.isEmpty {
                segments.append(TerminalSegment(text: current, color: color, bold: bold))
                current = ""
            }
        }

        var i = input.startIndex
        while i < input.endIndex {
            let ch = input[i]
            if ch == "\u{1B}" {
                let next = input.index(after: i)
                if next < input.endIndex, input[next] == "[" {
                    if let mIndex = input[next...].firstIndex(of: "m") {
                        flush()
                        let codeStr = String(input[input.index(after: next)..<mIndex])
                        apply(codes: codeStr, color: &color, bold: &bold)
                        i = input.index(after: mIndex)
                        continue
                    }
                }
            }
            current.append(ch)
            i = input.index(after: i)
        }
        flush()
        if segments.isEmpty {
            segments.append(TerminalSegment(text: "", color: .default, bold: false))
        }
        return segments
    }

    private static func apply(codes: String, color: inout TerminalColor, bold: inout Bool) {
        if codes.isEmpty || codes == "0" {
            color = .default
            bold = false
            return
        }
        for part in codes.split(separator: ";") {
            guard let code = Int(part) else { continue }
            switch code {
            case 0:
                color = .default; bold = false
            case 1:
                bold = true
            case 30: color = .black
            case 31: color = .red
            case 32: color = .green
            case 33: color = .yellow
            case 34: color = .blue
            case 35: color = .magenta
            case 36: color = .cyan
            case 37: color = .white
            case 90: color = .brightBlack
            case 91: color = .brightRed
            case 92: color = .brightGreen
            case 93: color = .brightYellow
            case 94: color = .brightBlue
            case 95: color = .brightMagenta
            case 96: color = .brightCyan
            case 97: color = .brightWhite
            default:
                break
            }
        }
    }
}

// MARK: - Mock session (one buffer per sidebar session)

@MainActor
final class MockTerminalSession: ObservableObject {
    let sessionID: UUID
    @Published var lines: [TerminalLine] = []
    @Published var commandCount = 0
    private var kind: SessionKind

    init(session: TerminalSession) {
        self.sessionID = session.id
        self.kind = session.kind
        self.lines = Self.bootScript(for: session.kind)
    }

    /// Called when the owning session switches TUI kind (e.g. typing `codex`).
    func noteKind(_ kind: SessionKind) {
        self.kind = kind
    }

    func submit(_ raw: String, prompt: String) {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(TerminalLine(segments: [
            TerminalSegment(text: prompt, color: .green, bold: true),
            TerminalSegment(text: command, color: .default, bold: false)
        ]))
        if command.isEmpty { return }
        commandCount += 1
        for chunk in MockTerminalEngine.response(for: command, kind: kind) {
            lines.append(TerminalLine(segments: AnsiParser.parse(chunk)))
        }
    }

    func appendNotice(_ text: String) {
        lines.append(TerminalLine(segments: AnsiParser.parse("\u{1B}[33m\(text)\u{1B}[0m")))
    }

    func clear() {
        lines = Self.bootScript(for: kind)
    }

    private static func bootScript(for kind: SessionKind) -> [TerminalLine] {
        switch kind {
        case .terminal:
            return parseAll([
                "\u{1B}[32mian@genesis\u{1B}[0m:\u{1B}[34m~/Lume\u{1B}[0m — zsh 5.9 (mock, no PTY yet)",
                "Type \u{1B}[1mhelp\u{1B}[0m for canned commands.",
                ""
            ])
        case .codex:
            return parseAll([
                "\u{1B}[1mcodex (mock)\u{1B}[0m — ~/Lume @ 6ed58ac4",
                "\u{1B}[90mreasoning traces and diffs will stream here in the PTY phase.\u{1B}[0m",
                ""
            ])
        case .claude:
            return parseAll([
                "\u{1B}[33m✳ Claude Code (mock)\u{1B}[0m — ~/Lume @ 6ed58ac4",
                "\u{1B}[90mtype `exit` to flip back to the plain terminal icon.\u{1B}[0m",
                ""
            ])
        case .opencode:
            return parseAll([
                "\u{1B}[1mOpenCode (mock)\u{1B}[0m — ~/Lume @ 6ed58ac4",
                "\u{1B}[90mtype `exit` to flip back to the plain terminal icon.\u{1B}[0m",
                ""
            ])
        case .settings:
            return []
        }
    }

    private static func parseAll(_ raws: [String]) -> [TerminalLine] {
        raws.map { TerminalLine(segments: AnsiParser.parse($0)) }
    }
}

// MARK: - Canned command responses

enum MockTerminalEngine {
    static func response(for command: String, kind: SessionKind) -> [String] {
        let lower = command.lowercased()
        let head = lower.split(separator: " ").first.map(String.init) ?? ""

        switch head {
        case "help":
            return [
                "canned: \u{1B}[1mls\u{1B}[0m  \u{1B}[1mgit status\u{1B}[0m  \u{1B}[1mcodex\u{1B}[0m  \u{1B}[1mclaude\u{1B}[0m  \u{1B}[1mopencode\u{1B}[0m  \u{1B}[1mexit\u{1B}[0m  \u{1B}[1mclear\u{1B}[0m",
                "\u{1B}[90mPTY phase will fork /bin/zsh instead of this table.\u{1B}[0m"
            ]
        case "ls":
            return ["\u{1B}[34mLume\u{1B}[0m  README.md  GenesisTerminal.xcodeproj"]
        case "git":
            return [
                "\u{1B}[32mM\u{1B}[0m  GenesisTerminal/TerminalView.swift",
                "\u{1B}[90m6ed58ac4 (mock ref)\u{1B}[0m"
            ]
        case "codex", "claude", "opencode":
            return ["\u{1B}[90mmock: '\(command)' echoed locally — PTY phase will exec it via /bin/zsh.\u{1B}[0m"]
        case "exit", "quit":
            return ["\u{1B}[90mlogout (mock — session stays open).\u{1B}[0m"]
        case "clear":
            return ["\u{1B}[90m(mock: use Clear button — buffer kept per-tab)\u{1B}[0m"]
        case "whoami":
            return ["ian"]
        case "echo":
            let rest = command.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return [rest.isEmpty ? "" : rest]
        default:
            let kindHint = kind == .terminal ? "" : " [\(kind.displayName) mock]"
            return ["\u{1B}[90mmock\(kindHint):\u{1B}[0m '\(command)' echoed locally — PTY phase will exec it via /bin/zsh."]
        }
    }
}
