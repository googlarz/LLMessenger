// LLMessenger/Core/DemoSeeder.swift
//
// Demo Mode: seeds a realistic two-day fixture dataset so a brand-new user
// (or a reviewer, or an investor demo) experiences the full product in
// seconds — briefs, cards, evidence chains, tasks, timeline — without
// connecting a single account or configuring an AI backend.
//
// Entered from the onboarding welcome step; exited from the chrome bar,
// which wipes the fixture data and re-runs the setup wizard. Demo mode is
// only ever entered on a fresh install, so wiping all rows is safe.

import Foundation
import GRDB

enum DemoSeeder {

    static let demoFlagKey = "demoModeActive"

    static var isActive: Bool {
        UserDefaults.standard.bool(forKey: demoFlagKey)
    }

    // MARK: - Fixture script

    private struct DemoMessage {
        let sender: String
        let text: String
        let minutesAgo: Int
        var role: BriefCardSourceRole = .newMessage
    }

    private struct DemoCard {
        let service: String
        let conversationId: String
        let title: String
        let headline: String
        let priority: String
        let summary: String
        let callback: String?
        let actions: [String]
        let messages: [DemoMessage]
        /// Indices into `messages` quoted verbatim in the brief.
        let quoteIndexes: [Int]
    }

    private static let morningCards: [DemoCard] = [
        DemoCard(
            service: "signal",
            conversationId: "demo-meridian",
            title: "Meridian — Series B",
            headline: "Anna needs the revised cap table before Thursday's partner meeting",
            priority: "high",
            summary: "Anna confirmed the partner meeting moved up to Thursday 10:00. She asked for the cap table with the option-pool change and flagged that Marcus still hasn't received data-room access. Tone is positive — she called the metrics deck 'the strongest in this batch'.",
            callback: "Last brief: you promised the updated deck by Friday — it shipped Thursday night.",
            actions: ["Send revised cap table to Anna", "Grant Marcus data-room access"],
            messages: [
                DemoMessage(sender: "Anna Keller", text: "Partner meeting moved to Thu 10:00 — can you get me the updated cap table by Wed EOD?", minutesAgo: 95, role: .quote),
                DemoMessage(sender: "Anna Keller", text: "Also Marcus says he still can't open the data room.", minutesAgo: 93, role: .quote),
                DemoMessage(sender: "Anna Keller", text: "For what it's worth — the metrics deck is the strongest in this batch. See you Thursday.", minutesAgo: 90),
            ],
            quoteIndexes: [0, 1]
        ),
        DemoCard(
            service: "slack",
            conversationId: "demo-launch-room",
            title: "#launch-room",
            headline: "Staging incident resolved — postmortem doc expected today",
            priority: "med",
            summary: "The 40-minute staging outage traced to a misconfigured rate limit on the new ingest service. Priya rolled it back at 07:15 and owns the postmortem. No customer impact; launch timeline unaffected.",
            callback: nil,
            actions: ["Review Priya's postmortem when it lands"],
            messages: [
                DemoMessage(sender: "Priya Sharma", text: "Rolled back. Root cause: rate limiter config, not the migration. Postmortem by EOD.", minutesAgo: 150, role: .quote),
                DemoMessage(sender: "Tom Okafor", text: "Confirmed clean on monitoring for the last 30 min.", minutesAgo: 144),
                DemoMessage(sender: "Priya Sharma", text: "Launch timeline unaffected — this was staging only.", minutesAgo: 140),
            ],
            quoteIndexes: [0]
        ),
        DemoCard(
            service: "imessage",
            conversationId: "demo-dad",
            title: "Dad",
            headline: "Dad confirmed Sunday lunch, asks if 1pm works",
            priority: "low",
            summary: "Sunday lunch is on. He suggested 1pm at the usual place and mentioned he fixed the boat trailer.",
            callback: nil,
            actions: [],
            messages: [
                DemoMessage(sender: "Dad", text: "Sunday lunch still on? 1pm at the usual place?", minutesAgo: 200),
                DemoMessage(sender: "Dad", text: "Fixed the boat trailer by the way. Ready for summer.", minutesAgo: 198),
            ],
            quoteIndexes: []
        ),
        DemoCard(
            service: "telegram",
            conversationId: "demo-sailing",
            title: "Sailing Club",
            headline: "Regatta moved to the 28th — no action needed",
            priority: "low",
            summary: "Race committee moved the regatta a week out due to the harbour dredging schedule. Crew assignments unchanged.",
            callback: nil,
            actions: [],
            messages: [
                DemoMessage(sender: "Race Committee", text: "Regatta moved to the 28th — harbour dredging runs through the original weekend.", minutesAgo: 320),
                DemoMessage(sender: "Lena", text: "Crew assignments stay as posted.", minutesAgo: 300),
            ],
            quoteIndexes: []
        ),
    ]

