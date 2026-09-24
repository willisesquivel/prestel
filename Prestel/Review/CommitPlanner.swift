import Foundation

struct CommitSelection: Equatable, Sendable {
    var paths: [String]
    var untrackedPaths: [String]
    var conflictPaths: [String]
    var unsafePaths: [String]
}

enum CommitPlanner {
    static func selection(from files: [ChangedFile]) -> CommitSelection {
        var paths: [String] = []
        var untracked: [String] = []
        var conflicts: [String] = []
        var unsafe: [String] = []
        for file in files {
            let path = file.identityPath.display
            if !file.identityPath.isLossless || !isSafeRelativePath(path) {
                unsafe.append(path)
                continue
            }
            if file.kind == .conflicted || file.comparisons.contains(where: { $0.kind == .conflict }) {
                conflicts.append(path)
                continue
            }
            paths.append(path)
            if file.kind == .untracked || file.comparisons.contains(where: { $0.kind == .untracked }) {
                untracked.append(path)
            }
        }
        return CommitSelection(paths: paths, untrackedPaths: untracked, conflictPaths: conflicts, unsafePaths: unsafe)
    }

    static func refusal(
        files: [ChangedFile],
        push: Bool,
        detached: Bool,
        indexLocked: Bool,
        catalogComplete: Bool
    ) -> String? {
        if indexLocked { return "Wait for the Git operation to finish." }
        if !catalogComplete { return "The file list is incomplete. Refresh before committing." }
        let selection = selection(from: files)
        if !selection.unsafePaths.isEmpty { return "A changed path could not be read safely." }
        if !selection.conflictPaths.isEmpty { return "Resolve the conflicted files before committing." }
        if selection.paths.isEmpty { return "There is nothing to commit." }
        if push && detached { return "This checkout is detached. Commit without pushing." }
        return nil
    }

    static func canSubmit(
        files: [ChangedFile],
        message: String,
        push: Bool,
        detached: Bool,
        indexLocked: Bool,
        catalogComplete: Bool
    ) -> Bool {
        guard refusal(files: files, push: push, detached: detached, indexLocked: indexLocked, catalogComplete: catalogComplete) == nil else {
            return false
        }
        return !CommitMessage.subjectLine(message).isEmpty
    }

    /// The web page for opening a pull request from `branch`, derived from the
    /// remote URL. GitLab and Bitbucket get their own forms; any other host is
    /// assumed to follow GitHub’s.
    static func pullRequestURL(remote: String, branch: String) -> URL? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !branch.isEmpty, branch != "HEAD" else { return nil }
        var host: String
        var path: String
        if let url = URL(string: text), let scheme = url.scheme, ["https", "http", "ssh", "git"].contains(scheme), let urlHost = url.host() {
            host = urlHost
            path = url.path()
        } else if let colon = text.firstIndex(of: ":"), !text.hasPrefix("/") {
            // scp-like: git@host:owner/repo.git
            var authority = String(text[..<colon])
            if let at = authority.lastIndex(of: "@") {
                authority = String(authority[authority.index(after: at)...])
            }
            host = authority
            path = String(text[text.index(after: colon)...])
        } else {
            return nil
        }
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, path.split(separator: "/").count >= 2 else { return nil }
        if host.hasPrefix("ssh.") { host.removeFirst(4) }
        text = "https://\(host)/\(path)"
        var components = URLComponents(string: text)
        let lowered = host.lowercased()
        if lowered.contains("gitlab") {
            components?.path += "/-/merge_requests/new"
            components?.queryItems = [URLQueryItem(name: "merge_request[source_branch]", value: branch)]
        } else if lowered.contains("bitbucket") {
            components?.path += "/pull-requests/new"
            components?.queryItems = [URLQueryItem(name: "source", value: branch)]
        } else {
            let escaped = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
            components?.percentEncodedPath += "/pull/new/\(escaped)"
        }
        return components?.url
    }

    /// Status paths are relative to the work tree. Reject anything `git add` could
    /// resolve outside that tree.
    private static func isSafeRelativePath(_ path: String) -> Bool {
        if path.isEmpty || path.contains("\u{0}") || path.hasPrefix("/") { return false }
        return !path.split(separator: "/").contains("..")
    }
}

enum CommitDigest {
    static let budget = 6_000

    static func clip(_ text: String, budget: Int = budget) -> String {
        guard text.count > budget else { return text }
        let end = text.index(text.startIndex, offsetBy: budget)
        let head = text[..<end]
        if let newline = head.lastIndex(of: "\n"), head.distance(from: head.startIndex, to: newline) > budget / 2 {
            return String(head[..<newline]) + "\n[diff truncated]"
        }
        return String(head) + "\n[diff truncated]"
    }

