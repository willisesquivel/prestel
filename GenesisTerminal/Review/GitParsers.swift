import Foundation

enum GitStatusParser {
    struct BranchInfo: Equatable, Sendable {
        var oid: String?
        var head: String?
        var isDetached = false
        var isUnborn = false
    }

    struct OrdinaryRecord: Equatable, Sendable {
        var xy: String
        var submodule: String
        var headMode: String
        var indexMode: String
        var worktreeMode: String
        var headOID: String
        var indexOID: String
        var path: ReviewPath
    }

    struct RenameRecord: Equatable, Sendable {
        var xy: String
        var submodule: String
        var headMode: String
        var indexMode: String
        var worktreeMode: String
        var headOID: String
        var indexOID: String
        var score: String
        var path: ReviewPath
        var origPath: ReviewPath
        var isCopy: Bool
    }

    struct UnmergedRecord: Equatable, Sendable {
        var xy: String
        var submodule: String
        var stage1Mode: String
        var stage2Mode: String
        var stage3Mode: String
        var worktreeMode: String
        var stage1OID: String
        var stage2OID: String
        var stage3OID: String
        var path: ReviewPath
    }

    struct ParsedStatus: Equatable, Sendable {
        var branch: BranchInfo
        var ordinary: [OrdinaryRecord]
        var renames: [RenameRecord]
        var unmerged: [UnmergedRecord]
        var untracked: [ReviewPath]
        var ignored: [ReviewPath]
        var isTruncated: Bool
    }

    static func parse(_ data: Data, entryLimit: Int = ReviewBudgets.statusChangedEntries) -> ParsedStatus {
        var branch = BranchInfo()
        var ordinary: [OrdinaryRecord] = []
        var renames: [RenameRecord] = []
        var unmerged: [UnmergedRecord] = []
        var untracked: [ReviewPath] = []
        var ignored: [ReviewPath] = []
        var isTruncated = false
        var offset = 0
        let bytes = [UInt8](data)

        func remaining() -> ArraySlice<UInt8> { bytes[offset...] }

        while offset < bytes.count {
            let marker = bytes[offset]
            if marker == 0x23 { // '#'
                let line = scanHeader(bytes, from: &offset)
                parseBranchLine(line, into: &branch)
                continue
            }

            let entries = ordinary.count + renames.count + unmerged.count + untracked.count
            if entries >= entryLimit {
                isTruncated = true
                break
            }

            switch marker {
            case 0x31: // '1'
                if let record = parseOrdinary(bytes, from: &offset) {
                    ordinary.append(record)
                } else {
                    skipUntilNUL(bytes, from: &offset)
                }
            case 0x32: // '2'
                if let record = parseRename(bytes, from: &offset) {
                    renames.append(record)
                } else {
                    skipUntilNUL(bytes, from: &offset)
                    skipUntilNUL(bytes, from: &offset)
                }
            case 0x75: // 'u'
                if let record = parseUnmerged(bytes, from: &offset) {
                    unmerged.append(record)
                } else {
                    skipUntilNUL(bytes, from: &offset)
                }
            case 0x3F: // '?'
                _ = consumePrefix(bytes, from: &offset, expected: "? ")
                untracked.append(ReviewPath.from(Data(scanUntilNUL(bytes, from: &offset))))
            case 0x21: // '!'
                _ = consumePrefix(bytes, from: &offset, expected: "! ")
                ignored.append(ReviewPath.from(Data(scanUntilNUL(bytes, from: &offset))))
            case 0x0A, 0x0D, 0x00:
                offset += 1
            default:
                skipUntilNUL(bytes, from: &offset)
                if offset < bytes.count, bytes[offset] != 0x23, bytes[offset] != 0x31, bytes[offset] != 0x32,
                   bytes[offset] != 0x75, bytes[offset] != 0x3F, bytes[offset] != 0x21 {
                    skipUntilNUL(bytes, from: &offset)
                }
            }
            _ = remaining()
        }

        return ParsedStatus(
            branch: branch,
            ordinary: ordinary,
            renames: renames,
            unmerged: unmerged,
            untracked: untracked,
            ignored: ignored,
            isTruncated: isTruncated
        )
    }

