import Foundation
import FoundationModels

/// Drafts commit messages with the on-device model that ships with macOS.
/// There is nothing to install, no account, and no setting.
enum CommitMessageGenerator {
    /// The on-device context window is small, so the evidence is trimmed to fit
    /// instead of being summarized by extra model passes.
    static let evidenceCharacters = 7_000

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
    ///
    /// This should always produce a draft. If the model overflows its context or
    /// declines the content, it tries again with less of the diff, down to just
    /// the file list.
    static func subject(
        repository: String,
        branch: String,
        files: [ChangedFile],
        generated: [ChangedFile] = [],
        diff: String,
        recentSubjects: [String],
        stagedOnly: Bool = false,
        onPartial: @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        if let reason = unavailableReason() { throw CommitNameError.unavailable(reason) }

        var lastFailure = CommitNameError.tooLarge
        var prompt = ""
        var message = ""
        var bulletLimit = 0
        let subjectStyle = CommitMessagePrompt.subjectStyle(from: recentSubjects)
        for budget in [evidenceCharacters, 4_500, 2_500, 1_000, 0] {
            try Task.checkCancellation()
            let fittedDiff = budget > 0 ? CommitDigest.fit(diff, budget: budget) : ""
            let attemptBulletLimit = CommitMessagePrompt.bulletLimit(
                forFileCount: files.count,
                hasMeaningfulDiff: CommitDigest.hasMeaningfulDiff(fittedDiff)
            )
            let attempt = CommitMessagePrompt.body(
                repository: repository,
                branch: branch,
                files: files,
                generated: generated,
                diff: fittedDiff,
                recentSubjects: recentSubjects,
                stagedOnly: stagedOnly
            )
            do {
                message = try await draft(
                    attempt,
                    bulletLimit: attemptBulletLimit,
                    subjectStyle: subjectStyle,
                    onPartial: onPartial
                )
                prompt = attempt
                bulletLimit = attemptBulletLimit
                break
            } catch let failure as CommitNameError where failure == .tooLarge || failure == .declined {
                lastFailure = failure
            }
        }
        if prompt.isEmpty { throw lastFailure }

        // One retry, only when the first subject says nothing ("Update files").
        // That subject was never shown, so the retry streams in as a fresh draft.
        if CommitMessage.isWeak(CommitMessage.subjectLine(message)) {
            message = try await draft("""
                \(prompt)

                A previous draft was too vague: \(CommitMessage.subjectLine(message))
                Make the subject specific, using only facts supported by the changes.
                """, bulletLimit: bulletLimit, subjectStyle: subjectStyle, onPartial: onPartial)
        }
        try Task.checkCancellation()
        let subject = CommitMessage.subjectLine(message)
        if subject.isEmpty { throw CommitNameError.empty }
        if CommitMessage.isWeak(subject) { throw CommitNameError.vague }
        return message
    }

    private static func draft(
        _ prompt: String,
        bulletLimit: Int,
        subjectStyle: CommitMessagePrompt.SubjectStyle,
        onPartial: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let session = LanguageModelSession(instructions: CommitMessagePrompt.instructions)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 600)
        var message = ""

        func publish(subject: String?, bullets: [String]?) async {
            message = CommitMessage.composed(
                subject: subject ?? "",
                bullets: bulletLimit > 0 ? (bullets ?? []) : [],
                style: subjectStyle,
                maxBullets: bulletLimit
            )
            if CommitMessage.isSafeToShow(partialSubject: CommitMessage.subjectLine(message)) {
                await onPartial(message)
            }
        }

        do {
            // Fields arrive in declaration order: key changes first so the subject
            // synthesizes every distinct part of the commit, then the subject line.
            switch bulletLimit {
            case ...0:
                for try await snapshot in session.streamResponse(to: prompt, generating: CommitSubjectOnlyDraft.self, options: options) {
                    await publish(subject: snapshot.content.subject, bullets: nil)
                }
            case 1, 2:
                for try await snapshot in session.streamResponse(to: prompt, generating: CommitDraft2.self, options: options) {
                    await publish(subject: snapshot.content.subject, bullets: snapshot.content.bullets)
                }
            case 3:
                for try await snapshot in session.streamResponse(to: prompt, generating: CommitDraft3.self, options: options) {
                    await publish(subject: snapshot.content.subject, bullets: snapshot.content.bullets)
                }
            case 4:
                for try await snapshot in session.streamResponse(to: prompt, generating: CommitDraft4.self, options: options) {
                    await publish(subject: snapshot.content.subject, bullets: snapshot.content.bullets)
                }
            default:
                for try await snapshot in session.streamResponse(to: prompt, generating: CommitDraft5.self, options: options) {
                    await publish(subject: snapshot.content.subject, bullets: snapshot.content.bullets)
                }
            }
            return message
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw CommitNameError.tooLarge
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            throw CommitNameError.declined
        }
    }
}

enum CommitNameError: Error, Equatable {
    case unavailable(String)
    case empty
    case vague
    case tooLarge
    /// The model's content safety check refused this text.
    case declined
}

// Field descriptions are plain labels on purpose: the on-device model copies
// constraint wording into the field ("at most 72 characters"). The rules are in
// `CommitMessagePrompt.instructions`.
@Generable
private struct CommitSubjectOnlyDraft {
    @Guide(description: "The commit subject line")
    var subject: String
}

@Generable
private struct CommitDraft2 {
    @Guide(description: "Key changes", .maximumCount(2))
    var bullets: [String]

    @Guide(description: "The commit subject line")
    var subject: String
}

@Generable
private struct CommitDraft3 {
    @Guide(description: "Key changes", .maximumCount(3))
    var bullets: [String]

    @Guide(description: "The commit subject line")
    var subject: String
}

@Generable
private struct CommitDraft4 {
    @Guide(description: "Key changes", .maximumCount(4))
    var bullets: [String]

    @Guide(description: "The commit subject line")
    var subject: String
}

@Generable
private struct CommitDraft5 {
    @Guide(description: "Key changes", .maximumCount(5))
    var bullets: [String]

    @Guide(description: "The commit subject line")
    var subject: String
}
