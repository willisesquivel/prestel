import AppKit
import Foundation

@MainActor
final class ReviewSelectionController {
    var selection: ReviewLineSelection?
    private(set) var anchorRow: Int?
    var onChange: (() -> Void)?

    func clear() {
        selection = nil
        anchorRow = nil
        onChange?()
    }

    func select(fileID: String, comparison: FileComparisonKind, revision: String, row: Int, utf16: Int, extending: Bool) {
        if extending, var current = selection, current.fileID == fileID, current.comparison == comparison, current.revision == revision {
            current.endRow = row
            current.endUTF16 = utf16
            selection = current
        } else {
            selection = ReviewLineSelection(
                fileID: fileID,
                comparison: comparison,
                revision: revision,
                startRow: row,
                endRow: row,
                startUTF16: utf16,
                endUTF16: utf16
            )
            anchorRow = row
        }
        onChange?()
    }

    func selectAll(fileID: String, comparison: FileComparisonKind, revision: String, lastRow: Int, lastUTF16: Int) {
        selection = ReviewLineSelection(
            fileID: fileID,
            comparison: comparison,
            revision: revision,
            startRow: 0,
            endRow: lastRow,
            startUTF16: 0,
            endUTF16: lastUTF16
        )
        onChange?()
    }

    func contains(fileID: String, comparison: FileComparisonKind, row: Int) -> Bool {
        guard let selection, selection.fileID == fileID, selection.comparison == comparison else { return false }
        let bounds = selection.orderedBounds
        return (bounds.fromRow...bounds.toRow).contains(row)
    }

    func utf16Range(fileID: String, comparison: FileComparisonKind, row: Int, lineLength: Int) -> NSRange? {
        guard let selection, selection.fileID == fileID, selection.comparison == comparison else { return nil }
        let bounds = selection.orderedBounds
        guard (bounds.fromRow...bounds.toRow).contains(row) else { return nil }
        if bounds.fromRow == bounds.toRow {
            let loc = min(max(0, bounds.fromUTF16), lineLength)
            let end = min(max(loc, bounds.toUTF16), lineLength)
            return NSRange(location: loc, length: end - loc)
        }
        if row == bounds.fromRow {
            let loc = min(max(0, bounds.fromUTF16), lineLength)
            return NSRange(location: loc, length: lineLength - loc)
        }
        if row == bounds.toRow {
            let len = min(max(0, bounds.toUTF16), lineLength)
            return NSRange(location: 0, length: len)
        }
        return NSRange(location: 0, length: lineLength)
    }

    func copyText(from rows: [ReviewDocumentRow]) -> String {
        guard let selection else { return "" }
        let bounds = selection.orderedBounds
        var lines: [String] = []
        var codeIndex = -1
        for row in rows {
            guard case .code(let line, let fileID, let comparison, _, _, _) = row else { continue }
            guard fileID == selection.fileID, comparison == selection.comparison else { continue }
            codeIndex += 1
            guard codeIndex >= bounds.fromRow && codeIndex <= bounds.toRow else { continue }
            let ns = line.text as NSString
            if let range = utf16Range(fileID: fileID, comparison: comparison, row: codeIndex, lineLength: ns.length), range.length > 0 {
                lines.append(ns.substring(with: range))
            } else if bounds.fromRow != bounds.toRow || bounds.fromUTF16 != bounds.toUTF16 {
                continue
            }
        }
        return lines.joined(separator: "\n")
    }
}

enum ReviewDocumentRow: Hashable {
    case fileHeader(ChangedFile)
    case comparisonHeader(ChangedFile, ComparisonSummary)
    case message(String, String)
    case folded(fileID: String, title: String, hunkIndex: Int)
    case hunkHeader(String)
    case code(DiffLine, fileID: String, comparison: FileComparisonKind, revision: String, hunkIndex: Int, lineIndex: Int)
    case spacing(String)

    var isCode: Bool {
        if case .code = self { return true }
        return false
    }
}

enum ReviewDocumentBuilder {
    static func rows(
        files: [ChangedFile],
        diffs: [String: FileDiff],
        presentation: ReviewPresentationState
    ) -> [ReviewDocumentRow] {
        var rows: [ReviewDocumentRow] = []
        for file in files {
            rows.append(.fileHeader(file))
            if presentation.expandedFileIDs.contains(file.id) {
                rows.append(contentsOf: bodyRows(file: file, diffs: diffs, presentation: presentation))
            }
            rows.append(.spacing(file.id))
        }
        return rows
    }

    static func bodyRows(
        file: ChangedFile,
        diffs: [String: FileDiff],
        presentation: ReviewPresentationState
    ) -> [ReviewDocumentRow] {
        var rows: [ReviewDocumentRow] = []
        let multiple = file.comparisons.count > 1
        for comparison in file.comparisons {
            if multiple {
                rows.append(.comparisonHeader(file, comparison))
            }
            let key = reviewDiffKey(file.id, comparison.kind)
            if let diff = diffs[key] {
                rows.append(contentsOf: diffRows(file: file, comparison: comparison, diff: diff, presentation: presentation))
            } else {
                rows.append(.message(file.id, "Loading diff…"))
            }
        }
        return rows
    }

