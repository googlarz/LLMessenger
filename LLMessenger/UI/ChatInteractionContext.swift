import Foundation

struct ChatConversationRef: Equatable {
    let number: Int
    let service: String
    let convId: String
    let name: String
}

struct ChatBriefCardRef {
    let number: Int
    let card: BriefCard
}

struct ChatDraftRef: Equatable {
    let number: Int
    let id: UUID
    let draft: ReplyDraft
}

struct ChatInteractionContext {
    let conversations: [ChatConversationRef]
    let cards: [ChatBriefCardRef]
    let drafts: [ChatDraftRef]
    let messages: [Message]

    init(brief: Brief,
         messages: [Message],
         threadItems: [ThreadItem],
         conversationTuples: [(service: String, convId: String, name: String)]) {
        self.conversations = conversationTuples.enumerated().map { index, conv in
            ChatConversationRef(number: index + 1,
                                service: conv.service,
                                convId: conv.convId,
                                name: conv.name)
        }
        self.cards = Self.decodeCards(from: brief).enumerated().map { index, card in
            ChatBriefCardRef(number: index + 1, card: card)
        }
        self.drafts = threadItems.compactMap { item -> (UUID, ReplyDraft)? in
            if case .replyDraft(let id, let draft) = item {
                return (id, draft)
            }
            return nil
        }
        .enumerated()
        .map { index, entry in
            ChatDraftRef(number: index + 1, id: entry.0, draft: entry.1)
        }
        self.messages = messages
    }

    var routerPromptContext: IntentRouterPromptContext {
        IntentRouterPromptContext(
            conversations: conversations.map {
                "\(Theme.serviceName($0.service)) — \($0.name) [service=\($0.service), conversationId=\($0.convId)]"
            },
            cards: cards.map {
                let card = $0.card
                let label = card.conversationTitle ?? card.conversationId
                return "\(card.headline) — \(label) [service=\(card.service), conversationId=\(card.conversationId), priority=\(card.priority)]"
            },
            drafts: drafts.map {
                let target = conversationName(service: $0.draft.serviceID, convId: $0.draft.conversationID)
                    ?? $0.draft.conversationID
                return "Draft to \(target): \($0.draft.text)"
            }
        )
    }

    func conversation(for action: IntentAction) -> ChatConversationRef? {
        if let number = action.conversationNumber {
            return conversations.first { $0.number == number }
        }
        if let card = card(for: action) {
            return conversations.first {
                $0.service == card.card.service && $0.convId == card.card.conversationId
            }
        }
        guard let target = normalized(action.targetName) else { return nil }
        let matches = conversations(matching: target)
        return matches.count == 1 ? matches[0] : nil
    }

    func conversations(matching targetName: String) -> [ChatConversationRef] {
        let needle = normalized(targetName)?.lowercased() ?? ""
        guard !needle.isEmpty else { return [] }
        return conversations.filter { conv in
            conv.name.lowercased().contains(needle)
                || conv.convId.lowercased().contains(needle)
                || Theme.serviceName(conv.service).lowercased().contains(needle)
        }
    }

    func card(for action: IntentAction) -> ChatBriefCardRef? {
        if let number = action.cardNumber {
            return cards.first { $0.number == number }
        }
        if let number = action.conversationNumber,
           let conversation = conversations.first(where: { $0.number == number }) {
            return cards.first {
                $0.card.service == conversation.service && $0.card.conversationId == conversation.convId
            }
        }
        guard let target = normalized(action.targetName) else { return nil }
        let matches = cards.filter { cardRef in
            let card = cardRef.card
            return card.headline.lowercased().contains(target.lowercased())
                || card.conversationId.lowercased().contains(target.lowercased())
                || (card.conversationTitle?.lowercased().contains(target.lowercased()) ?? false)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func draft(for action: IntentAction) -> ChatDraftRef? {
        if let number = action.draftNumber {
            return drafts.first { $0.number == number }
        }
        if let target = normalized(action.targetName) {
            let matches = drafts.filter { draftRef in
                let draft = draftRef.draft
                let convName = conversationName(service: draft.serviceID, convId: draft.conversationID) ?? ""
                return draft.conversationID.lowercased().contains(target.lowercased())
                    || convName.lowercased().contains(target.lowercased())
            }
            if matches.count == 1 {
                return matches[0]
            }
        }
        // Only one draft open and the action carries no number/name — safe to resolve unambiguously.
        if drafts.count == 1 { return drafts[0] }
        // Ambiguous (0 or 2+ drafts): return nil so callers can ask the user to clarify.
        return nil
    }

    func sourceMessages(for card: ChatBriefCardRef) -> [Message] {
        let ids = Set(card.card.sourceMessageIds)
        guard !ids.isEmpty else { return [] }
        return messages.filter {
            $0.service == card.card.service
                && $0.conversationId == card.card.conversationId
                && ids.contains($0.messageId)
        }
    }

    func conversationMessages(for conversation: ChatConversationRef) -> [Message] {
        messages.filter {
            $0.service == conversation.service && $0.conversationId == conversation.convId
        }
    }

    private func conversationName(service: String, convId: String) -> String? {
        conversations.first { $0.service == service && $0.convId == convId }?.name
    }

    private static func decodeCards(from brief: Brief) -> [BriefCard] {
        BriefJSON.decodeLenient(from: brief.openingSummary)?.cards ?? []
    }

    private func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
