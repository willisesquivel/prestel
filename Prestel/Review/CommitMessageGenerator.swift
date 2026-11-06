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

    /// Writes the message, calling `onPartial` with the text so far as the model
    /// produces it. The return value is the finished, validated message.
    static func subject(
        repository: String,
        branch: String,
        files: [ChangedFile],
        diff: String,
        recentSubjects: [String],
        onPartial: @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        if let reason = unavailableReason() { throw CommitNameError.unavailable(reason) }

        let prompt = CommitMessagePrompt.body(
            repository: repository,
            branch: branch,
            files: files,
            diff: CommitDigest.fit(diff, budget: evidenceCharacters),
            recentSubjects: recentSubjects
        )
        var message = try await draft(prompt, onPartial: onPartial)
        // One retry, only when the first subject says nothing ("Update files").
        // That subject was never shown, so the retry streams in as a fresh draft.
        if CommitMessage.isWeak(CommitMessage.subjectLine(message)) {
            message = try await draft("""
                \(prompt)

                A previous draft was too vague: \(CommitMessage.subjectLine(message))
                Make the subject specific, using only facts supported by the changes.
                """, onPartial: onPartial)
        }
        try Task.checkCancellation()
        let subject = CommitMessage.subjectLine(message)
        if subject.isEmpty { throw CommitNameError.empty }
        if CommitMessage.isWeak(subject) { throw CommitNameError.vague }
        return message
    }

    private static func draft(
        _ prompt: String,
        onPartial: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let session = LanguageModelSession(instructions: CommitMessagePrompt.instructions)
        var message = ""
        do {
            let stream = session.streamResponse(
                to: prompt,
                generating: CommitSubjectDraft.self,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 600)
            )
            // Fields arrive in declaration order: the subject first, then the body.
            // The last snapshot is the complete draft.
            for try await snapshot in stream {
                message = CommitMessage.composed(
                    subject: snapshot.content.subject ?? "",
                    detail: snapshot.content.detail ?? ""
                )
                if CommitMessage.isSafeToShow(partialSubject: CommitMessage.subjectLine(message)) {
                    await onPartial(message)
                }
            }
            return message
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
