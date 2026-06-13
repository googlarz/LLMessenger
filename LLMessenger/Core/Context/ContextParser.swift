// LLMessenger/Core/Context/ContextParser.swift
import Foundation

/// Turns a freeform user sentence describing a conversation into structured
/// ConversationContext fields via a fixed JSON-extraction LLM prompt.
/// The sentence is user-authored (trusted); a clear system instruction is enough.
struct ContextParser {
    let llmClient: any LLMClient

    func parse(
        sentence: String,
        service: String,
        conversationId: String,
        existing: ConversationContext?,
        model: String
    ) async throws -> ConversationContext {
        let prompt = """
        Extract conversation metadata from the user's sentence. Output ONLY valid JSON — \
        no markdown fences, no prose. Use this exact schema, omitting nothing:
        {
          "relationship": "<short relationship label, or empty string>",
          "importantTopics": ["<topic>", ...],
          "noiseTopics": ["<topic to ignore>", ...],
          "keySenders": ["<name of a sender that matters most>", ...],
          "priorityHint": "auto"|"high"|"med"|"low",
          "contextNote": "<one-sentence note, or empty string>",
          "responseExpectation": "<e.g. fast, evening ok, no reply needed, or empty string>"
        }

        Rules:
        - Only extract what the sentence states. Use empty values when unstated.
        - priorityHint defaults to "auto" unless the user clearly wants this conversation
          always high or always low.

        Sentence:
        \(sentence)
        """

        let response = try await llmClient.complete(
            model: model,
            messages: [LLMMessage(role: .user, content: prompt)],
            maxTokens: 400
        )
        let parsed = try parseJSON(response.text)
        return merge(parsed, onto: existing, service: service, conversationId: conversationId)
    }

    private struct ParsedFields {
        var relationship: String?
        var importantTopics: [String]
        var noiseTopics: [String]
        var keySenders: [String]
        var priorityHint: String?
        var contextNote: String?
        var responseExpectation: String?
    }

    private func parseJSON(_ text: String) throws -> ParsedFields {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw LLMError.invalidResponse }

        func string(_ key: String) -> String? {
            guard let v = json[key] as? String, !v.isEmpty else { return nil }
            return v
        }
        func array(_ key: String) -> [String] {
            (json[key] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
        }
        let validHints = ["auto", "high", "med", "low"]
        let hint = string("priorityHint").flatMap { validHints.contains($0) ? $0 : nil }

        return ParsedFields(
            relationship: string("relationship"),
            importantTopics: array("importantTopics"),
            noiseTopics: array("noiseTopics"),
            keySenders: array("keySenders"),
            priorityHint: hint,
            contextNote: string("contextNote"),
            responseExpectation: string("responseExpectation")
        )
    }

    /// Merges parsed fields onto an existing context. Parsed values win when present;
    /// nil/empty parsed values preserve the existing field rather than clobbering it.
    private func merge(
        _ parsed: ParsedFields,
        onto existing: ConversationContext?,
        service: String,
        conversationId: String
    ) -> ConversationContext {
        var ctx = ConversationContext(
            service: service,
            conversationId: conversationId,
            label: existing?.label ?? "",
            priorityHint: parsed.priorityHint ?? existing?.priorityHint ?? "auto",
            updatedAt: Date(),
            relationship: parsed.relationship ?? existing?.relationship,
            contextNote: parsed.contextNote ?? existing?.contextNote,
            responseExpectation: parsed.responseExpectation ?? existing?.responseExpectation,
            privacyOverride: existing?.privacyOverride
        )
        ctx.importantTopicsList = parsed.importantTopics.isEmpty
            ? (existing?.importantTopicsList ?? [])
            : parsed.importantTopics
        ctx.noiseTopicsList = parsed.noiseTopics.isEmpty
            ? (existing?.noiseTopicsList ?? [])
            : parsed.noiseTopics
        ctx.keySendersList = parsed.keySenders.isEmpty
            ? (existing?.keySendersList ?? [])
            : parsed.keySenders
        return ctx
    }
}
