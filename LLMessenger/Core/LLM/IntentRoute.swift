import Foundation

enum IntentActionType: String, Codable, Equatable {
    case answer
    case draftReply = "draft_reply"
    case reviseDraft = "revise_draft"
    case sendDraftRequest = "send_draft_request"
    case showSources = "show_sources"
    case listActions = "list_actions"
    case findWaitingReplies = "find_waiting_replies"
    case summarizeChanges = "summarize_changes"
    case extractTasks = "extract_tasks"
    case compareConversations = "compare_conversations"
    // Agent-queue commands (P5): map a natural-language command to an operation
    // against the agent queue, not just a Q&A answer.
    case catchMeUp = "catch_me_up"
    case handleEasy = "handle_easy"
    case whatDoIOwe = "what_do_i_owe"
    case draftAllWaiting = "draft_all_waiting"
    case clarify
    case unknown
}

struct IntentRoute: Codable, Equatable {
    let actions: [IntentAction]
}

struct IntentAction: Codable, Equatable {
    let type: IntentActionType
    let conversationNumber: Int?
    let cardNumber: Int?
    let draftNumber: Int?
    let targetName: String?
    let message: String?
    let question: String?
    let instruction: String?

    init(type: IntentActionType,
         conversationNumber: Int? = nil,
         cardNumber: Int? = nil,
         draftNumber: Int? = nil,
         targetName: String? = nil,
         message: String? = nil,
         question: String? = nil,
         instruction: String? = nil) {
        self.type = type
        self.conversationNumber = conversationNumber
        self.cardNumber = cardNumber
        self.draftNumber = draftNumber
        self.targetName = targetName
        self.message = message
        self.question = question
        self.instruction = instruction
    }

    enum CodingKeys: String, CodingKey {
        case type
        case conversationNumber
        case cardNumber
        case draftNumber
        case targetName
        case message
        case question
        case instruction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        type = IntentActionType(rawValue: Self.normalizeType(rawType)) ?? .unknown
        conversationNumber = try container.decodeIfPresent(Int.self, forKey: .conversationNumber)
        cardNumber = try container.decodeIfPresent(Int.self, forKey: .cardNumber)
        draftNumber = try container.decodeIfPresent(Int.self, forKey: .draftNumber)
        targetName = try container.decodeIfPresent(String.self, forKey: .targetName)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        question = try container.decodeIfPresent(String.self, forKey: .question)
        instruction = try container.decodeIfPresent(String.self, forKey: .instruction)
    }

    private static func normalizeType(_ type: String) -> String {
        switch type {
        case "reply", "message", "send_message":
            return IntentActionType.draftReply.rawValue
        case "details", "question", "chat":
            return IntentActionType.answer.rawValue
        case "send", "send_draft", "confirm_send":
            return IntentActionType.sendDraftRequest.rawValue
        case "sources", "source", "show_source", "show_evidence":
            return IntentActionType.showSources.rawValue
        case "actions", "next_actions", "what_should_i_do":
            return IntentActionType.listActions.rawValue
        case "waiting_replies", "needs_reply", "who_needs_reply":
            return IntentActionType.findWaitingReplies.rawValue
        case "changes", "new_since_last_brief":
            return IntentActionType.summarizeChanges.rawValue
        case "tasks", "deadlines":
            return IntentActionType.extractTasks.rawValue
        case "compare":
            return IntentActionType.compareConversations.rawValue
        case "catchup", "catch_up", "brief_me", "what_is_pending":
            return IntentActionType.catchMeUp.rawValue
        case "handle_low_risk", "approve_easy", "do_the_easy_ones", "handle_the_easy_ones":
            return IntentActionType.handleEasy.rawValue
        case "what_i_owe", "who_do_i_owe", "owed", "my_commitments":
            return IntentActionType.whatDoIOwe.rawValue
        case "draft_all", "draft_waiting", "reply_to_everyone", "draft_everyone":
            return IntentActionType.draftAllWaiting.rawValue
        default:
            return type
        }
    }
}

struct IntentRouterPromptContext: Equatable {
    let conversations: [String]
    let cards: [String]
    let drafts: [String]

    var formatted: String {
        let conversationBlock = Self.numberedBlock(title: "Available conversations", rows: conversations)
        let cardBlock = Self.numberedBlock(title: "Visible brief cards", rows: cards)
        let draftBlock = Self.numberedBlock(title: "Active drafts", rows: drafts)
        return [conversationBlock, cardBlock, draftBlock].joined(separator: "\n\n")
    }

    private static func numberedBlock(title: String, rows: [String]) -> String {
        if rows.isEmpty {
            return "\(title):\nNone available."
        }
        return "\(title):\n" + rows.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
    }
}
