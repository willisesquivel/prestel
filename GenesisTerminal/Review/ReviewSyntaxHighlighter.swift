import AppKit
import Foundation
import Highlighter

final class ReviewSyntaxHighlighter: Sendable {
    private final class Core: @unchecked Sendable {
        var highlighter: Highlighter?
        var theme: String?
    }

    private let core = Core()
    private let queue = DispatchQueue(label: "genesis.review.highlight")

    func highlight(snapshot: SourceSnapshot, path: String, dark: Bool, appearanceGeneration: UInt64) async -> HighlightedSource? {
        guard let text = snapshot.text else { return nil }
        guard !snapshot.exceedsBudget else { return nil }
        let bytes = text.utf8.count
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard bytes <= ReviewBudgets.highlightBytes,
              lines.count <= ReviewBudgets.highlightLines,
              lines.allSatisfy({ $0.count <= ReviewBudgets.highlightCharactersPerLine }) else {
            return nil
        }
        let language = Self.language(for: path)
        let theme = dark ? "github-dark" : "github"
        let identity = snapshot.identity
        return await withCheckedContinuation { continuation in
            queue.async {
                if self.core.highlighter == nil {
                    self.core.highlighter = Highlighter()
                    self.core.highlighter?.ignoreIllegals = true
                }
                guard let highlighter = self.core.highlighter else {
                    continuation.resume(returning: nil)
                    return
                }
                if self.core.theme != theme {
                    _ = highlighter.setTheme(theme)
                    self.core.theme = theme
                }
                guard let rendered = highlighter.highlight(text, as: language, doFastRender: true) else {
                    continuation.resume(returning: nil)
                    return
                }
                var spans: [SyntaxSpan] = []
                rendered.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
                    guard let color = value as? NSColor,
                          let rgb = color.usingColorSpace(.sRGB) else { return }
                    spans.append(
                        SyntaxSpan(
                            utf16Start: range.location,
                            utf16Length: range.length,
                            red: rgb.redComponent,
                            green: rgb.greenComponent,
                            blue: rgb.blueComponent,
                            alpha: rgb.alphaComponent
                        )
                    )
                }
                continuation.resume(
                    returning: HighlightedSource(
                        identity: identity,
                        appearanceGeneration: appearanceGeneration,
                        spans: spans
                    )
                )
            }
        }
    }

    static func language(for path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "m", "mm", "h": return "objectivec"
        case "c": return "c"
        case "cc", "cpp", "cxx", "hpp", "hh": return "cpp"
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "jsx": return "javascript"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "py": return "python"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "go": return "go"
        case "java": return "java"
        case "kt": return "kotlin"
        case "cs": return "csharp"
        case "html", "htm": return "xml"
        case "css": return "css"
        case "scss": return "scss"
        case "sh", "zsh", "bash": return "bash"
        case "yml", "yaml": return "yaml"
        case "toml": return "ini"
        case "xml", "plist": return "xml"
        case "sql": return "sql"
        case "php": return "php"
        default: return nil
        }
    }
}
