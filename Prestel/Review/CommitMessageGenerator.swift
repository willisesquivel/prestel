import Foundation
import FoundationModels

enum CommitMessageGenerator {
    static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            if SystemLanguageModel.default.supportsLocale() { return nil }
            return "The on-device model does not support the current language."
        case .unavailable(.deviceNotEligible):
            return "This Mac cannot run the on-device model."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence to draft a commit message on this Mac."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading."
        @unknown default:
            return "The on-device model is not available."
        }
    }

    static func subject(
        repository: String,
        branch: String,
        files: [ChangedFile],
        diff: String,
        recentSubjects: [String]
    ) async throws -> String {
        if let reason = unavailableReason() { throw CommitNameError.unavailable(reason) }

        let header = CommitMessagePrompt.header(
            repository: repository,
            branch: branch,
            files: files,
            recentSubjects: recentSubjects,
            fileLimit: max(12, promptCharacters / 300)
        )
        let prompt = try await evidencePrompt(header: header, diff: diff)
        try Task.checkCancellation()
        var draft = try await Self.draft(prompt)
        var message = CommitMessage.composed(subject: draft.subject, detail: draft.detail)
        var subject = CommitMessage.subjectLine(message)
        if subject.isEmpty { throw CommitNameError.empty }
        let substantial = diff.count > 1_500 || files.count >= 3
        if CommitMessage.isWeak(subject) || (substantial && draft.detail.trimmingCharacters(in: .whitespacesAndNewlines).count < 80) {
            let bodyGuidance = substantial
                ? "Explain the major changes in concrete body bullets."
                : "Use a brief body only if it adds a useful fact."
            draft = try await Self.draft("""
                \(prompt)

                Revise this draft. Subject: \(subject). Body: \(draft.detail)
                Make the subject specific. \(bodyGuidance) Use only facts supported by the changes.
                """)
            message = CommitMessage.composed(subject: draft.subject, detail: draft.detail)
            subject = CommitMessage.subjectLine(message)
        }
        guard !subject.isEmpty, !CommitMessage.isWeak(subject) else { throw CommitNameError.vague }
        if substantial {
            let auditPrompt = """
                \(prompt)

                Proposed message:
                \(message)

                Check every claim in the proposed message against the supplied changes. Remove or rewrite claims that the changes do not support, including claims about tests or documentation when their changes are not shown. Keep the accurate specifics and return the corrected message.
                """
            if let checked = try? await Self.draft(auditPrompt) {
                let verified = CommitMessage.composed(subject: checked.subject, detail: checked.detail)
                if !CommitMessage.isWeak(CommitMessage.subjectLine(verified)) { message = verified }
            }
        }
        try Task.checkCancellation()
        return message
    }

    /// The draft prompt. The condensed changes go in whole when they fit;
    /// otherwise they are summarized in at most about `summaryParts` passes,
    /// sized so the summaries fit the draft in one round.
    private static func evidencePrompt(header: String, diff: String) async throws -> String {
        let budget = promptCharacters
        let room = budget - header.count - 200
        let blocks = CommitEvidence.blocks(from: diff, budget: (budget - 220) * summaryParts)
        let full = blocks.joined(separator: "\n")
        var changes = full
        if changes.count > room, room > 0, changes.count <= room * 3 / 2 {
            // Slightly over: an outline of every file beats summaries of it.
            changes = CommitEvidence.blocks(from: diff, budget: room * 9 / 10).joined(separator: "\n")
        }
        if changes.count <= room {
            return CommitMessagePrompt.body(header: header, changes: changes, summarized: false)
        }
        var pieces = blocks
        var size = full.count
        while true {
            let parts = CommitEvidence.parts(pieces, budget: budget)
            let words = min(200, max(40, room / max(1, parts.count) / 7))
            var summaries: [String] = []
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                let summary = try await summarize("""
                    Summarize part \(index + 1) of \(parts.count) of a git change. Keep concrete names and behavior, including any tests or compatibility changes. Do not invent intent. Limit the answer to \(words) words. This is evidence for a commit message, not the message itself.

                    \(part)
                    """, words: words)
                summaries.append("Part \(index + 1) of \(parts.count):\n\(summary)")
            }
            let reduced = summaries.joined(separator: "\n\n")
            if reduced.count <= room {
                return CommitMessagePrompt.body(header: header, changes: reduced, summarized: true)
            }
            guard reduced.count < size else { throw CommitNameError.tooLarge }
            pieces = summaries
            size = reduced.count
        }
    }

    /// Prompt characters that leave room for the instructions and the answer.
    /// 6,000 fits the 4,096-token model; larger on-device contexts scale it.
    private static var promptCharacters: Int {
        6_000 * max(4_096, SystemLanguageModel.default.contextSize) / 4_096
    }

    /// Summary passes before the draft. Condensing caps the evidence at this
    /// many prompts, so a huge commit costs about as much as a large one.
    private static let summaryParts = 8

    private static func summarize(_ prompt: String, words: Int) async throws -> String {
        let session = LanguageModelSession(instructions: "Summarize git changes precisely. Preserve file names, identifiers, behavior, and tests. Write only the summary.")
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(temperature: 0.1, maximumResponseTokens: words * 2 + 60)
        )
        return response.content
    }

    private static func draft(_ prompt: String) async throws -> (subject: String, detail: String) {
        let session = LanguageModelSession(instructions: CommitMessagePrompt.instructions)
        let response = try await session.respond(
            to: prompt,
            generating: CommitSubjectDraft.self,
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 800)
        )
        return (response.content.subject, response.content.detail)
    }
}

enum CommitNameError: Error, Equatable {
    case unavailable(String)
    case empty
    case vague
    case tooLarge
}

@Generable
struct CommitSubjectDraft {
    @Guide(description: "One specific git commit subject of at most 72 characters. No trailing period, quotes, or label.")
    var subject: String

    @Guide(description: "A factual body. Explain substantial changes in several concrete bullet points; use one sentence for a small change. Do not repeat the subject, invent motives or claim unshown tests.")
    var detail: String
}
