import Foundation

struct BriefConversationPromptMetadata {
    var context: ConversationContext?
    var state: ConversationState?
    var previousCard: BriefCardRecord?
}

/// Pure prompt-boundary helpers. User-controlled metadata and messages are
/// sanitized here before they enter the structured summarization prompt.
enum BriefPromptAssembler {
    static func isExcludedByPrivacy(
        context: ConversationContext?,
        clientIsCloud: Bool
    ) -> Bool {
        if context?.privacyOverride == "never_draft" { return true }
        if context?.privacyOverride == "local_only", clientIsCloud { return true }
        return false
    }

    static func buildConversationBlock(
        service: String,
        conversationID: String,
        conversationTitle: String,
        newMessages: [Message],
        omittedNewMessageCount: Int,
        recentContextMessages: [Message],
        metadataCharacterLimit: Int? = nil,
        promptMetadata: BriefConversationPromptMetadata,
        dateFormatter: DateFormatter,
        senderNameResolver: (String) -> String
    ) -> String {
        func bounded(_ value: String) -> String {
            let sanitized = inline(value)
            guard let metadataCharacterLimit, sanitized.count > metadataCharacterLimit else {
                return sanitized
            }
            return String(sanitized.prefix(metadataCharacterLimit))
        }

        let safeConversationID = bounded(conversationID)
        let safeTitle = bounded(conversationTitle)
        guard !newMessages.isEmpty else {
            return "=== [\(service)] \(safeConversationID) | \(safeTitle) ==="
        }

        var lines = ["=== [\(service)] \(safeConversationID) | \(safeTitle) ==="]
        if let context = promptMetadata.context {
            var contextParts: [String] = []
            if !context.label.isEmpty {
                contextParts.append(bounded(context.label))
            }
            if context.priorityHint != "auto" {
                contextParts.append("priority override: \(bounded(context.priorityHint))")
            }
            if !contextParts.isEmpty {
                lines.append("Context: \(contextParts.joined(separator: " · "))")
            }
        }

        if let summary = promptMetadata.state?.rollingSummary, !summary.isEmpty {
            lines.append("Previous summary: \(bounded(summary))")
        }
        if let headline = promptMetadata.previousCard?.headline, !headline.isEmpty {
            lines.append("Previous brief card: \(bounded(headline))")
        }
        if let unresolved = promptMetadata.state?.unresolvedActions, !unresolved.isEmpty {
            lines.append("Unresolved actions from prior brief: \(bounded(unresolved))")
        }
        if !recentContextMessages.isEmpty {
            lines.append("[Recent context before new messages]")
            lines.append(contentsOf: recentContextMessages.map {
                messageLine($0, dateFormatter: dateFormatter, senderNameResolver: senderNameResolver)
            })
        }
        if omittedNewMessageCount > 0 {
            lines.append("[\(omittedNewMessageCount) earlier new messages omitted]")
        }
        lines.append("[New messages]")
        lines.append(contentsOf: newMessages.map {
            messageLine($0, dateFormatter: dateFormatter, senderNameResolver: senderNameResolver)
        })
        return lines.joined(separator: "\n")
    }

    static func boundedPromptMessage(_ message: Message, tokenBudget: Int) -> Message {
        var copy = message
        copy.text = TokenEstimator.truncated(message.text, toTokenBudget: tokenBudget)
        return copy
    }

    static func messageSortAscending(_ lhs: Message, _ rhs: Message) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.messageId != rhs.messageId {
            return lhs.messageId < rhs.messageId
        }
        return (lhs.id ?? 0) < (rhs.id ?? 0)
    }

    private static func messageLine(
        _ message: Message,
        dateFormatter: DateFormatter,
        senderNameResolver: (String) -> String
    ) -> String {
        let senderLabel = message.isSent ? "YOU" : inline(senderNameResolver(message.sender))
        let safeText = inline(message.text)
        return "[id=\(message.messageId) | \(dateFormatter.string(from: message.timestamp))] \(senderLabel): \(safeText)"
    }

    /// Prompt records are line-oriented. Escaping line breaks prevents message
    /// content from forging conversation headers or additional source records.
    private static func inline(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "===", with: "—")
            .replacingOccurrences(of: "\0", with: "")
    }
}
