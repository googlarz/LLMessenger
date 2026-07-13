import Foundation

enum BriefEngineValidationError: Error {
    case emptyCards
    case wrongService(cardId: String, service: String)
    case missingSourceMessageIds(cardId: String)
    case unknownSourceMessageId(cardId: String, messageId: String)
    case unknownQuoteMessageId(cardId: String, messageId: String)
}

/// Converts untrusted model output into grounded domain records. Keeping this
/// boundary pure makes validation independently testable and keeps database
/// orchestration out of the model-response path.
enum BriefOutputProcessor {
    static func decodeAndValidate(
        _ text: String,
        service: String,
        sourceMessages: [Message]
    ) throws -> BriefJSON {
        let cleanText = BriefJSON.extractJSONPayload(from: text)
        guard let data = cleanText.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid UTF-8")
            )
        }
        let parsed = try JSONDecoder().decode(BriefJSON.self, from: data)
        guard !parsed.cards.isEmpty else { throw BriefEngineValidationError.emptyCards }

        let sourceMessagesByID = Dictionary(
            sourceMessages.map { ($0.messageId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var validCards: [BriefCard] = []
        for card in parsed.cards {
            guard card.service == service else {
                print("[BriefOutputProcessor] skipping card \(card.id): wrong service \(card.service)")
                continue
            }

            let validSourceIDs = card.sourceMessageIds.filter { messageID in
                guard !messageID.isEmpty, let source = sourceMessagesByID[messageID] else {
                    return false
                }
                return source.conversationId == card.conversationId
            }
            let droppedCount = card.sourceMessageIds.count - validSourceIDs.count
            if droppedCount > 0 {
                print("[BriefOutputProcessor] card \(card.id): dropped \(droppedCount) unknown sourceMessageIds")
            }
            guard !validSourceIDs.isEmpty else {
                print("[BriefOutputProcessor] skipping card \(card.id): no valid sourceMessageIds")
                continue
            }

            let validQuotes = card.quotes.filter { quote in
                guard let messageID = quote.messageId,
                      let source = sourceMessagesByID[messageID] else { return false }
                return source.conversationId == card.conversationId
            }
            if validQuotes.count < card.quotes.count {
                print("[BriefOutputProcessor] card \(card.id): dropped \(card.quotes.count - validQuotes.count) unknown quotes")
            }

            validCards.append(BriefCard(
                id: card.id,
                service: card.service,
                conversationId: card.conversationId,
                conversationTitle: card.conversationTitle,
                headline: card.headline,
                priority: card.priority,
                counts: card.counts,
                summary: card.summary,
                callback: card.callback,
                needsReply: card.needsReply,
                reason: card.reason,
                grounding: card.grounding,
                actionItems: card.actionItems,
                quotes: validQuotes,
                sourceMessageIds: validSourceIDs,
                collapsed: card.collapsed
            ))
        }

        guard !validCards.isEmpty else { throw BriefEngineValidationError.emptyCards }
        return BriefJSON(
            totalMessages: parsed.totalMessages,
            totalThreads: parsed.totalThreads,
            totalPeople: parsed.totalPeople,
            cards: validCards
        )
    }

    static func buildCardRecords(
        _ cards: [BriefCard],
        briefID: Int64,
        sourceMessagesByService: [String: [String: Message]],
        now: Date = Date()
    ) throws -> (cardRecords: [BriefCardRecord], sources: [BriefCardSource]) {
        var cardRecords: [BriefCardRecord] = []
        var allSources: [BriefCardSource] = []

        for (position, card) in cards.enumerated() {
            // LLM card IDs are logical identities and can repeat between runs.
            // Database rows need a fresh physical identity for every brief.
            let cardID = UUID().uuidString
            guard !card.sourceMessageIds.isEmpty else {
                print("[BriefOutputProcessor] skipping \(card.service)/\(card.conversationId): no source message IDs")
                continue
            }

            let record = BriefCardRecord(
                id: cardID,
                briefId: briefID,
                service: card.service,
                conversationId: card.conversationId,
                conversationTitle: card.conversationTitle,
                headline: card.headline,
                priority: card.priority,
                summary: card.summary,
                needsReply: card.needsReply,
                reason: card.reason,
                grounding: card.grounding,
                actionItems: try encode(card.actionItems),
                callbackText: card.callback,
                sourceMessageIds: try encode(card.sourceMessageIds),
                createdAt: now,
                logicalId: card.id,
                position: position,
                messageCount: card.counts.messages,
                threadCount: card.counts.threads,
                peopleCount: card.counts.people,
                quotes: try encode(card.quotes),
                collapsed: card.collapsed
            )

            let quoteMessageIDs = Set(card.quotes.compactMap(\.messageId))
            let sources = card.sourceMessageIds.map { messageID in
                let message = sourceMessagesByService[card.service]?[messageID]
                let quote = card.quotes.first { $0.messageId == messageID }
                return BriefCardSource(
                    id: nil,
                    briefCardId: cardID,
                    messageRowId: message?.id,
                    service: card.service,
                    messageId: messageID,
                    sourceRole: quoteMessageIDs.contains(messageID)
                        ? BriefCardSourceRole.quote.rawValue
                        : BriefCardSourceRole.newMessage.rawValue,
                    quoteText: quote?.text,
                    createdAt: now
                )
            }

            cardRecords.append(record)
            allSources.append(contentsOf: sources)
        }

        return (cardRecords, allSources)
    }

    static func encodeBriefJSON(_ briefJSON: BriefJSON) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encode(briefJSON, using: encoder)
    }

    private static func encode<Value: Encodable>(
        _ value: Value,
        using encoder: JSONEncoder = JSONEncoder()
    ) throws -> String {
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: [], debugDescription: "Unable to encode UTF-8 JSON")
            )
        }
        return json
    }
}