    private static let eveningCards: [DemoCard] = [
        DemoCard(
            service: "signal",
            conversationId: "demo-meridian",
            title: "Meridian — Series B",
            headline: "Metrics deck delivered — Anna acknowledged receipt",
            priority: "low",
            summary: "You sent the updated metrics deck. Anna confirmed receipt and said she'd review before the weekend.",
            callback: nil,
            actions: [],
            messages: [
                DemoMessage(sender: "Anna Keller", text: "Got the deck — will review before the weekend. Nice work turning it around.", minutesAgo: 60 * 14),
            ],
            quoteIndexes: [0]
        ),
        DemoCard(
            service: "slack",
            conversationId: "demo-launch-room",
            title: "#launch-room",
            headline: "Ingest service migration merged behind a feature flag",
            priority: "low",
            summary: "Tom merged the ingest migration behind a flag; staging soak test runs overnight.",
            callback: nil,
            actions: [],
            messages: [
                DemoMessage(sender: "Tom Okafor", text: "Migration merged behind the flag. Soak test running overnight on staging.", minutesAgo: 60 * 15),
            ],
            quoteIndexes: []
        ),
    ]

    // MARK: - Seeding

    /// Seeds demo briefs, messages, cards, sources, and tasks. Also writes
    /// disabled ServiceConfig rows for every service so the poll engine and
    /// health UI stay quiet while demo data is on screen.
    static func seed(into database: AppDatabase) throws {
        let now = Date()

        // Yesterday evening's quiet brief first, so it sits below today's in
        // the archive and gives the conversation timeline two entries.
        let eveningDate = Calendar.current.date(byAdding: .hour, value: -14, to: now) ?? now
        _ = try insertBrief(
            cards: eveningCards, createdAt: eveningDate, windowStart: eveningDate.addingTimeInterval(-3 * 3600),
            status: "open", notificationText: "Nothing urgent · 2 threads",
            database: database
        )

        // This morning's brief — the one the user lands on.
        let morningDate = Calendar.current.date(byAdding: .minute, value: -25, to: now) ?? now
        let morningID = try insertBrief(
            cards: morningCards, createdAt: morningDate, windowStart: morningDate.addingTimeInterval(-2 * 3600),
            status: "ready", notificationText: "1 thing needs you · cap table for Anna",
            database: database
        )

        // A pending task from the high-priority card's action item.
        try database.dbQueue.write { db in
            var task = BriefTask(id: nil, briefCardId: "demo-signal-demo-meridian-\(morningID)",
                                 text: "Send revised cap table to Anna",
                                 completedAt: nil, createdAt: morningDate)
            try task.insert(db)
        }

        // Keep every service quiet while the demo is active.
        let settings = SettingsRepository(database: database)
        for service in ["imessage", "signal", "telegram", "slack"] {
            var config = ServiceConfig.default(for: service)
            config.enabled = false
            try settings.saveServiceConfig(config)
        }

        UserDefaults.standard.set(true, forKey: demoFlagKey)
    }