    private static func parseBranchLine(_ line: String, into branch: inout BranchInfo) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let oid = value(after: "# branch.oid ", in: trimmed) {
            if oid == "(initial)" {
                branch.isUnborn = true
                branch.oid = nil
            } else {
                branch.oid = oid
            }
        } else if let head = value(after: "# branch.head ", in: trimmed) {
            if head == "(detached)" {
                branch.isDetached = true
                branch.head = nil
            } else {
                branch.head = head
            }
        }
    }

    private static func parseOrdinary(_ bytes: [UInt8], from offset: inout Int) -> OrdinaryRecord? {
        guard consumePrefix(bytes, from: &offset, expected: "1 ") else { return nil }
        let payload = Data(scanUntilNUL(bytes, from: &offset))
        guard let text = String(data: payload, encoding: .utf8) else {
            return nil
        }
        let parts = splitOnce(text, count: 8)
        guard parts.count == 8 else { return nil }
        return OrdinaryRecord(
            xy: parts[0],
            submodule: parts[1],
            headMode: parts[2],
            indexMode: parts[3],
            worktreeMode: parts[4],
            headOID: parts[5],
            indexOID: parts[6],
            path: ReviewPath.from(parts[7])
        )
    }

    private static func parseRename(_ bytes: [UInt8], from offset: inout Int) -> RenameRecord? {
        guard consumePrefix(bytes, from: &offset, expected: "2 ") else { return nil }
        let first = Data(scanUntilNUL(bytes, from: &offset))
        let orig = Data(scanUntilNUL(bytes, from: &offset))
        guard let text = String(data: first, encoding: .utf8) else { return nil }
        let parts = splitOnce(text, count: 9)
        guard parts.count == 9 else { return nil }
        let score = parts[7]
        return RenameRecord(
            xy: parts[0],
            submodule: parts[1],
            headMode: parts[2],
            indexMode: parts[3],
            worktreeMode: parts[4],
            headOID: parts[5],
            indexOID: parts[6],
            score: score,
            path: ReviewPath.from(parts[8]),
            origPath: ReviewPath.from(orig),
            isCopy: parts[0].contains("C") || score.hasPrefix("C")
        )
    }

    private static func parseUnmerged(_ bytes: [UInt8], from offset: inout Int) -> UnmergedRecord? {
        guard consumePrefix(bytes, from: &offset, expected: "u ") else { return nil }
        let payload = Data(scanUntilNUL(bytes, from: &offset))
        guard let text = String(data: payload, encoding: .utf8) else { return nil }
        let parts = splitOnce(text, count: 10)
        guard parts.count == 10 else { return nil }
        return UnmergedRecord(
            xy: parts[0],
            submodule: parts[1],
            stage1Mode: parts[2],
            stage2Mode: parts[3],
            stage3Mode: parts[4],
            worktreeMode: parts[5],
            stage1OID: parts[6],
            stage2OID: parts[7],
            stage3OID: parts[8],
            path: ReviewPath.from(parts[9])
        )
    }
}

enum GitNumstatParser {
    struct Record: Equatable, Sendable {
        var additions: Int?
        var deletions: Int?
        var path: ReviewPath
        var origPath: ReviewPath?
        var isBinary: Bool
    }

    static func parse(_ data: Data) -> [Record] {
        var records: [Record] = []
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            if bytes[offset] == 0 { offset += 1; continue }
            let first = Data(scanUntilNUL(bytes, from: &offset))
            guard let line = String(data: first, encoding: .utf8), !line.isEmpty else { continue }
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let isRenameHeader = fields.count == 2 || (fields.count == 3 && fields[2].isEmpty)
            if isRenameHeader {
                let orig = Data(scanUntilNUL(bytes, from: &offset))
                let dest = Data(scanUntilNUL(bytes, from: &offset))
                let binary = fields[0] == "-" || fields[1] == "-"
                records.append(
                    Record(
                        additions: binary ? nil : Int(fields[0]),
                        deletions: binary ? nil : Int(fields[1]),
                        path: ReviewPath.from(dest),
                        origPath: ReviewPath.from(orig),
                        isBinary: binary
                    )
                )
            } else if fields.count >= 3 {
                let binary = fields[0] == "-" || fields[1] == "-"
                records.append(
                    Record(
                        additions: binary ? nil : Int(fields[0]),
                        deletions: binary ? nil : Int(fields[1]),
                        path: ReviewPath.from(fields[2]),
                        origPath: nil,
                        isBinary: binary
                    )
                )
            }
        }
        return records
    }
}

