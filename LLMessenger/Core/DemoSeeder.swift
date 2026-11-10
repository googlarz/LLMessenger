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

    /// The exact conversations the seeder inserts, as "service|conversationId".
    /// This constant is the one definition of "sample data": the wipe deletes by
    /// it and the send path diverts by it. Nothing is matched by prefix or name,
    /// so a real contact called "demo-team@example.com" can never be mistaken
    /// for sample data.
    static let sampleConversations: [(service: String, conversationId: String)] = [
        ("signal", "demo-meridian"), ("slack", "demo-launch-room"),
        ("imessage", "demo-dad"), ("telegram", "demo-sailing"),
        ("signal", "demo-marcus"), ("imessage", "demo-mum"),
    ]

    private static let sampleKeys: Set<String> =
        Set(sampleConversations.map { "\($0.service)|\($0.conversationId)" })

    /// True only while demo mode is active AND the pair is one the seeder inserted.
    /// Read at the moment of the decision; outside demo mode nothing is sample.
    static func isSample(service: String, conversationId: String) -> Bool {
        isActive && sampleKeys.contains("\(service)|\(conversationId)")
    }

    /// `(service = ? AND conversationId = ?) OR ...` over the sample pairs.
    private static var sampleMatchSQL: String {
        sampleConversations.map { _ in "(service = ? AND conversationId = ?)" }.joined(separator: " OR ")
    }

    private static var sampleMatchArgs: StatementArguments {
        StatementArguments(sampleConversations.flatMap { [$0.service, $0.conversationId] })
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
            callback: "Last digest: you promised the updated deck by Friday — it shipped Thursday night.",
            actions: ["Send revised cap table to Anna", "Grant Marcus data-room access"],
            messages: [
                DemoMessage(sender: "Anna Keller", text: "For what it's worth — the metrics deck is the strongest in this batch.", minutesAgo: 95),
                DemoMessage(sender: "Anna Keller", text: "Also Marcus says he still can't open the data room.", minutesAgo: 93, role: .quote),
                DemoMessage(sender: "Anna Keller", text: "Partner meeting moved to Thu 10:00 — can you get me the updated cap table by Wed EOD?", minutesAgo: 90, role: .quote),
            ],
            quoteIndexes: [1, 2]
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
            actions: ["Confirm whether 1pm works for Sunday lunch"],
            messages: [
                DemoMessage(sender: "Dad", text: "Fixed the boat trailer by the way. Ready for summer.", minutesAgo: 200),
                DemoMessage(sender: "Dad", text: "Sunday lunch still on? 1pm at the usual place?", minutesAgo: 198),
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
    static func seed(into database: AppDatabase, activateDemoMode: Bool = true,
                     defaults: UserDefaults = .standard) throws {
        // Before anything is overwritten: the user's own service settings.
        let tookSnapshot = try snapshotServiceConfigs(in: database)
        do {
            try seedContent(into: database, activateDemoMode: activateDemoMode, defaults: defaults)
        } catch {
            // A failed seed must not leave stand-ins behind. (If the sample data was
            // already in place, the configs are the demo's and the snapshot stays.)
            if tookSnapshot { _ = try? restoreServiceConfigs(in: database) }
            throw error
        }
    }

    // MARK: - Service settings snapshot

    /// Sets the real serviceConfig rows aside so the demo's disabled stand-ins can be
    /// undone exactly. Kept in the database (not memory or defaults) so a relaunch
    /// in the middle of the demo still restores. If the sample data is already in
    /// place the snapshot is the real one and must not be replaced by the stand-ins.
    private static func snapshotServiceConfigs(in database: AppDatabase) throws -> Bool {
        try database.dbQueue.write { db in
            let alreadySeeded = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE \(sampleMatchSQL))",
                arguments: sampleMatchArgs) ?? false
            let hasSnapshot = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM demoServiceConfigSnapshot)") ?? false
            if alreadySeeded && hasSnapshot { return false }
            let configs = try ServiceConfig.order(Column("service")).fetchAll(db)
            let json = String(data: try JSONEncoder().encode(configs), encoding: .utf8) ?? "[]"
            try db.execute(sql: "DELETE FROM demoServiceConfigSnapshot")
            try db.execute(sql: "INSERT INTO demoServiceConfigSnapshot (id, configsJSON) VALUES (1, ?)",
                           arguments: [json])
            return true
        }
    }

    /// Puts the snapshot back as the whole serviceConfig table and drops it. Returns
    /// false when there is no snapshot (a demo started by an earlier version).
    @discardableResult
    private static func restoreServiceConfigs(in database: AppDatabase) throws -> Bool {
        try database.dbQueue.write { db in try restoreServiceConfigs(db) }
    }

    private static func restoreServiceConfigs(_ db: Database) throws -> Bool {
        guard let json = try String.fetchOne(db, sql: "SELECT configsJSON FROM demoServiceConfigSnapshot WHERE id = 1"),
              let data = json.data(using: .utf8) else { return false }
        let configs = try JSONDecoder().decode([ServiceConfig].self, from: data)
        try db.execute(sql: "DELETE FROM serviceConfig")
        for config in configs { try config.insert(db) }
        try db.execute(sql: "DELETE FROM demoServiceConfigSnapshot")
        return true
    }

    private static func seedContent(into database: AppDatabase, activateDemoMode: Bool,
                                    defaults: UserDefaults) throws {
        let now = Date()

        // Yesterday evening's quiet brief first, so it sits below today's in
        // the archive and gives the conversation timeline two entries.
        let eveningDate = Calendar.current.date(byAdding: .hour, value: -14, to: now) ?? now
        let eveningID = try insertBrief(
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
            let task = BriefTask(id: nil, briefCardId: "demo-signal-demo-meridian-\(morningID)",
                                 text: "Send revised cap table to Anna",
                                 completedAt: nil, createdAt: morningDate)
            try task.insert(db)
        }

        let repo = BriefRepository(database: database)
        try seedActQueue(into: database, now: now, morningBriefID: morningID, eveningBriefID: eveningID)
        try repo.upsertConversationContext(ConversationContext(
            service: "signal",
            conversationId: "demo-meridian",
            label: "investor",
            priorityHint: "high",
            updatedAt: morningDate,
            relationship: "lead investor",
            importantTopics: try jsonString(["fundraise", "data room", "partner meeting"]),
            contextNote: "Always surface time-sensitive fundraising requests.",
            responseExpectation: "same day",
            tone: "precise and warm"
        ))
        try repo.upsertConversationContext(ConversationContext(
            service: "telegram",
            conversationId: "demo-sailing",
            label: "club",
            priorityHint: "low",
            updatedAt: morningDate,
            relationship: "hobby group",
            noiseTopics: try jsonString(["schedule announcements", "crew chatter"]),
            contextNote: "Usually FYI unless a direct question names me."
        ))
        try repo.upsertConversationContext(ConversationContext(
            service: "imessage",
            conversationId: "demo-dad",
            label: "family",
            priorityHint: "auto",
            updatedAt: morningDate,
            relationship: "family",
            importantTopics: try jsonString(["plans", "travel", "health"]),
            tone: "casual"
        ))

        // Keep every service quiet while the demo is active.
        let settings = SettingsRepository(database: database)
        for service in ["imessage", "signal", "telegram", "slack", "whatsapp"] {
            var config = ServiceConfig.default(for: service)
            config.enabled = false
            try settings.saveServiceConfig(config)
        }

        if activateDemoMode {
            defaults.set(true, forKey: demoFlagKey)
        }
    }

    /// Removes everything seed() created and clears the flag. Demo mode only
    /// exists on fresh installs, so a full wipe of content tables is safe.
    static func wipe(from database: AppDatabase, defaults: UserDefaults = .standard) throws {
        var seededOwedIDs: Set<String> = []
        try database.dbQueue.write { db in
            let match = sampleMatchSQL, args = sampleMatchArgs
            // Everything is found through the exact sample conversations.
            let seeded = try Row.fetchAll(
                db, sql: "SELECT service, conversationId, messageId, briefId FROM messages WHERE \(match)",
                arguments: args)
            seededOwedIDs = Set(seeded.map { "\($0["service"] as String)|\($0["conversationId"] as String)|\($0["messageId"] as String)" })
            let briefIDs = Set(seeded.compactMap { $0["briefId"] as Int64? })
            let cardIDs = try String.fetchAll(db, sql: "SELECT id FROM briefCards WHERE \(match)", arguments: args)
            for id in cardIDs {
                try db.execute(sql: "DELETE FROM briefCardSources WHERE briefCardId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM tasks WHERE briefCardId = ?", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM briefCards WHERE \(match)", arguments: args)
            try db.execute(sql: "DELETE FROM messages WHERE \(match)", arguments: args)
            for id in briefIDs { try db.execute(sql: "DELETE FROM briefs WHERE id = ?", arguments: [id]) }
            try db.execute(sql: "DELETE FROM conversationContexts WHERE \(match)", arguments: args)
            try db.execute(sql: "DELETE FROM agentActions WHERE \(match)", arguments: args)
            try db.execute(sql: "DELETE FROM commitments WHERE \(match)", arguments: args)
            // The seeder overwrote every service's config with a disabled stand-in.
            // Put back exactly the rows that were there before. (A demo started by an
            // earlier version has no snapshot: its stand-ins carry no marker and the
            // setup flow that follows rewrites them.)
            if try !restoreServiceConfigs(db) {
                try db.execute(sql: "DELETE FROM serviceConfig")
            }
        }
        // Dismissing or snoozing a sample "owed reply" is remembered in defaults.
        let dismissed = OwedReplyStore.dismissedIDs(defaults).subtracting(seededOwedIDs)
        defaults.set(Array(dismissed), forKey: OwedReplyStore.dismissedKey)
        defaults.set(OwedReplyStore.snoozedMap(defaults).filter { !seededOwedIDs.contains($0.key) },
                     forKey: OwedReplyStore.snoozedKey)
        defaults.removeObject(forKey: demoFlagKey)
    }

    // MARK: - Act queue

    /// The small world behind the Act screen, told with the same people as the
    /// digests: Anna is waiting on the cap table, Priya owes a postmortem, Dad
    /// wants a yes about Sunday. Everything is written through the same
    /// repository calls real data uses, so `OwedReplyDeriver`,
    /// `fetchPendingAgentActions` and the commitment reads find it unaided.
    ///
    /// Act then shows: Needs your decision (Anna's unanswered question, ranked
    /// first, and a "Maybe" draft for Priya), Ready to send (Dad on iMessage,
    /// Marcus on Signal), Waiting on others (Priya's postmortem), Your promises
    /// and tasks (the cap table task) and, under Older, Mum's three-day-old question.
    private static func seedActQueue(into database: AppDatabase, now: Date,
                                     morningBriefID: Int64, eveningBriefID: Int64) throws {
        let repo = BriefRepository(database: database)

        // Two conversations that have no digest card: Marcus (waiting on data-room
        // access) and Mum (an old, still-unanswered question). Attached to a
        // brief so the digest pipeline never treats them as unprocessed.
        try database.dbQueue.write { db in
            var marcus = Message(
                briefId: morningBriefID, service: "signal", conversationId: "demo-marcus",
                conversationName: "Marcus Reid", messageId: "demo-signal-demo-marcus-m0",
                sender: "Marcus Reid",
                text: "Hi — Anna said you could sort my data-room access. Still getting 'access denied'. Any ETA?",
                timestamp: now.addingTimeInterval(-40 * 60), isSent: false)
            try marcus.insert(db)
            var mum = Message(
                briefId: eveningBriefID, service: "imessage", conversationId: "demo-mum",
                conversationName: "Mum", messageId: "demo-imessage-demo-mum-m0",
                sender: "Mum",
                text: "Did you see the photos I sent from Gran's birthday? No rush 🙂",
                timestamp: now.addingTimeInterval(-4 * 24 * 3600), isSent: false)
            try mum.insert(db)
        }

        func draft(service: String, conversationId: String, name: String, title: String,
                   text: String, why: String, confidence: Double, minutesAgo: Int,
                   maybe: Bool = false) -> AgentAction {
            AgentAction(
                id: nil, kind: AgentActionKind.reply.rawValue, service: service,
                conversationId: conversationId, conversationName: name, title: title,
                payload: AgentAction.encodeReplyPayload(text), reasoning: why,
                confidence: confidence,
                // Normal risk on purpose: "low" is what batch-approve picks up.
                riskLevel: AgentActionRisk.normal.rawValue,
                status: AgentActionStatus.pending.rawValue,
                createdAt: now.addingTimeInterval(-Double(minutesAgo) * 60), resolvedAt: nil,
                isMaybe: maybe)
        }
        for action in [
            draft(service: "imessage", conversationId: "demo-dad", name: "Dad",
                  title: "Reply — Sunday lunch at 1pm",
                  text: "1pm works! See you Sunday. Glad the trailer is fixed 🙂",
                  why: "Dad asked a direct question, and you usually answer him in a line.",
                  confidence: 0.86, minutesAgo: 20),
            draft(service: "signal", conversationId: "demo-marcus", name: "Marcus Reid",
                  title: "Reply — data-room access",
                  text: "Sorry about that, Marcus. I'll get your access sorted today and message you when it's live.",
                  why: "Marcus asked for access, and Anna raised it too.",
                  confidence: 0.82, minutesAgo: 35),
            draft(service: "slack", conversationId: "demo-launch-room", name: "#launch-room",
                  title: "Acknowledge Priya's update",
                  text: "Thanks Priya, I'll read the postmortem when it lands.",
                  why: "Priya didn't ask anything, so this may not need a reply.",
                  confidence: 0.55, minutesAgo: 50, maybe: true),
        ] {
            try repo.insertAgentAction(action)
        }

        _ = try repo.insertCommitment(Commitment(
            id: nil, direction: CommitmentDirection.theyOwe.rawValue, service: "slack",
            conversationId: "demo-launch-room", conversationName: "#launch-room",
            what: "Priya will post the incident postmortem",
            dueAt: now.addingTimeInterval(6 * 3600), evidenceMessageId: nil,
            status: CommitmentStatus.open.rawValue,
            createdAt: now.addingTimeInterval(-150 * 60)))
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

        for (position, card) in cards.enumerated() {
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
                needsReply: !card.actions.isEmpty,
                reason: card.actions.isEmpty ? "FYI announcement only" : "Direct question needs a lightweight reply",
                grounding: card.callback == nil ? "direct" : "context",
                actionItems: try jsonString(card.actions),
                callbackText: card.callback,
                sourceMessageIds: try jsonString(sourceMessageIds),
                createdAt: createdAt,
                logicalId: cardID,
                position: position,
                messageCount: card.messages.count,
                threadCount: 1,
                peopleCount: Set(card.messages.map(\.sender)).count,
                quotes: try jsonString(quotes),
                collapsed: false
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
                "needsReply": !card.actions.isEmpty,
                "reason": card.actions.isEmpty ? "FYI announcement only" : "Direct question needs a lightweight reply",
                "grounding": card.callback == nil ? "direct" : "context",
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
        guard var brief = try repo.fetchBrief(id: briefID) else {
            throw DatabaseError(message: "demo brief \(briefID) missing after insert")
        }
        brief.openingSummary = String(data: data, encoding: .utf8)
        try repo.update(brief: brief)

        return briefID
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "[]"
    }
}