    static func failureLine(_ stderr: String, fallback: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let useful = lines.first { line in
            let lower = line.lowercased()
            return !line.isEmpty && !lower.hasPrefix("hint:") && !lower.hasPrefix("warning:")
        }
        var text = useful ?? fallback
        if text.lowercased().hasPrefix("fatal:") {
            text = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        if text.count > 280 { return String(text.prefix(280)) }
        return text
    }
}

enum CommitMessage {
    static let maxSubjectLength = 72

    /// The message git receives. The first line is the subject; everything after
    /// the blank line is kept.
    static func prepared(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var start = 0
        var end = lines.count
        while start < end, lines[start].isEmpty { start += 1 }
        while end > start, lines[end - 1].isEmpty { end -= 1 }
        guard start < end else { return "" }
        var collapsed: [String] = []
        var pendingBlank = false
        for line in lines[start..<end] {
            if line.isEmpty {
                pendingBlank = true
                continue
            }
            if pendingBlank, !collapsed.isEmpty { collapsed.append("") }
            pendingBlank = false
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n")
    }

    static func subjectLine(_ raw: String) -> String {
        prepared(raw).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    static func cleaned(_ raw: String) -> String {
        subjectLine(raw)
    }

    /// Subject plus an optional explanation. A vague or repeated explanation is left off.
    static func composed(subject rawSubject: String, detail rawDetail: String) -> String {
        let subject = subject(from: rawSubject)
        guard !subject.isEmpty else { return "" }
        let detail = prepared(rawDetail)
        if detail.isEmpty || detail.compare(subject, options: .caseInsensitive) == .orderedSame {
            return subject
        }
        if !detail.contains("\n"), isWeak(subjectLine(detail)) {
            return subject
        }
        return subject + "\n\n" + detail
    }

    static func subject(from raw: String) -> String {
        var text = cleaned(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["commit:", "subject:", "title:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if text.hasSuffix(".") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxSubjectLength else { return text }
        let bounded = String(text.prefix(maxSubjectLength + 1))
        if let space = bounded.lastIndex(of: " "), bounded.distance(from: bounded.startIndex, to: space) >= 24 {
            return String(bounded[..<space]).trimmingCharacters(in: .whitespaces)
        }
        return String(text.prefix(maxSubjectLength)).trimmingCharacters(in: .whitespaces)
    }

    static func isWeak(_ subject: String) -> Bool {
        let normalized = subject
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let weak: Set<String> = [
            "update", "updates", "update files", "update code", "update the code",
            "changes", "change", "misc", "miscellaneous", "wip", "todo",
            "fix", "fixes", "fix bug", "bug fix", "bugfix",
            "cleanup", "clean up", "tweaks", "tweak", "minor changes",
            "various changes", "various fixes", "commit", "save", "edits"
        ]
        return normalized.isEmpty || weak.contains(normalized)
    }

    static func fileLine(_ file: ChangedFile) -> String {
        var line = "\(file.kind.title) \(file.identityPath.display)"
        if file.comparisons.contains(where: { $0.additions != nil || $0.deletions != nil }) {
            line += " +\(file.additions) -\(file.deletions)"
        }
        if let old = file.oldPath?.display, old != file.identityPath.display {
            line += " (from \(old))"
        }
        return line
    }
}

enum CommitMessagePrompt {
    static let instructions = """
    You name a git commit from a diff.
    The name is one line a maintainer would keep without editing.
    Say what changed, specific enough that a different diff would get a different name.
    Follow the grammar of the recent subjects when those subjects share a grammar. Otherwise use the imperative mood.
    At most 72 characters. No trailing period. No quotes. No markdown.
    Do not start with a label such as Commit, Subject, or WIP.
    Do not answer with only Update, Updates, Changes, Misc, Fix, Fixes, Cleanup, or Tweaks.
    When the diff has one purpose, name that purpose instead of listing files.
    Put the subject in subject. Put one or two sentences of explanation in detail, or leave detail empty when the subject already says the whole change.
    """

    static func body(
        repository: String,
        branch: String,
        files: [ChangedFile],
        diff: String,
        recentSubjects: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("Repository: \(repository)")
        lines.append("Branch: \(branch)")
        if recentSubjects.isEmpty {
            lines.append("Recent subjects: none")
        } else {
            lines.append("Recent subjects, oldest first:")
            for subject in recentSubjects {
                lines.append("- \(subject)")
            }
        }
        lines.append("Files:")
        if files.isEmpty {
            lines.append("- (none)")
        } else {
            for file in files {
                lines.append("- \(CommitMessage.fileLine(file))")
            }
        }
        lines.append("Diff:")
        lines.append(diff.isEmpty ? "(no textual diff)" : diff)
        lines.append("Write the commit message.")
        return lines.joined(separator: "\n")
    }
}