    /// Removes everything seed() created and clears the flag. Demo mode only
    /// exists on fresh installs, so a full wipe of content tables is safe.
    static func wipe(from database: AppDatabase) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM briefCardSources")
            try db.execute(sql: "DELETE FROM tasks")
            try db.execute(sql: "DELETE FROM briefCards")
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM briefs")
            try db.execute(sql: "DELETE FROM serviceConfig")
        }
        UserDefaults.standard.removeObject(forKey: demoFlagKey)
    }

    // MARK: - Private

    private static func insertBrief(cards: [DemoCard], createdAt: Date, windowStart: Date,
                                    status: String, notificationText: String,
                                    database: AppDatabase) throws -> Int64 {
        let repo = BriefRepository(database: database)
        let services = Array(Set(cards.map(\.service))).sorted()
        let servicesJSON = try jsonString(services)

        let briefID = try repo.insertBrief(Brief(
            createdAt: createdAt,
            status: status,
            services: servicesJSON,
            openingSummary: "",  // filled below once message IDs exist
            notificationText: notificationText,
            windowStart: windowStart
        ))

        var jsonCards: [[String: Any]] = []
        var totalMessages = 0, totalPeople = Set<String>()

        for card in cards {
            let cardID = "demo-\(card.service)-\(card.conversationId)-\(briefID)"
            var sourceMessageIds: [String] = []
            var quotes: [[String: String]] = []
            var insertedRows: [(rowID: Int64, messageID: String, message: DemoMessage)] = []

            try database.dbQueue.write { db in
                for (idx, m) in card.messages.enumerated() {
                    let timestamp = createdAt.addingTimeInterval(TimeInterval(-m.minutesAgo * 60))
                    let messageID = "\(cardID)-m\(idx)"
                    var row = Message(
                        briefId: briefID, service: card.service,
                        conversationId: card.conversationId,
                        conversationName: card.title,
                        messageId: messageID, sender: m.sender,
                        text: m.text, timestamp: timestamp, isSent: false
                    )
                    try row.insert(db)
                    insertedRows.append((row.id ?? 0, messageID, m))
                    sourceMessageIds.append(messageID)
                    totalPeople.insert(m.sender)
                }
            }
            totalMessages += card.messages.count

            for idx in card.quoteIndexes {
                let m = card.messages[idx]
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                quotes.append([
                    "messageId": insertedRows[idx].messageID,
                    "from": m.sender,
                    "time": f.string(from: createdAt.addingTimeInterval(TimeInterval(-m.minutesAgo * 60))),
                    "text": m.text,
                ])
            }

            try repo.insertBriefCard(BriefCardRecord(
                id: cardID, briefId: briefID, service: card.service,
                conversationId: card.conversationId, conversationTitle: card.title,
                headline: card.headline, priority: card.priority,
                summary: card.summary,
                actionItems: try jsonString(card.actions),
                callbackText: card.callback,
                sourceMessageIds: try jsonString(sourceMessageIds),
                createdAt: createdAt
            ))

            try repo.insertBriefCardSources(insertedRows.map { row in
                BriefCardSource(
                    briefCardId: cardID, messageRowId: row.rowID,
                    service: card.service, messageId: row.messageID,
                    sourceRole: row.message.role.rawValue,
                    quoteText: row.message.role == .quote ? row.message.text : nil,
                    createdAt: createdAt
                )
            })

            jsonCards.append([
                "id": cardID,
                "service": card.service,
                "conversationId": card.conversationId,
                "conversationTitle": card.title,
                "headline": card.headline,
                "priority": card.priority,
                "counts": ["messages": card.messages.count, "threads": 1,
                           "people": Set(card.messages.map(\.sender)).count],
                "summary": card.summary,
                "callback": card.callback as Any,
                "actionItems": card.actions,
                "quotes": quotes,
                "sourceMessageIds": sourceMessageIds,
            ])
        }

        let briefJSON: [String: Any] = [
            "total_messages": totalMessages,
            "total_threads": cards.count,
            "total_people": totalPeople.count,
            "cards": jsonCards,
        ]
        let data = try JSONSerialization.data(withJSONObject: briefJSON)
        var brief = try repo.fetchBrief(id: briefID)!
        brief.openingSummary = String(data: data, encoding: .utf8)
        try repo.update(brief: brief)

        return briefID
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "[]"
    }
}