enum UnifiedDiffParser {
    enum ParseError: Error, Equatable {
        case malformed
        case truncated
        case combinedDiff
        case hunkCountMismatch
    }

    struct ParsedPatch: Equatable, Sendable {
        var hunks: [DiffHunk]
        var isBinary: Bool
        var oldPath: String?
        var newPath: String?
        var missingNewlineOnLastLine: Bool
        var raw: String
    }

    static func parse(_ data: Data) throws -> ParsedPatch {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ParseError.malformed
        }
        if text.contains("\ndiff --cc ") || text.contains("\ndiff --combined ") || text.hasPrefix("diff --cc ") {
            throw ParseError.combinedDiff
        }
        var hunks: [DiffHunk] = []
        var isBinary = text.contains("Binary files ") || text.contains("GIT binary patch")
        var oldPath: String?
        var newPath: String?
        let lines = splitKeepingEnds(text)
        var index = 0
        while index < lines.count {
            let line = stripTerminator(lines[index])
            if line.hasPrefix("diff --git ") {
                let names = gitPaths(from: line)
                oldPath = names.old
                newPath = names.new
            } else if line.hasPrefix("--- ") {
                oldPath = filePath(fromHeader: line)
            } else if line.hasPrefix("+++ ") {
                newPath = filePath(fromHeader: line)
            } else if line.hasPrefix("@@ ") {
                let hunk = try parseHunk(lines, start: &index)
                hunks.append(hunk)
                continue
            }
            index += 1
        }
        return ParsedPatch(
            hunks: hunks,
            isBinary: isBinary,
            oldPath: oldPath,
            newPath: newPath,
            missingNewlineOnLastLine: text.contains("\\ No newline at end of file"),
            raw: text
        )
    }

    private static func parseHunk(_ lines: [String], start index: inout Int) throws -> DiffHunk {
        let headerLine = stripTerminator(lines[index])
        guard let header = parseHunkHeader(headerLine) else { throw ParseError.malformed }
        index += 1
        var oldRemaining = header.oldCount
        var newRemaining = header.newCount
        var oldNumber = header.oldStart
        var newNumber = header.newStart
        var body: [DiffLine] = []
        while index < lines.count {
            let raw = lines[index]
            let line = stripTerminator(raw)
            if line.hasPrefix("@@ ") || line.hasPrefix("diff --git ") { break }
            if line.hasPrefix("\\ No newline at end of file") {
                if !body.isEmpty {
                    body[body.count - 1].missingNewline = true
                }
                index += 1
                continue
            }
            guard let first = line.first else {
                // Empty context line with no prefix can appear; treat as context.
                body.append(DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: "", missingNewline: false))
                oldNumber += 1
                newNumber += 1
                oldRemaining -= 1
                newRemaining -= 1
                index += 1
                continue
            }
            switch first {
            case " ":
                body.append(DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: String(line.dropFirst()), missingNewline: false))
                oldNumber += 1
                newNumber += 1
                oldRemaining -= 1
                newRemaining -= 1
            case "+":
                body.append(DiffLine(kind: .addition, oldNumber: nil, newNumber: newNumber, text: String(line.dropFirst()), missingNewline: false))
                newNumber += 1
                newRemaining -= 1
            case "-":
                body.append(DiffLine(kind: .deletion, oldNumber: oldNumber, newNumber: nil, text: String(line.dropFirst()), missingNewline: false))
                oldNumber += 1
                oldRemaining -= 1
            default:
                if line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file") {
                    break
                }
                throw ParseError.malformed
            }
            index += 1
            if oldRemaining <= 0 && newRemaining <= 0 { break }
        }
        if oldRemaining != 0 || newRemaining != 0 {
            // Zero-count hunks (additions to empty / deletions to empty) are valid when the
            // declared count was 0 and we consumed nothing on that side.
            if !(header.oldCount == 0 && oldRemaining == 0) && !(header.newCount == 0 && newRemaining == 0) {
                if oldRemaining < 0 || newRemaining < 0 || (oldRemaining != 0 && newRemaining != 0 && !body.isEmpty) {
                    throw ParseError.hunkCountMismatch
                }
            }
        }
        return DiffHunk(
            oldStart: header.oldStart,
            oldCount: header.oldCount,
            newStart: header.newStart,
            newCount: header.newCount,
            header: headerLine,
            lines: body
        )
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        // @@ -oldStart,oldCount +newStart,newCount @@
        guard line.hasPrefix("@@ ") else { return nil }
        var scanner = line.dropFirst(3)
        func consumeRange(_ prefix: Character) -> (Int, Int)? {
            guard scanner.first == prefix else { return nil }
            scanner = scanner.dropFirst()
            var number = ""
            while let ch = scanner.first, ch.isNumber {
                number.append(ch)
                scanner = scanner.dropFirst()
            }
            guard let start = Int(number) else { return nil }
            var count = 1
            if scanner.first == "," {
                scanner = scanner.dropFirst()
                var countText = ""
                while let ch = scanner.first, ch.isNumber {
                    countText.append(ch)
                    scanner = scanner.dropFirst()
                }
                guard let parsed = Int(countText) else { return nil }
                count = parsed
            }
            if scanner.first == " " { scanner = scanner.dropFirst() }
            return (start, count)
        }
        guard let old = consumeRange("-"), let new = consumeRange("+") else { return nil }
        return (old.0, old.1, new.0, new.1)
    }
}

