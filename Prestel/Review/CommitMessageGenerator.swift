import Foundation
import FoundationModels

/// Drafts commit messages with the on-device model that ships with macOS.
/// There is nothing to install, no account, and no setting.
enum CommitMessageGenerator {
    /// The on-device context window is small, so the evidence is trimmed to fit
    /// instead of being summarized by extra model passes.
    static let evidenceCharacters = 5_000

    static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            if SystemLanguageModel.default.supportsLocale() { return nil }
            return "The on-device model does not support the current language."
        case .unavailable(.deviceNotEligible):
            return "Drafting needs a Mac with Apple Silicon."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to draft a commit message."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading."
        @unknown default:
            return "The on-device model is not available."
        }
    }

    /// Loads the model ahead of the first Draft so the first draft is not slower
    /// than the rest.
    static func prewarm() {
        guard unavailableReason() == nil else { return }
        LanguageModelSession(instructions: CommitMessagePrompt.instructions).prewarm()
    }

    static func subject(
        repository: String,
        branch: String,
        files: [ChangedFile],
        diff: String,
        recentSubjects: [String]
    ) async throws -> String {
        if let reason = unavailableReason() { throw CommitNameError.unavailable(reason) }

        let prompt = CommitMessagePrompt.body(
            repository: repository,
            branch: branch,
            files: files,
            diff: CommitDigest.fit(diff, budget: evidenceCharacters),
            recentSubjects: recentSubjects
        )
        var message = try await draft(prompt)
        // One retry, only when the first subject says nothing ("Update files").
        if CommitMessage.isWeak(CommitMessage.subjectLine(message)) {
            message = try await draft("""
                \(prompt)

                A previous draft was too vague: \(CommitMessage.subjectLine(message))
                Make the subject specific, using only facts supported by the changes.
                """)
        }
        try Task.checkCancellation()
        let subject = CommitMessage.subjectLine(message)
        if subject.isEmpty { throw CommitNameError.empty }
        if CommitMessage.isWeak(subject) { throw CommitNameError.vague }
        return message
    }

    private static func draft(_ prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: CommitMessagePrompt.instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                generating: CommitSubjectDraft.self,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 600)
            )
            return CommitMessage.composed(subject: response.content.subject, detail: response.content.detail)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw CommitNameError.tooLarge
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            throw CommitNameError.unavailable("The on-device model declined to describe this change. Write the message manually.")
        }
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

    @Guide(description: "A short factual body: one sentence for a small change, or at most four concrete bullet points for a larger one. Do not repeat the subject, invent motives or claim unshown tests.")
    var detail: String
}
