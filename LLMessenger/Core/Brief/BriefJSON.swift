import Foundation

struct BriefJSON: Codable {
    let totalMessages: Int?
    let totalThreads: Int?
    let totalPeople: Int?
    let cards: [BriefCard]

    var total_messages: Int? { totalMessages }
    var total_threads: Int? { totalThreads }
    var total_people: Int? { totalPeople }

    enum CodingKeys: String, CodingKey {
        case totalMessages = "total_messages"
        case totalThreads = "total_threads"
        case totalPeople = "total_people"
        case cards
    }
}

struct BriefCard: Codable, Identifiable {
    let id: String
    let service: String
    let conversationId: String
    let conversationTitle: String?
    let headline: String
    let priority: String
    let counts: BriefCardCounts
    let summary: String
    let callback: String?
    let needsReply: Bool
    let reason: String?
    let grounding: String
    let actionItems: [String]
    let quotes: [BriefQuote]
    let sourceMessageIds: [String]
    /// Set at brief creation time by DigestOrdering — low-priority/noise cards are folded
    /// into the noise strip in the UI rather than rendered as full cards.
    let collapsed: Bool

    var conversation: String? { conversationTitle }
    var actions: [String] { actionItems }

    enum CodingKeys: String, CodingKey {
        case id
        case service
        case conversationId
        case conversationTitle
        case legacyConversation = "conversation"
        case headline
        case priority
        case counts
        case summary
        case callback
        case needsReply
        case reason
        case grounding
        case actionItems
        case legacyActions = "actions"
        case quotes
        case sourceMessageIds
        case collapsed
    }

    init(
        id: String,
        service: String,
        conversationId: String,
        conversationTitle: String?,
        headline: String,
        priority: String,
        counts: BriefCardCounts,
        summary: String,
        callback: String?,
        needsReply: Bool = false,
        reason: String? = nil,
        grounding: String = "direct",
        actionItems: [String],
        quotes: [BriefQuote],
        sourceMessageIds: [String],
        collapsed: Bool = false
    ) {
        self.id = id
        self.service = service
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.headline = headline
        self.priority = priority
        self.counts = counts
        self.summary = summary
        self.callback = callback
        self.needsReply = needsReply
        self.reason = reason
        self.grounding = grounding
        self.actionItems = actionItems
        self.quotes = quotes
        self.sourceMessageIds = sourceMessageIds
        self.collapsed = collapsed
    }

    func withCollapsed(_ value: Bool) -> BriefCard {
        BriefCard(id: id, service: service, conversationId: conversationId,
                  conversationTitle: conversationTitle, headline: headline,
                  priority: priority, counts: counts, summary: summary,
                  callback: callback, needsReply: needsReply, reason: reason,
                  grounding: grounding, actionItems: actionItems, quotes: quotes,
                  sourceMessageIds: sourceMessageIds, collapsed: value)
    }

    func withActionability(priority: String? = nil,
                           needsReply: Bool? = nil,
                           reason: String? = nil,
                           grounding: String? = nil) -> BriefCard {
        BriefCard(id: id, service: service, conversationId: conversationId,
                  conversationTitle: conversationTitle, headline: headline,
                  priority: priority ?? self.priority, counts: counts, summary: summary,
                  callback: callback, needsReply: needsReply ?? self.needsReply,
                  reason: reason ?? self.reason, grounding: grounding ?? self.grounding,
                  actionItems: actionItems, quotes: quotes,
                  sourceMessageIds: sourceMessageIds, collapsed: collapsed)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        service = try container.decodeIfPresent(String.self, forKey: .service) ?? "unknown"
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
            ?? (try container.decodeIfPresent(String.self, forKey: .legacyConversation))
            ?? "unknown"
        conversationTitle = try container.decodeIfPresent(String.self, forKey: .conversationTitle)
            ?? (try container.decodeIfPresent(String.self, forKey: .legacyConversation))
        headline = try container.decode(String.self, forKey: .headline)
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? "low"
        counts = try container.decodeIfPresent(BriefCardCounts.self, forKey: .counts) ?? .zero
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? headline
        // The LLM occasionally emits a bool or other non-string value for callback;
        // tolerate it as nil rather than failing the whole brief.
        callback = (try? container.decodeIfPresent(String.self, forKey: .callback)) ?? nil
        needsReply = (try? container.decodeIfPresent(Bool.self, forKey: .needsReply)) ?? false
        reason = (try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        grounding = try container.decodeIfPresent(String.self, forKey: .grounding) ?? "direct"
        actionItems = try container.decodeIfPresent([String].self, forKey: .actionItems)
            ?? (try container.decodeIfPresent([String].self, forKey: .legacyActions))
            ?? []
        quotes = try container.decodeIfPresent([BriefQuote].self, forKey: .quotes) ?? []
        // The LLM formats messages as "[id=<msgId> | ...]" and sometimes copies the "id=" label
        // verbatim into sourceMessageIds (e.g. "id=541a06ac-...-1777702993542"). Strip it here so
        // validation, persistence, and evidence lookup all receive bare message IDs.
        sourceMessageIds = (try container.decodeIfPresent([String].self, forKey: .sourceMessageIds) ?? [])
            .map { $0.hasPrefix("id=") ? String($0.dropFirst(3)) : $0 }
        collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(service, forKey: .service)
        try container.encode(conversationId, forKey: .conversationId)
        try container.encodeIfPresent(conversationTitle, forKey: .conversationTitle)
        try container.encode(headline, forKey: .headline)
        try container.encode(priority, forKey: .priority)
        try container.encode(counts, forKey: .counts)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(callback, forKey: .callback)
        try container.encode(needsReply, forKey: .needsReply)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(grounding, forKey: .grounding)
        try container.encode(actionItems, forKey: .actionItems)
        try container.encode(quotes, forKey: .quotes)
        try container.encode(sourceMessageIds, forKey: .sourceMessageIds)
        try container.encode(collapsed, forKey: .collapsed)
    }
}

struct BriefCardCounts: Codable {
    let messages: Int
    let threads: Int
    let people: Int

