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
          "actionItems": [],
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
        return state
    }

    // MARK: - Renderer

    private var outputDir: URL {
        let tag = ProcessInfo.processInfo.environment["SNAPSHOT_TAG"] ?? "current"
        let testsDir = URL(fileURLWithPath: String(#filePath)).deletingLastPathComponent()
        return testsDir.deletingLastPathComponent()
            .appendingPathComponent("docs/design/snapshots/\(tag)", isDirectory: true)
    }

    private func render<V: View>(_ view: V, size: NSSize, name: String) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
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
}
