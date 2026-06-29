// LLMessengerTests/DesignSnapshotTests.swift
//
// Offscreen UI snapshot harness. Renders the main surfaces with golden fixture
// data into PNGs under docs/design/snapshots/<tag>/ so design changes can be
// reviewed (and regression-checked) without launching the app or exposing real
// message content.
//
// Run:  TEST_RUNNER_SNAPSHOT_TAG=before xcodebuild test \
//         -scheme LLMessenger -only-testing:LLMessengerTests/DesignSnapshotTests
// Tag defaults to "current".

import XCTest
import SwiftUI
import AppKit
@testable import LLMessenger

@MainActor
final class DesignSnapshotTests: XCTestCase {

    // MARK: - Fixture

    /// A founder's Tuesday morning: one urgent term-sheet thread, one ops
    /// heads-up, two FYIs. Shapes match PromptBuilder's summarizer schema.
    private static let fixtureBriefJSON = """
    {
      "total_messages": 47,
      "total_threads": 6,
      "total_people": 14,
      "cards": [
        {
          "id": "signal-ts-1",
          "service": "signal",
          "conversationId": "ts-1",
          "conversationTitle": "Meridian — Series B",
          "headline": "Anna needs the revised cap table before Thursday's partner meeting",
          "priority": "high",
          "counts": {"messages": 12, "threads": 1, "people": 3},
          "summary": "Anna confirmed the partner meeting moved up to Thursday 10:00. She asked for the cap table with the option-pool change and flagged that Marcus still hasn't received data-room access. Tone is positive — she called the metrics deck 'the strongest in this batch'.",
          "callback": "Last brief: you promised the updated deck by Friday — it shipped Thursday night.",
          "needsReply": true,
          "reason": "Deadline Wednesday EOD",
          "grounding": "context",
          "actionItems": ["Send revised cap table to Anna", "Grant Marcus data-room access"],
          "quotes": [
            {"messageId": "m101", "from": "Anna Keller", "time": "08:42", "text": "Partner meeting moved to Thu 10:00 — can you get me the updated cap table by Wed EOD?"},
            {"messageId": "m102", "from": "Anna Keller", "time": "08:44", "text": "Also Marcus says he still can't open the data room."}
          ],
          "sourceMessageIds": ["m101", "m102", "m103"]
        },
        {
          "id": "slack-ops-1",
          "service": "slack",
          "conversationId": "ops-1",
          "conversationTitle": "#launch-room",
          "headline": "Staging incident resolved — postmortem doc expected today",
          "priority": "med",
          "counts": {"messages": 23, "threads": 3, "people": 7},
          "summary": "The 40-minute staging outage traced to a misconfigured rate limit on the new ingest service. Priya rolled it back at 07:15 and owns the postmortem. No customer impact; launch timeline unaffected.",
          "callback": null,
          "needsReply": true,
          "reason": "Postmortem review expected today",
          "grounding": "direct",
          "actionItems": ["Review Priya's postmortem when it lands"],
          "quotes": [
            {"messageId": "m201", "from": "Priya Sharma", "time": "07:16", "text": "Rolled back. Root cause: rate limiter config, not the migration. Postmortem by EOD."}
          ],
          "sourceMessageIds": ["m201", "m202"]
        },
        {
          "id": "imessage-fam-1",
          "service": "imessage",
          "conversationId": "fam-1",
          "conversationTitle": "Dad",
          "headline": "Dad confirmed Sunday lunch, asks if 1pm works",
          "priority": "low",
          "counts": {"messages": 4, "threads": 1, "people": 2},
          "summary": "Sunday lunch is on. He suggested 1pm at the usual place and mentioned he fixed the boat trailer.",
          "callback": null,
          "needsReply": true,
          "reason": "Direct question about Sunday lunch",
          "grounding": "direct",
          "actionItems": ["Confirm whether 1pm works for Sunday lunch"],
          "quotes": [],
          "sourceMessageIds": ["m301"]
        },
        {
          "id": "telegram-club-1",
          "service": "telegram",
          "conversationId": "club-1",
          "conversationTitle": "Sailing Club",
          "headline": "Regatta moved to the 28th — no action needed",
          "priority": "low",
          "counts": {"messages": 8, "threads": 1, "people": 5},
          "summary": "Race committee moved the regatta a week out due to the harbour dredging schedule. Crew assignments unchanged.",
          "callback": null,
          "needsReply": false,
          "reason": "FYI announcement only",
          "grounding": "direct",
          "actionItems": [],
          "quotes": [],
          "sourceMessageIds": ["m401"]
        }
      ]
    }
    """

