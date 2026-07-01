// LLMessengerTests/FrontendRobustnessTests.swift
// Tests every backend→frontend contract that could cause a crash or inconsistent state.
//
// The frontend has one force-unwrap (ChatViewModel.loadBrief: brief.id!), reads BriefCardRecord
// JSON fields as raw strings, and computes selectedBrief from a cached array after every refresh.
// These tests verify that the backend upholds each contract so those paths are always safe.
import XCTest
import GRDB
import AppKit
@testable import LLMessenger

@MainActor
final class FrontendRobustnessTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(inMemory: true) }

    private func makeAppState(db: AppDatabase) -> AppState {
        AppState(database: db, llmClient: MockLLMClient(), llmModel: "test", basePrompt: "BASE")
    }

    // MARK: - Windows must open over another app's fullscreen Space without crashing

    /// Opening Settings while another app owns the active fullscreen Space hangs/crashes
    /// the app unless the window can join all Spaces as a fullscreen auxiliary — a managed
    /// window (the default collectionBehavior) can't be placed on a fullscreen Space.
    func testSettingsWindowCanOpenOverFullscreenSpace() throws {
        let controller = SettingsWindowController(database: try makeDB())
        let behavior = controller.window?.collectionBehavior ?? []
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces), "Settings window must join all Spaces")
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary), "Settings window must be a fullscreen auxiliary")
    }

    func testOnboardingWindowCanOpenOverFullscreenSpace() throws {
        let controller = OnboardingWindowController(database: try makeDB())
        let behavior = controller.window?.collectionBehavior ?? []
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces), "Onboarding window must join all Spaces")
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary), "Onboarding window must be a fullscreen auxiliary")
    }

    // MARK: - Act queue identity

    func testActItemIDsStayUniqueBeforeDatabaseInsert() {
        let now = Date()
        func action(title: String, draft: String) -> AgentAction {
            AgentAction(
                id: nil,
                kind: AgentActionKind.reply.rawValue,
                service: "imessage",
                conversationId: "c1",
                conversationName: "Alice",
                title: title,
                payload: AgentAction.encodeReplyPayload(draft),
                reasoning: "fixture",
                confidence: 0.8,
                riskLevel: AgentActionRisk.low.rawValue,
                status: AgentActionStatus.pending.rawValue,
                createdAt: now,
                resolvedAt: nil
            )
        }

        let ids = [
            ActItem.agentAction(action(title: "Reply one", draft: "one")).id,
            ActItem.agentAction(action(title: "Reply two", draft: "two")).id
        ]

        XCTAssertEqual(Set(ids).count, ids.count,
                       "Act items without database ids must still have distinct SwiftUI identities")
        XCTAssertFalse(ids.contains("action-0"),
                       "Nil database ids must not collapse to action-0; snapshot fixtures can contain several")
    }

    func testActItemSorterKeepsFreshItemsAheadOfStaleItems() {
        func action(title: String, createdAt: Date) -> AgentAction {
            AgentAction(
                id: nil,
                kind: AgentActionKind.reply.rawValue,
                service: "imessage",
                conversationId: title,
                conversationName: title,
                title: title,
                payload: AgentAction.encodeReplyPayload(title),
                reasoning: "fixture",
                confidence: 0.8,
                riskLevel: AgentActionRisk.low.rawValue,
                status: AgentActionStatus.pending.rawValue,
                createdAt: createdAt,
                resolvedAt: nil
            )
        }

        let fresh = ActItem.agentAction(action(title: "fresh", createdAt: Date().addingTimeInterval(-3600)))
        let stale = ActItem.agentAction(action(title: "stale", createdAt: Date().addingTimeInterval(-72 * 3600)))

        let sorted = ActItemSorter.sort([stale, fresh]) { _, _ in nil }

        XCTAssertEqual(sorted.map(\.name), ["fresh", "stale"])
    }

    func testProductOutcomeStatsCountsRecentBriefsHandledCardsAndAudits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recentID: Int64 = 42
        let oldID: Int64 = 7
        let json = """
        {
          "total_messages": 3,
          "total_threads": 2,
          "total_people": 2,
          "cards": [
            {
              "id": "c1",
              "service": "signal",
              "conversationId": "vip",
              "headline": "Anna needs reply",
              "priority": "high",
              "counts": { "messages": 2, "threads": 1, "people": 1 },
              "summary": "Needs a reply.",
              "needsReply": true,
              "sourceMessageIds": ["m1"]
            },
            {
              "id": "c2",
              "service": "telegram",
              "conversationId": "noise",
              "headline": "FYI only",
              "priority": "low",
              "counts": { "messages": 1, "threads": 1, "people": 1 },
              "summary": "No action.",
              "needsReply": false,
              "sourceMessageIds": ["m2"]
            }
          ]
        }
        """
        let briefs = [
            Brief(id: recentID, createdAt: now.addingTimeInterval(-3600), status: "ready",
                  services: #"["signal"]"#, openingSummary: json, notificationText: "x"),
            Brief(id: oldID, createdAt: now.addingTimeInterval(-9 * 86400), status: "open",
                  services: #"["signal"]"#, openingSummary: json, notificationText: "x")
        ]
        let audits = [
            ActionAuditRecord(id: 1, actionKind: "reply", service: "signal", conversationId: "vip",
                              detail: "Sent", trigger: "approved", createdAt: now.addingTimeInterval(-120)),
            ActionAuditRecord(id: 2, actionKind: "reply", service: "signal", conversationId: "vip",
                              detail: "Auto", trigger: "delegated", createdAt: now.addingTimeInterval(-60)),
            ActionAuditRecord(id: 3, actionKind: "reply", service: "signal", conversationId: "old",
                              detail: "Old", trigger: "approved", createdAt: now.addingTimeInterval(-9 * 86400))
        ]

        let stats = ProductOutcomeStats.lastSevenDays(
            briefs: briefs,
            handledCardKeys: ["\(recentID):c1", "\(oldID):c1", "bad-key"],
            auditRows: audits,
            openCommitmentCount: 3,
            heldBackCount: 5,
            now: now
        )

        XCTAssertEqual(stats.digestCount, 1)
        XCTAssertEqual(stats.threadsSummarized, 2)
        XCTAssertEqual(stats.sourceBackedCardCount, 2)
        XCTAssertEqual(stats.replyNeededCount, 1)
        XCTAssertEqual(stats.quietThreadCount, 1)
        XCTAssertEqual(stats.handledCount, 1)
        XCTAssertEqual(stats.queuedSendCount, 1)
        XCTAssertEqual(stats.autoSentCount, 1)
        XCTAssertEqual(stats.auditCount, 2)
        XCTAssertEqual(stats.openCommitmentCount, 3)
        XCTAssertEqual(stats.heldBackCount, 5)
    }

    func testProductLoveMetricStoreCountsActiveDaysAndActionsLocally() throws {
        let suiteName = "ProductLoveMetricStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        let day2 = day1.addingTimeInterval(86400)

        var metrics = ProductLoveMetricStore.markActiveToday(defaults: defaults, now: day1)
        metrics = ProductLoveMetricStore.markActiveToday(defaults: defaults, now: day1.addingTimeInterval(3600))
        XCTAssertEqual(metrics.activeDays, 1)
        XCTAssertEqual(metrics.firstWeekDay, 1)

        metrics = ProductLoveMetricStore.markActiveToday(defaults: defaults, now: day2)
        XCTAssertEqual(metrics.activeDays, 2)

        metrics = ProductLoveMetricStore.recordOpenedDigest(defaults: defaults)
        metrics = ProductLoveMetricStore.recordHandledCard(defaults: defaults)
        metrics = ProductLoveMetricStore.recordPriorityCorrection(defaults: defaults)
        metrics = ProductLoveMetricStore.recordQuietedThread(defaults: defaults)
        metrics = ProductLoveMetricStore.recordDraftCreated(defaults: defaults)
        metrics = ProductLoveMetricStore.recordUndo(defaults: defaults)
        metrics = ProductLoveMetricStore.recordDemoStart(defaults: defaults)

        XCTAssertEqual(metrics.openedDigests, 1)
        XCTAssertEqual(metrics.handledCards, 1)
        XCTAssertEqual(metrics.priorityCorrections, 1)
        XCTAssertEqual(metrics.quietedThreads, 1)
        XCTAssertEqual(metrics.draftsCreated, 1)
        XCTAssertEqual(metrics.undoCount, 1)
        XCTAssertEqual(metrics.demoStarts, 1)
        XCTAssertTrue(metrics.hasLearningSignal)
        XCTAssertTrue(metrics.learningReceipt.contains("undo"))

        metrics = ProductLoveMetricStore.acknowledgeFirstRealDigest(defaults: defaults)
        XCTAssertTrue(metrics.firstRealDigestAcknowledged)
    }

    func testProductLoveMetricsHidesFirstWeekGuideAfterHabitLoopCompletes() {
        let formed = ProductLoveMetrics(
            activeDays: 2,
            firstSeenAt: Date().addingTimeInterval(-2 * 86400),
            handledCards: 3,
            priorityCorrections: 1,
            quietedThreads: 1,
            openedDigests: 4,
            guideDismissed: false,
            draftsCreated: 1,
            undoCount: 0,
            demoStarts: 0,
            firstRealDigestAcknowledged: false
        )
        let newUser = ProductLoveMetrics.empty

        XCTAssertFalse(formed.shouldShowFirstWeekGuide(suggestionCount: 0))
        XCTAssertTrue(formed.shouldShowFirstWeekGuide(suggestionCount: 1))
        XCTAssertTrue(newUser.shouldShowFirstWeekGuide(suggestionCount: 0))
        XCTAssertTrue(formed.shouldShowLearningReceipt)
        XCTAssertFalse(newUser.shouldShowLearningReceipt)
        XCTAssertTrue(formed.learningNextStep.contains("Next digest"))
    }

    func testFirstWeekGuideStaysHiddenOnceDismissedEvenWithinFirstWeek() {
        let newUser = ProductLoveMetrics.empty
        XCTAssertTrue(newUser.shouldShowFirstWeekGuide(suggestionCount: 0))

        var dismissed = newUser
        dismissed.guideDismissed = true
        // Even with a fresh suggestion arriving (the OR-gate condition that would
        // otherwise resurrect the guide), a user dismiss must win.
        XCTAssertFalse(dismissed.shouldShowFirstWeekGuide(suggestionCount: 1))
    }

    func testMarkCardHandledReceiptCanUndo() async throws {
        let db = try makeDB()
        let appState = makeAppState(db: db)
        let briefID = try await insertBrief(db: db)

        appState.markCardHandled(briefID: briefID, cardID: "card-1")
        XCTAssertTrue(appState.isCardHandled(briefID: briefID, cardID: "card-1"))
        XCTAssertEqual(appState.userReceipt?.actionTitle, "Undo")

        let beforeUndo = appState.productLoveMetrics.undoCount
        appState.userReceipt?.action?()
        XCTAssertFalse(appState.isCardHandled(briefID: briefID, cardID: "card-1"))
        XCTAssertEqual(appState.productLoveMetrics.undoCount, beforeUndo + 1)
    }

    func testSkipActionReceiptCanUndo() async throws {
        let db = try makeDB()
        let appState = makeAppState(db: db)
        let action = try await insertAgentAction(db: db)

        appState.reloadAgentActions()
        appState.skipAction(action)
        var stored = try await db.dbQueue.read { d in
            try AgentAction.fetchOne(d, key: action.id!)
        }
        XCTAssertEqual(stored?.statusEnum, .skipped)
        XCTAssertEqual(appState.userReceipt?.actionTitle, "Undo")

        let beforeUndo = appState.productLoveMetrics.undoCount
        appState.userReceipt?.action?()
        stored = try await db.dbQueue.read { d in
            try AgentAction.fetchOne(d, key: action.id!)
        }
        XCTAssertEqual(stored?.statusEnum, .pending)
        XCTAssertEqual(appState.productLoveMetrics.undoCount, beforeUndo + 1)
    }

    /// Inserts a Brief using only the fields accepted by the existing memberwise init.
    private func insertBrief(db: AppDatabase,
                             status: String = "ready",
                             services: String = #"["signal"]"#,
                             openingSummary: String? = nil,
                             episodicSummary: String? = nil) async throws -> Int64 {
        try await db.dbQueue.write { d in
            var b = Brief(createdAt: Date(), status: status, services: services,
                          openingSummary: openingSummary, notificationText: "x",
                          episodicSummary: episodicSummary)
            try b.insert(d)
            return b.id!
        }
    }

    private func insertAgentAction(db: AppDatabase) async throws -> AgentAction {
        try await db.dbQueue.write { d in
            var action = AgentAction(
                id: nil,
                kind: AgentActionKind.reply.rawValue,
                service: "signal",
                conversationId: "c1",
                conversationName: "Anna",
                title: "Reply to Anna",
                payload: AgentAction.encodeReplyPayload("On it."),
                reasoning: "Fixture",
                confidence: 0.8,
                riskLevel: AgentActionRisk.low.rawValue,
                status: AgentActionStatus.pending.rawValue,
                createdAt: Date(),
                resolvedAt: nil
            )
            try action.insert(d)
            return action
        }
    }

    /// Inserts a BriefCardRecord directly into the DB, bypassing insertBriefCard's guard.
    /// Used to inject corrupt JSON and verify the read path is crash-safe.
    private func insertBriefCardDirect(db: AppDatabase,
                                       briefId: Int64,
                                       actionItems: String,
                                       sourceMessageIds: String) async throws {
        try await db.dbQueue.write { d in
            let card = BriefCardRecord(
                id: UUID().uuidString,
                briefId: briefId,
                service: "signal",
                conversationId: "c1",
                conversationTitle: nil,
                headline: "Test card",
                priority: "normal",
                summary: "A test summary.",
                actionItems: actionItems,
                callbackText: nil,
                sourceMessageIds: sourceMessageIds,
                createdAt: Date()
            )
            try card.insert(d)
        }
    }

    // MARK: - brief.id! force-unwrap contract
    //
    // ChatViewModel.loadBrief line 21: `brief.id!`
    // This is the only force-unwrap in the UI layer. The contract: every Brief returned by
    // fetchAllBriefs() must have a non-nil id. GRDB assigns rowIDs on insert, so this is always
    // true — but we must prove it with a test, not rely on assumption.

    func testFetchAllBriefsNeverReturnsNilId() async throws {
        let db = try makeDB()
        _ = try await insertBrief(db: db, status: "ready")
        _ = try await insertBrief(db: db, status: "open")
        _ = try await insertBrief(db: db, status: "idle")

        let repository = BriefRepository(database: db)
        let briefs = try repository.fetchAllBriefs()

        XCTAssertFalse(briefs.isEmpty, "Precondition: briefs must be present in DB")
        for brief in briefs {
            XCTAssertNotNil(brief.id,
                            "fetchAllBriefs must never return a Brief with nil id — " +
                            "ChatViewModel.loadBrief force-unwraps brief.id on every invocation")
        }
    }

    func testLoadBriefWithDatabaseBriefDoesNotCrash() async throws {
        let db = try makeDB()
        let briefId = try await insertBrief(db: db)
        try await db.dbQueue.write { d in
            var msg = Message(briefId: briefId, service: "signal",
                              conversationId: "c1", messageId: "m1",
                              sender: "Alice", text: "Hi",
                              timestamp: Date(), isSent: false)
            try msg.insert(d)
        }

        let appState = makeAppState(db: db)
        await appState.refreshBriefs().value
        let brief = try XCTUnwrap(appState.briefs.first, "Precondition: must have a brief after refresh")
        let vm = ChatViewModel(appState: appState)

        // Must not crash — this exercises brief.id! on a real DB-fetched Brief
        try await vm.loadBrief(brief)

        XCTAssertFalse(vm.threadItems.isEmpty,
                       "loadBrief must populate threadItems from the attached messages")
    }

    // MARK: - fetchBriefCards contract
    //
    // BriefProseView calls fetchBriefCards and iterates the result.
    // An unknown briefID must return [] — not nil, not crash.
    // Corrupt JSON in actionItems/sourceMessageIds must not crash the read path.

    func testFetchBriefCardsForUnknownBriefIDReturnsEmptyArray() throws {
        let db = try makeDB()
        let repository = BriefRepository(database: db)
        let cards = try repository.fetchBriefCards(briefID: 99_999)
        XCTAssertEqual(cards.count, 0,
                       "fetchBriefCards with a non-existent briefID must return [] — " +
                       "never nil, never crash — BriefProseView iterates the result unconditionally")
    }

    func testFetchBriefCardsWithMalformedJSONFieldsDoesNotCrash() async throws {
        let db = try makeDB()
        let briefId = try await insertBrief(db: db)
        // Inject corrupt JSON by bypassing the guard in insertBriefCard
        try await insertBriefCardDirect(db: db, briefId: briefId,
                                        actionItems: "NOT_VALID_JSON",
                                        sourceMessageIds: "ALSO_NOT_JSON")

        let repository = BriefRepository(database: db)
        let cards = try repository.fetchBriefCards(briefID: briefId)

        XCTAssertEqual(cards.count, 1,
                       "fetchBriefCards must return the card even when JSON fields are corrupt — " +
                       "BriefCardRecord stores them as raw Strings, not decoded on read")
        XCTAssertEqual(cards[0].actionItems, "NOT_VALID_JSON",
                       "actionItems must be returned verbatim — it is a raw String, never decoded on read")
        XCTAssertEqual(cards[0].sourceMessageIds, "ALSO_NOT_JSON",
                       "sourceMessageIds must be returned verbatim — raw String, never decoded on read")
    }

    // MARK: - Stale selectedBriefID
    //
    // AppState.selectedBrief = briefs.first { $0.id == selectedBriefID }
    // If the selected brief is deleted and briefs are refreshed, selectedBriefID is stale.
    // selectedBrief must return nil — not crash, not return the wrong brief.

    func testSelectedBriefReturnsNilAfterBriefDeletedAndRefreshed() async throws {
        let db = try makeDB()
        let briefId = try await insertBrief(db: db)
        let appState = makeAppState(db: db)
        await appState.refreshBriefs().value
        appState.selectedBriefID = briefId
        XCTAssertNotNil(appState.selectedBrief, "Precondition: selectedBrief must resolve before deletion")

        // Simulate brief being pruned / replaced
        try await db.dbQueue.write { d in
            try d.execute(sql: "DELETE FROM briefs WHERE id = ?", arguments: [briefId])
        }
        await appState.refreshBriefs().value

        XCTAssertNil(appState.selectedBrief,
                     "selectedBrief must return nil after the targeted brief is deleted and briefs are refreshed — " +
                     "a stale selectedBriefID must never crash or return wrong data")
        XCTAssertTrue(appState.briefs.isEmpty,
                      "briefs must be empty after all briefs are deleted")
    }

    // MARK: - markAsOpen contract
    //
    // AppState.markAsOpen silently ignores errors — the UI must stay consistent regardless.

    func testMarkAsOpenWithUnknownBriefIDDoesNotCrash() throws {
        let db = try makeDB()
        let appState = makeAppState(db: db)
        appState.refreshBriefs()

        // Must not crash, must not throw (AppState catches and ignores errors)
        appState.markAsOpen(briefID: 99_999)

        XCTAssertTrue(appState.briefs.isEmpty,
                      "briefs must remain empty — markAsOpen on unknown ID must be a no-op")
    }

    func testMarkAsOpenIsIdempotent() async throws {
        let db = try makeDB()
        let briefId = try await insertBrief(db: db, status: "ready")
        let appState = makeAppState(db: db)
        await appState.refreshBriefs().value
        XCTAssertEqual(appState.briefs.first?.briefStatus, .ready, "Precondition: status must be ready")

        // Call twice — must not crash, must not corrupt state
        await appState.markAsOpen(briefID: briefId).value
        await appState.markAsOpen(briefID: briefId).value

        XCTAssertEqual(appState.briefs.first?.briefStatus, .open,
                       "markAsOpen must be idempotent — calling twice must produce the same result without crashing")
    }

    func testMarkAsOpenDoesNotAffectOtherBriefs() async throws {
        let db = try makeDB()
        let id1 = try await insertBrief(db: db, status: "ready")
        let id2 = try await insertBrief(db: db, status: "ready")
        let appState = makeAppState(db: db)
        await appState.refreshBriefs().value

        await appState.markAsOpen(briefID: id1).value

        let byID = Dictionary(uniqueKeysWithValues: appState.briefs.compactMap { b in
            b.id.map { ($0, b.briefStatus) }
        })
        XCTAssertEqual(byID[id1], .open,
                       "markAsOpen must set the target brief's status to open")
        XCTAssertEqual(byID[id2], .ready,
                       "markAsOpen must not affect other briefs — SQL WHERE id = ? must be scoped correctly")
    }

    func testSaveConversationContextPreservesRichContextFields() throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        var existing = ConversationContext(
            service: "signal",
            conversationId: "c1",
            label: "client",
            priorityHint: "auto",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            relationship: "client",
            importantTopics: #"["launch"]"#,
            noiseTopics: #"["memes"]"#,
            keySenders: #"["Ari"]"#,
            contextNote: "Prefers short updates.",
            responseExpectation: "same day",
            privacyOverride: "never_draft",
            aliases: #"["ACME = Acme Corp"]"#,
            tone: "concise",
            delegation: #"["calendar"]"#
        )
        existing.noiseTopicsList.append("old low-signal thread")
        try repo.upsertConversationContext(existing)

        let appState = makeAppState(db: db)
        appState.saveConversationContext(service: "signal", conversationId: "c1", label: "vip client", priorityHint: "low")

        let saved = try XCTUnwrap(repo.fetchConversationContext(service: "signal", conversationId: "c1"))
        XCTAssertEqual(saved.label, "vip client")
        XCTAssertEqual(saved.priorityHint, "low")
        XCTAssertEqual(saved.relationship, "client")
        XCTAssertEqual(saved.importantTopicsList, ["launch"])
        XCTAssertEqual(saved.noiseTopicsList, ["memes", "old low-signal thread"])
        XCTAssertEqual(saved.keySendersList, ["Ari"])
        XCTAssertEqual(saved.contextNote, "Prefers short updates.")
        XCTAssertEqual(saved.responseExpectation, "same day")
        XCTAssertEqual(saved.privacyOverride, "never_draft")
        XCTAssertEqual(saved.aliasesList, ["ACME = Acme Corp"])
        XCTAssertEqual(saved.tone, "concise")
        XCTAssertEqual(saved.delegationKinds, ["calendar"])
    }

    func testSaveConversationPrivacyOverridePreservesContextAndCanClear() throws {
        let db = try makeDB()
        let repo = BriefRepository(database: db)
        let existing = ConversationContext(
            service: "signal",
            conversationId: "c1",
            label: "client",
            priorityHint: "high",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            relationship: "client",
            importantTopics: #"["launch"]"#,
            privacyOverride: "never_draft",
            tone: "concise"
        )
        try repo.upsertConversationContext(existing)

        let appState = makeAppState(db: db)
        appState.saveConversationPrivacyOverride(service: "signal", conversationId: "c1", privacyOverride: "local_only")

        var saved = try XCTUnwrap(repo.fetchConversationContext(service: "signal", conversationId: "c1"))
        XCTAssertEqual(saved.label, "client")
        XCTAssertEqual(saved.priorityHint, "high")
        XCTAssertEqual(saved.importantTopicsList, ["launch"])
        XCTAssertEqual(saved.privacyOverride, "local_only")
        XCTAssertEqual(saved.tone, "concise")

        appState.saveConversationPrivacyOverride(service: "signal", conversationId: "c1", privacyOverride: nil)
        saved = try XCTUnwrap(repo.fetchConversationContext(service: "signal", conversationId: "c1"))
        XCTAssertNil(saved.privacyOverride)
        XCTAssertEqual(saved.label, "client")
        XCTAssertEqual(saved.tone, "concise")
    }

    // MARK: - Chaos test: corrupt JSON in every nullable field
    //
    // Worst-case DB state: every JSON-bearing field holds invalid data.
    // The full frontend lifecycle (refreshBriefs → select → loadBrief → markAsOpen) must complete
    // without crashing. The backend must degrade gracefully, never panic the UI.

    func testFullLifecycleWithAllCorruptNullableFieldsDoesNotCrash() async throws {
        let db = try makeDB()

        // Insert a Brief where every JSON/optional field holds garbage
        let briefId = try await db.dbQueue.write { d -> Int64 in
            try d.execute(
                sql: """
                    INSERT INTO briefs (createdAt, status, services, failedServices,
                                        openingSummary, notificationText, episodicSummary)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [Date(), "ready",
                            "NOT_JSON_ARRAY",        // briefServices() returns []
                            "<<<CORRUPT>>>",          // failedServices is displayed as-is
                            "{{{invalid",             // openingSummary shown as-is
                            "ok",
                            "[}broken"]               // episodicSummary shown as-is
            )
            return d.lastInsertedRowID
        }

        // Inject BriefCardRecord with corrupt JSON in both JSON fields
        try await insertBriefCardDirect(db: db, briefId: briefId,
                                        actionItems: "CORRUPT",
                                        sourceMessageIds: "CORRUPT")

        // Attach a message so loadBrief has data to display
        try await db.dbQueue.write { d in
            var msg = Message(briefId: briefId, service: "signal",
                              conversationId: "c1", messageId: "m1",
                              sender: "Alice", text: "Hi",
                              timestamp: Date(), isSent: false)
            try msg.insert(d)
        }

        let appState = makeAppState(db: db)

        // Step 1: refreshBriefs must not crash with corrupt Brief fields
        await appState.refreshBriefs().value
        XCTAssertEqual(appState.briefs.count, 1,
                       "refreshBriefs must load briefs even with corrupt JSON fields")

        // Step 2: selectedBrief must resolve from selectedBriefID
        appState.selectedBriefID = briefId
        let brief = try XCTUnwrap(appState.selectedBrief,
                                   "selectedBrief must resolve even when the Brief's JSON fields are corrupt")

        // Step 3: loadBrief must not crash on brief.id! (the only UI force-unwrap)
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)

        // Step 4: markAsOpen must not crash
        await appState.markAsOpen(briefID: briefId).value
        XCTAssertEqual(appState.briefs.first?.briefStatus, .open,
                       "markAsOpen must succeed in the chaos scenario — corrupt JSON must not block status update")

        // Step 5: unreadCount must be >= 0 — no crash from corrupt services JSON
        XCTAssertGreaterThanOrEqual(appState.unreadCount, 0,
                                    "unreadCount must remain non-negative regardless of corrupt DB state")
    }
}