    static func height(of row: ReviewDocumentRow) -> CGFloat {
        switch row {
        case .fileHeader: 40
        case .comparisonHeader: 28
        case .message: 32
        case .folded: 24
        case .hunkHeader: 22
        case .code: 18
        case .spacing: 8
        }
    }

    static func contentHeight(of rows: [ReviewDocumentRow]) -> CGFloat {
        rows.reduce(0) { $0 + height(of: $1) }
    }

    static func viewportHeight(of rows: [ReviewDocumentRow]) -> CGFloat {
        min(max(contentHeight(of: rows), 72), 420)
    }

    private static func diffRows(
        file: ChangedFile,
        comparison: ComparisonSummary,
        diff: FileDiff,
        presentation: ReviewPresentationState
    ) -> [ReviewDocumentRow] {
        switch diff.limitation {
        case .none:
            break
        case .large(let reason):
            return [.message(file.id, reason)]
        case .binary:
            return [.message(file.id, "Binary file changed.")]
        case .unsupportedEncoding:
            return [.message(file.id, "Text preview is unavailable for this encoding.")]
        case .truncated:
            return [.message(file.id, "This diff was truncated.")]
        case .symlink(let target):
            return [.message(file.id, "Symlink changed: \(target)")]
        case .submodule(let summary):
            return [.message(file.id, summary)]
        case .conflictPreview:
            break
        case .modeOnly:
            return [.message(file.id, "File mode changed.")]
        }

        var rows: [ReviewDocumentRow] = []
        let revealed = presentation.revealedContext[file.id] ?? []
        if let old = diff.oldSource, let new = diff.newSource, let oldText = old.text, let newText = new.text, !old.exceedsBudget, !new.exceedsBudget {
            rows.append(contentsOf: foldedRows(file: file, comparison: comparison.kind, diff: diff, oldLines: splitLines(oldText), newLines: splitLines(newText), revealed: revealed))
        } else {
            for (hunkIndex, hunk) in diff.hunks.enumerated() {
                rows.append(.hunkHeader(hunk.header))
                for (lineIndex, line) in hunk.lines.enumerated() {
                    rows.append(.code(line, fileID: file.id, comparison: comparison.kind, revision: diff.revision, hunkIndex: hunkIndex, lineIndex: lineIndex))
                }
            }
        }
        return rows
    }

    private static func foldedRows(
        file: ChangedFile,
        comparison: FileComparisonKind,
        diff: FileDiff,
        oldLines: [String],
        newLines: [String],
        revealed: Set<Int>
    ) -> [ReviewDocumentRow] {
        var rows: [ReviewDocumentRow] = []
        var oldCursor = 1
        var newCursor = 1
        for (hunkIndex, hunk) in diff.hunks.enumerated() {
            let hiddenOld = max(0, hunk.oldStart - oldCursor)
            if hiddenOld > 0 {
                if revealed.contains(hunkIndex) || hiddenOld <= ReviewBudgets.contextLines {
                    let count = hiddenOld
                    for offset in 0..<count {
                        let oldNumber = oldCursor + offset
                        let newNumber = newCursor + offset
                        let text = oldLines.indices.contains(oldNumber - 1) ? oldLines[oldNumber - 1] : ""
                        rows.append(.code(
                            DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: text, missingNewline: false),
                            fileID: file.id,
                            comparison: comparison,
                            revision: diff.revision,
                            hunkIndex: hunkIndex,
                            lineIndex: -offset - 1
                        ))
                    }
                } else {
                    rows.append(.folded(fileID: file.id, title: "\(hiddenOld) unchanged lines", hunkIndex: hunkIndex))
                }
            }
            for (lineIndex, line) in hunk.lines.enumerated() {
                rows.append(.code(line, fileID: file.id, comparison: comparison, revision: diff.revision, hunkIndex: hunkIndex, lineIndex: lineIndex))
            }
            oldCursor = hunk.oldStart + hunk.oldCount
            newCursor = hunk.newStart + hunk.newCount
        }
        let trailing = max(0, oldLines.count - (oldCursor - 1))
        if trailing > 0 {
            let marker = diff.hunks.count
            if revealed.contains(marker) {
                for offset in 0..<trailing {
                    let oldNumber = oldCursor + offset
                    let newNumber = newCursor + offset
                    let text = oldLines.indices.contains(oldNumber - 1) ? oldLines[oldNumber - 1] : ""
                    rows.append(.code(
                        DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: text, missingNewline: false),
                        fileID: file.id,
                        comparison: comparison,
                        revision: diff.revision,
                        hunkIndex: marker,
                        lineIndex: -offset - 1
                    ))
                }
            } else {
                rows.append(.folded(fileID: file.id, title: "\(trailing) unchanged lines", hunkIndex: marker))
            }
        }
        return rows
    }

    private static func splitLines(_ text: String) -> [String] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if text.hasSuffix("\n") && lines.last == "" { lines.removeLast() }
        return lines
    }
}

@MainActor
enum ReviewFocus {
    static func isProtected(_ responder: NSResponder?) -> Bool {
        var current = responder
        while let node = current {
            if node is ReviewFocusOwning { return true }
            current = node.nextResponder
        }
        return false
    }
}

protocol ReviewFocusOwning: AnyObject {}