    private func makeFixtureState() throws -> AppState {
        let db = try AppDatabase(inMemory: true)
        let state = AppState(
            database: db,
            llmClient: UnconfiguredLLMClient(),
            llmModel: "fixture",
            isLLMConfigured: true,
            basePrompt: ""
        )

        let cal = Calendar.current
        let now = Date()
        func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: now)!
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }

        state.briefs = [
            Brief(id: 1, createdAt: at(9, 12), status: "open",
                  services: #"["signal","slack","imessage","telegram"]"#,
                  openingSummary: Self.fixtureBriefJSON,
                  notificationText: "1 action needed",
                  windowStart: at(7, 0)),
            Brief(id: 2, createdAt: at(8, 0), status: "open",
                  services: #"["signal","slack"]"#,
                  notificationText: "Nothing urgent"),
            Brief(id: 3, createdAt: at(21, 30, daysAgo: 1), status: "open",
                  services: #"["imessage"]"#,
                  notificationText: "2 briefs"),
            Brief(id: 4, createdAt: at(17, 5, daysAgo: 1), status: "ready",
                  services: #"["slack","telegram"]"#,
                  notificationText: "Quiet afternoon"),
        ]
        state.selectedBriefID = 1
        state.serviceHealth = ["imessage": .ok, "signal": .ok, "telegram": .ok, "slack": .ok]
        state.nextPollDate = now.addingTimeInterval(23 * 60 + 14)

        // v2.0 Owed Replies fixture — people waiting on you, ranked by who matters.
        func ago(_ days: Int) -> Date { cal.date(byAdding: .day, value: -days, to: now)! }
        state.owedReplies = [
            OwedReply(service: "imessage", conversationId: "fam-mum", conversationName: "Mum",
                      triggerMessageId: "o1",
                      triggerText: "Can you pick up wine on the way Sunday? And is 1pm still good for you?",
                      triggeredAt: ago(3), reason: "unanswered question", priorityRank: 3),
            OwedReply(service: "telegram", conversationId: "bball-parents", conversationName: "Basketball Parents",
                      triggerMessageId: "o2",
                      triggerText: "Coach: training moved to Thursday 6pm this week — can your son make it?",
                      triggeredAt: ago(1), reason: "needs reply", priorityRank: 3),
            OwedReply(service: "signal", conversationId: "ts-1", conversationName: "Anna — Meridian",
                      triggerMessageId: "o3",
                      triggerText: "Partner meeting moved to Thu 10:00 — can you get me the updated cap table by Wed EOD?",
                      triggeredAt: ago(1), reason: "unanswered question", priorityRank: 2),
            OwedReply(service: "slack", conversationId: "ops-1", conversationName: "#launch-room",
                      triggerMessageId: "o4",
                      triggerText: "Priya: postmortem is up — want you to sign off before we send to the team.",
                      triggeredAt: ago(2), reason: "needs reply", priorityRank: 1),
        ]
        state.owedCount = state.owedReplies.count

        // v2.1 "Act" fixture — the agent's prepared action queue.
        func reply(_ name: String, _ svc: String, _ conv: String, _ title: String,
                   _ draft: String, _ why: String, risk: String, conf: Double) -> AgentAction {
            AgentAction(
                id: nil, kind: AgentActionKind.reply.rawValue, service: svc,
                conversationId: conv, conversationName: name, title: title,
                payload: #"{"draftText":"\#(draft)"}"#,
                reasoning: why, confidence: conf, riskLevel: risk,
                status: AgentActionStatus.pending.rawValue, createdAt: now, resolvedAt: nil)
        }
        state.agentActions = [
            reply("Mum", "imessage", "fam-mum", "Reply — confirm Sunday + wine",
                  "yeah 1pm works! i'll grab the wine on the way 🙂", "You owe a reply; her question is unanswered.",
                  risk: "normal", conf: 0.74),
            reply("Basketball Parents", "telegram", "bball-parents", "Reply Coach — Thursday training",
                  "Thanks coach — he'll be there Thursday 6pm 👍", "Key sender (Coach); needs a yes/no.",
                  risk: "low", conf: 0.83),
            reply("#launch-room", "slack", "ops-1", "Acknowledge Priya's postmortem",
                  "Got it — reviewing now, will sign off shortly.", "Low-risk acknowledgement; you usually ack these fast.",
                  risk: "low", conf: 0.81),
            reply("Anna — Meridian", "signal", "ts-1", "Reply — cap table by Wed",
                  "On it — sending the updated cap table by Wednesday EOD.", "Owed reply; commitment due Wed.",
                  risk: "normal", conf: 0.69),
        ]
        // v2.2 — persistent to-do strip fixture: open commitments + tasks + one "maybe".
        state.commitments = [
            Commitment(id: 1, direction: CommitmentDirection.iOwe.rawValue, service: "signal",
                       conversationId: "ts-1", conversationName: "Anna — Meridian",
                       what: "send the revised cap table", dueAt: at(18, 0), evidenceMessageId: nil,
                       status: CommitmentStatus.open.rawValue, createdAt: at(8, 44)),
            Commitment(id: 2, direction: CommitmentDirection.theyOwe.rawValue, service: "slack",
                       conversationId: "ops-1", conversationName: "#launch-room",
                       what: "post the incident postmortem", dueAt: nil, evidenceMessageId: nil,
                       status: CommitmentStatus.open.rawValue, createdAt: at(7, 16)),
        ]
        state.commitmentsCount = state.commitments.count
        // Flip the lowest-confidence reply to a "maybe" so the strip's Maybe bucket renders.
        if let last = state.agentActions.indices.last {
            state.agentActions[last].isMaybe = true
        }
        state.actionsReadyCount = state.agentActions.filter { !$0.isMaybe }.count
        return state
    }

    // MARK: - Renderer

    private var outputDir: URL {
        let tag = ProcessInfo.processInfo.environment["SNAPSHOT_TAG"] ?? "current"
        let testsDir = URL(fileURLWithPath: String(#filePath)).deletingLastPathComponent()
        return testsDir.deletingLastPathComponent()
            .appendingPathComponent("docs/design/snapshots/\(tag)", isDirectory: true)
    }

    private func render<V: View>(_ view: V, size: NSSize, name: String,
                                 appearance: NSAppearance.Name = .darkAqua) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: appearance)
        hosting.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = hosting

        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI commit async layout/animation passes before capture.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("Could not create bitmap rep for \(name)")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG encode failed for \(name)")
        }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let url = outputDir.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("SNAPSHOT WROTE: \(url.path)")
    }

    // MARK: - Tests

    func testSnapshotMainWindow() throws {
        let state = try makeFixtureState()
        let chat = state.makeChatViewModel()
        let view = ContentView()
            .environmentObject(state)
            .environmentObject(chat)
            .frame(width: 1180, height: 780)
            .background(Theme.bg)
        try render(view, size: NSSize(width: 1180, height: 780), name: "main-window")
    }

    func testSnapshotSidebar() throws {
        let state = try makeFixtureState()
        let chat = state.makeChatViewModel()
        let view = BriefListView()
            .environmentObject(state)
            .environmentObject(chat)
            .frame(width: 260, height: 700)
            .background(Theme.sidebar)
        try render(view, size: NSSize(width: 260, height: 700), name: "sidebar")
    }

    /// End-to-end: renders the window from a DemoSeeder-seeded database via
    /// the real read path (fetchAllBriefs → JSON decode → needs-reply join),
    /// exactly what a first-time user sees after "Explore the demo desk".
    func testSnapshotDemoMode() async throws {
        defer { UserDefaults.standard.removeObject(forKey: DemoSeeder.demoFlagKey) }
        let db = try AppDatabase(inMemory: true)
        try DemoSeeder.seed(into: db)

        let state = AppState(database: db, llmClient: UnconfiguredLLMClient(),
                             llmModel: "demo", isLLMConfigured: false, basePrompt: "")
        await state.refreshBriefs().value
        state.selectedBriefID = try BriefRepository(database: db).latestBriefID()
        state.serviceHealth = [:]

        let chat = state.makeChatViewModel()
        let main = ContentView()
            .environmentObject(state)
            .environmentObject(chat)
            .frame(width: 1180, height: 780)
            .background(Theme.bg)
        try render(main, size: NSSize(width: 1180, height: 780), name: "demo-mode")

        let sidebar = BriefListView()
            .environmentObject(state)
            .environmentObject(chat)
            .frame(width: 260, height: 700)
            .background(Theme.sidebar)
        try render(sidebar, size: NSSize(width: 260, height: 700), name: "demo-sidebar")
    }

    func testSnapshotEmptyState() throws {
        let state = try makeFixtureState()
        state.selectedBriefID = nil
        state.briefs = []
        let chat = state.makeChatViewModel()
        let view = ContentView()
            .environmentObject(state)
            .environmentObject(chat)
            .frame(width: 1180, height: 780)
            .background(Theme.bg)
        try render(view, size: NSSize(width: 1180, height: 780), name: "empty-state")
    }

    /// v2.1 headline: the Act surface — the agent's prepared action queue.
    func testSnapshotAct() throws {
        let state = try makeFixtureState()
        let chat = state.makeChatViewModel()
        let view = DeskView()
            .environmentObject(state)
            .environmentObject(chat)
            .frame(width: 760, height: 300)
            .background(Theme.bg)
        try render(view, size: NSSize(width: 760, height: 300), name: "act")
    }

    /// v2.0 headline: the Owed Replies surface inside the real Desk chrome —
    /// "who's waiting on you?", ranked by who matters.
    func testSnapshotOwed() throws {
        let state = try makeFixtureState()
        let chat = state.makeChatViewModel()
        let view = DeskView()
            .environmentObject(state)
            .environmentObject(chat)
            .frame(width: 760, height: 560)
            .background(Theme.bg)
        try render(view, size: NSSize(width: 760, height: 560), name: "owed")
    }

    /// Light mode (new since the last screenshots) — same reading surface.
    func testSnapshotLightMode() throws {
        let state = try makeFixtureState()
        let chat = state.makeChatViewModel()
        let view = ContentView()
            .environmentObject(state)
            .environmentObject(chat)
            .frame(width: 1180, height: 780)
            .background(Theme.bg)
        try render(view, size: NSSize(width: 1180, height: 780),
                   name: "light-mode", appearance: .aqua)
    }
}