    static let zero = BriefCardCounts(messages: 0, threads: 0, people: 0)
}

struct BriefQuote: Codable {
    let messageId: String?
    let from: String
    let time: String
    let text: String

    init(messageId: String?, from: String, time: String, text: String) {
        self.messageId = messageId
        self.from = from
        self.time = time
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .messageId)
        messageId = raw.map { $0.hasPrefix("id=") ? String($0.dropFirst(3)) : $0 }
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

// MARK: - Lenient extraction from raw LLM output (OpusPlus audit 2026-06-15)
//
// LLMs routinely violate "JSON only": markdown fences, preamble ("Here is your brief:"),
// trailing prose, trailing commas, truncated output. ONE shared lenient path is used by
// both the engine (BriefEngine.decodeAndValidateBrief) and the render fallback
// (BriefProseView) so the two decoders never diverge.
extension BriefJSON {
    /// Best-effort extraction of a JSON payload from raw model output: strips a fenced code
    /// block anywhere (not just a leading one), drops prose around the JSON by taking the
    /// first `{`/`[` to the last `}`/`]`, and removes trailing commas. It attempts to balance
    /// trailing-truncated brackets, but a brief truncated MID-STRUCTURE stays invalid by design
    /// — the caller decodes with `try?` and an unrecoverable brief is safely dropped, not
    /// half-rendered.
    static func extractJSONPayload(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenced = firstFencedBlock(in: s) { s = fenced }
        if let span = outermostJSONSpan(in: s) { s = span }
        s = s.replacingOccurrences(of: #",\s*\]"#, with: "]", options: .regularExpression)
        s = s.replacingOccurrences(of: #",\s*\}"#, with: "}", options: .regularExpression)
        // Count only brackets that are outside JSON string literals, so a stray `{` or `[`
        // inside a headline/summary value doesn't trigger a spurious append that breaks decode.
        var openBraces = 0, closeBraces = 0, openBrackets = 0, closeBrackets = 0
        var inString = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if inString {
                if c == "\\" {
                    idx = s.index(after: idx) // skip the escaped character
                    if idx < s.endIndex { idx = s.index(after: idx) }
                    continue
                }
                if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{": openBraces += 1
                case "}": closeBraces += 1
                case "[": openBrackets += 1
                case "]": closeBrackets += 1
                default: break
                }
            }
            idx = s.index(after: idx)
        }
        if closeBraces < openBraces { s += String(repeating: "}", count: openBraces - closeBraces) }
        if closeBrackets < openBrackets { s += String(repeating: "]", count: openBrackets - closeBrackets) }
        return s
    }

    /// Decode raw model output into a BriefJSON, tolerating fences/prose/minor defects.
    /// Returns nil for empty input or output with no recoverable JSON.
    static func decodeLenient(from raw: String?) -> BriefJSON? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let data = extractJSONPayload(from: raw).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BriefJSON.self, from: data)
    }

    /// True when a string still looks like (possibly malformed) JSON — used by the render
    /// fallback to avoid showing raw JSON to the user after decoding has already failed.
    static func looksLikeJSON(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") || t.contains("\"cards\"") { return true }
        return t.range(of: #"\{\s*"[^"]+"\s*:"#, options: .regularExpression) != nil
    }

    private static func firstFencedBlock(in s: String) -> String? {
        guard let open = s.range(of: #"```[a-zA-Z]*\n?"#, options: .regularExpression) else { return nil }
        let rest = s[open.upperBound...]
        if let close = rest.range(of: "```") {
            return String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func outermostJSONSpan(in s: String) -> String? {
        guard let firstOpen = s.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let closer: Character = s[firstOpen] == "{" ? "}" : "]"
        guard let lastClose = s.lastIndex(of: closer), lastClose > firstOpen else { return nil }
        return String(s[firstOpen...lastClose])
    }
}
