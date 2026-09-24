import Foundation
import FoundationModels

/// On-device Apple Intelligence model. Drafting a name does not call the network.
enum CommitMessageGenerator {
    static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            if SystemLanguageModel.default.supportsLocale() { return nil }
            return "The on-device model does not support the current language."
        case .unavailable(.deviceNotEligible):
            return "This Mac cannot run the on-device model."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence to draft a commit name on this Mac."
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
        if let reason = unavailableReason() {
            throw CommitNameError.unavailable(reason)
        }
        let prompt = CommitMessagePrompt.body(
            repository: repository,
            branch: branch,
            files: files,
            diff: diff,
            recentSubjects: recentSubjects
        )
        let session = LanguageModelSession(instructions: CommitMessagePrompt.instructions)
        session.prewarm()
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 360)
        let first = try await session.respond(to: prompt, generating: CommitSubjectDraft.self, options: options)
        let drafted = CommitMessage.composed(subject: first.content.subject, detail: first.content.detail)
        let subject = CommitMessage.subjectLine(drafted)
        if subject.isEmpty { throw CommitNameError.empty }
        guard CommitMessage.isWeak(subject) else { return drafted }
        let retry = """
        \(prompt)

        The draft "\(subject)" does not say what changed. Write a specific replacement.
        """
        let second = try await session.respond(to: retry, generating: CommitSubjectDraft.self, options: options)
        let better = CommitMessage.composed(subject: second.content.subject, detail: second.content.detail)
        if !CommitMessage.subjectLine(better).isEmpty, !CommitMessage.isWeak(CommitMessage.subjectLine(better)) {
            return better
        }
        throw CommitNameError.vague
    }
}

enum CommitNameError: Error, Equatable {
    case unavailable(String)
    case empty
    case vague
}

@Generable
struct CommitSubjectDraft {
    @Guide(description: "One commit subject of at most 72 characters. Name the change. No trailing period. No surrounding quotes.")
    var subject: String

    @Guide(description: "One or two sentences explaining the change. Empty when the subject already says it. No label and no markdown.")
    var detail: String
}