private func value(after prefix: String, in line: String) -> String? {
    guard line.hasPrefix(prefix) else { return nil }
    return String(line.dropFirst(prefix.count))
}

private func splitOnce(_ text: String, count: Int) -> [String] {
    var parts: [String] = []
    var remaining = text[...]
    for index in 0..<count {
        if index == count - 1 {
            parts.append(String(remaining))
            break
        }
        guard let space = remaining.firstIndex(of: " ") else { return parts }
        parts.append(String(remaining[..<space]))
        remaining = remaining[remaining.index(after: space)...]
    }
    return parts
}

private func scanHeader(_ bytes: [UInt8], from offset: inout Int) -> String {
    let start = offset
    while offset < bytes.count && bytes[offset] != 0 && bytes[offset] != 0x0A {
        offset += 1
    }
    let slice = bytes[start..<offset]
    if offset < bytes.count { offset += 1 }
    return String(bytes: slice.filter { $0 != 0x0D }, encoding: .utf8) ?? ""
}

private func scanUntilNUL(_ bytes: [UInt8], from offset: inout Int) -> ArraySlice<UInt8> {
    let start = offset
    while offset < bytes.count && bytes[offset] != 0 {
        offset += 1
    }
    let slice = bytes[start..<offset]
    if offset < bytes.count { offset += 1 }
    return slice
}

private func skipUntilNUL(_ bytes: [UInt8], from offset: inout Int) {
    _ = scanUntilNUL(bytes, from: &offset)
}

private func consumePrefix(_ bytes: [UInt8], from offset: inout Int, expected: String) -> Bool {
    let prefix = Array(expected.utf8)
    guard bytes[offset...].starts(with: prefix) else { return false }
    offset += prefix.count
    return true
}

private func splitKeepingEnds(_ text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for character in text {
        current.append(character)
        if character == "\n" {
            lines.append(current)
            current = ""
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

private func stripTerminator(_ line: String) -> String {
    if line.hasSuffix("\r\n") { return String(line.dropLast(2)) }
    if line.hasSuffix("\n") { return String(line.dropLast()) }
    if line.hasSuffix("\r") { return String(line.dropLast()) }
    return line
}

private func filePath(fromHeader line: String) -> String {
    let stripped = String(line.dropFirst(4))
    if stripped == "/dev/null" { return stripped }
    if stripped.hasPrefix("a/") || stripped.hasPrefix("b/") { return String(stripped.dropFirst(2)) }
    return stripped
}

private func gitPaths(from line: String) -> (old: String?, new: String?) {
    let rest = line.dropFirst("diff --git ".count)
    let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2 else { return (nil, nil) }
    func strip(_ value: Substring) -> String {
        if value.hasPrefix("a/") || value.hasPrefix("b/") { return String(value.dropFirst(2)) }
        return String(value)
    }
    return (strip(parts[0]), strip(parts[1]))
}
