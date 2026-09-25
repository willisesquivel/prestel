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
        let engine: CommitDraftEngine
        if let model = await OllamaCommitModel.availableModel() {
            engine = .ollama(model)
        } else {
            if let reason = unavailableReason() { throw CommitNameError.unavailable(reason) }
            engine = .apple
        }

        let evidence = CommitMessagePrompt.body(
            repository: repository,
            branch: branch,
            files: files,
            diff: diff,
            recentSubjects: recentSubjects
        )
        let prompt = try await condensedEvidence(evidence, using: engine)
        try Task.checkCancellation()
        var draft = try await engine.draft(prompt)
        var message = CommitMessage.composed(subject: draft.subject, detail: draft.detail)
        var subject = CommitMessage.subjectLine(message)
        if subject.isEmpty { throw CommitNameError.empty }
        let substantial = diff.count > 1_500 || files.count >= 3
        if CommitMessage.isWeak(subject) || (substantial && draft.detail.trimmingCharacters(in: .whitespacesAndNewlines).count < 80) {
            let bodyGuidance = substantial
                ? "Explain the major changes in concrete body bullets."
                : "Use a brief body only if it adds a useful fact."
            draft = try await engine.draft("""
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
            if let checked = try? await engine.draft(auditPrompt) {
                let verified = CommitMessage.composed(subject: checked.subject, detail: checked.detail)
                if !CommitMessage.isWeak(CommitMessage.subjectLine(verified)) { message = verified }
            }
        }
        try Task.checkCancellation()
        return message
    }

    private static func condensedEvidence(_ evidence: String, using engine: CommitDraftEngine) async throws -> String {
        let budget = engine.promptCharacters
        if evidence.count <= budget { return evidence }
        var text = evidence
        while text.count > budget - 200 {
            let parts = CommitDigest.chunks(text, budget: budget - 500)
            var summaries: [String] = []
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                let summary = try await engine.summarize("""
                    Summarize part \(index + 1) of \(parts.count) of a git change. Keep concrete names and behavior, including any tests or compatibility changes. Do not invent intent. Limit the answer to 250 words. This is evidence for a commit message, not the message itself.

                    \(part)
                    """)
                summaries.append("Part \(index + 1) of \(parts.count):\n\(summary)")
            }
            let reduced = summaries.joined(separator: "\n\n")
            guard reduced.count < text.count else { throw CommitNameError.tooLarge }
            text = reduced
        }
        return "Summaries of every part of the change:\n\(text)\n\nWrite the commit message from these summaries."
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

private enum CommitDraftEngine {
    case apple
    case ollama(String)

    var promptCharacters: Int {
        switch self {
        case .apple: 6_000
        case .ollama: 40_000
        }
    }

    func summarize(_ prompt: String) async throws -> String {
        switch self {
        case .apple:
            let session = LanguageModelSession(instructions: "Summarize git changes precisely. Preserve file names, identifiers, behavior, and tests. Write only the summary.")
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 400))
            return response.content
        case .ollama(let model):
            return try await OllamaCommitModel.chat(
                model: model,
                system: "Summarize git changes precisely. Preserve file names, identifiers, behavior, and tests. Write only the summary.",
                prompt: prompt,
                json: false,
                responseTokens: 400
            )
        }
    }

    func draft(_ prompt: String) async throws -> (subject: String, detail: String) {
        switch self {
        case .apple:
            let session = LanguageModelSession(instructions: CommitMessagePrompt.instructions)
            let response = try await session.respond(
                to: prompt,
                generating: CommitSubjectDraft.self,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 800)
            )
            return (response.content.subject, response.content.detail)
        case .ollama(let model):
            let content = try await OllamaCommitModel.chat(
                model: model,
                system: CommitMessagePrompt.instructions + "\nReturn a JSON object with string keys subject and detail, with no other text.",
                prompt: prompt,
                json: true,
                responseTokens: 800
            )
            let draft = try JSONDecoder().decode(OllamaCommitModel.Draft.self, from: Data(content.utf8))
            return (draft.subject, draft.detail)
        }
    }
}

enum OllamaCommitModel {
    struct Draft: Decodable {
        let subject: String
        let detail: String
    }

    private struct Tags: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    private struct Response: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }

    private static let endpoint = URL(string: "http://127.0.0.1:11434")!

    static func availableModel() async -> String? {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let names = try? JSONDecoder().decode(Tags.self, from: data).models.map(\.name) else {
            return nil
        }
        return preferredModel(in: names)
    }

    static func preferredModel(in names: [String]) -> String? {
        let preferred = ["qwen3-coder:30b", "qwen3-coder:latest", "gpt-oss-20b:latest", "gpt-oss:20b", "gpt-oss:latest"]
        for model in preferred where names.contains(model) { return model }
        return names.first { $0.lowercased().contains("coder") && !$0.lowercased().contains("cloud") }
    }

    static func chat(model: String, system: String, prompt: String, json: Bool, responseTokens: Int) async throws -> String {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt]
            ],
            "options": ["temperature": 0.2, "num_ctx": 32_768, "num_predict": responseTokens]
        ]
        if model.lowercased().contains("gpt-oss") {
            body["think"] = "low"
        } else {
            body["think"] = false
        }
        if json {
            body["format"] = [
                "type": "object",
                "properties": ["subject": ["type": "string"], "detail": ["type": "string"]],
                "required": ["subject", "detail"]
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CommitNameError.unavailable("The local Ollama model could not draft this commit.") }
        let content = try JSONDecoder().decode(Response.self, from: data).message.content
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommitNameError.empty }
        return content
    }
}
