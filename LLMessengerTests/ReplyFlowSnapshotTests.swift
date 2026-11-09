// LLMessengerTests/ReplyFlowSnapshotTests.swift
//
// Renders the reply flow to docs/design/snapshots/<tag>/reply-*.png: the Reply
// composer (1:1, group, read-only WhatsApp, with an AI draft), the Act queue
// (a failed send, an external-agent proposal, a send counting down, caught up)
// and the Ask panel with a "Review and send…" draft. Same renderer as
// DesignSnapshotTests. In-memory DB, no adapters, nothing is sent.

import XCTest
import SwiftUI
import AppKit
@testable import LLMessenger

@MainActor
final class ReplyFlowSnapshotTests: XCTestCase {

    // MARK: - Fixture

    private func makeState() throws -> AppState {
        let db = try AppDatabase(inMemory: true)
        let defaults = UserDefaults(suiteName: "ReplyFlowSnapshotTests-\(UUID().uuidString)")!
        let state = AppState(database: db, llmClient: UnconfiguredLLMClient(), llmModel: "fixture",
                             isLLMConfigured: true, basePrompt: "", defaults: defaults)
        state.replyHandOff = { _, _ in }
        state.serviceHealth = ["imessage": .ok, "signal": .ok, "telegram": .ok, "slack": .ok, "whatsapp": .ok]
        return state
    }

    private func seed(_ state: AppState, service: String, conv: String, name: String,
                      _ lines: [(sender: String, text: String, minutesAgo: Double, sent: Bool)]) throws {
        try state.database.dbQueue.write { d in
            for line in lines {
                var m = Message(id: nil, briefId: nil, service: service, conversationId: conv,
                                conversationName: name, messageId: "\(conv)-\(UUID().uuidString)",
                                sender: line.sender, text: line.text,
                                timestamp: Date().addingTimeInterval(-line.minutesAgo * 60), isSent: line.sent)
                try m.insert(d)
            }
        }
    }

    private func action(_ name: String, _ service: String, _ conv: String, _ draft: String,
                        reasoning: String = "You owe a reply; her question is unanswered.",
                        risk: AgentActionRisk = .normal, id: Int64, minutesAgo: Double = 40) -> AgentAction {
        AgentAction(id: id, kind: AgentActionKind.reply.rawValue, service: service, conversationId: conv,
                    conversationName: name, title: "Reply", payload: AgentAction.encodeReplyPayload(draft),
                    reasoning: reasoning, confidence: 0.75, riskLevel: risk.rawValue,
                    status: AgentActionStatus.pending.rawValue,
                    createdAt: Date().addingTimeInterval(-minutesAgo * 60), resolvedAt: nil)
    }

    private var waitingOn: [Commitment] {
        [Commitment(id: 2, direction: CommitmentDirection.theyOwe.rawValue, service: "slack",
                    conversationId: "ops-1", conversationName: "#launch-room",
                    what: "post the incident postmortem", dueAt: nil, evidenceMessageId: nil,
                    status: CommitmentStatus.open.rawValue, createdAt: Date()),
         Commitment(id: 3, direction: CommitmentDirection.iOwe.rawValue, service: "signal",
                    conversationId: "ts-1", conversationName: "Anna Keller",
                    what: "send the revised cap table", dueAt: nil, evidenceMessageId: nil,
                    status: CommitmentStatus.open.rawValue, createdAt: Date())]
    }

    // MARK: - Renderer (mirrors DesignSnapshotTests.render)

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
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        hosting.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("Could not create bitmap rep for \(name)")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG encode failed for \(name)")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try png.write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    private func composer(_ state: AppState) throws -> some View {
        let request = try XCTUnwrap(state.replyComposer)
        return ReplyComposerView(request: request, appState: state)
            .environmentObject(state)
    }

    // MARK: - Composer

    func testSnapshotComposerOneToOne() throws {
        let state = try makeState()
        try seed(state, service: "signal", conv: "+4915112345", name: "Anna Keller", [
            ("Anna Keller", "Partner meeting moved to Thu 10:00.", 52, false),
            ("Anna Keller", "Can you get me the updated cap table by Wed EOD?", 50, false),
        ])
        state.openReplyComposer(service: "signal", conversationId: "+4915112345", conversationName: "Anna Keller")
        let size = NSSize(width: 540, height: 470)
        try render(try composer(state), size: size, name: "reply-composer-signal")
        try render(try composer(state), size: size, name: "reply-composer-signal-light", appearance: .aqua)
    }

    func testSnapshotComposerGroup() throws {
        let state = try makeState()
        try seed(state, service: "telegram", conv: "bball-parents", name: "Basketball Parents", [
            ("Coach Petra", "Training moved to Thursday 6pm this week.", 70, false),
            ("Marek", "Works for us 👍", 66, false),
            ("Coach Petra", "Can your son make it? Need numbers by tonight.", 64, false),
        ])
        state.openReplyComposer(service: "telegram", conversationId: "bball-parents",
                                conversationName: "Basketball Parents",
                                text: "Yes, he'll be there Thursday at 6.")
        try render(try composer(state), size: NSSize(width: 540, height: 510), name: "reply-composer-group")
    }

    func testSnapshotComposerWhatsAppReadOnly() throws {
        let state = try makeState()
        try seed(state, service: "whatsapp", conv: "120363@g.us", name: "Flat 4B", [
            ("Jonas", "Who's taking the bins out this week?", 30, false),
        ])
        state.openReplyComposer(service: "whatsapp", conversationId: "120363@g.us", conversationName: "Flat 4B",
                                text: "I'll do it tonight.")
        let size = NSSize(width: 540, height: 470)
        try render(try composer(state), size: size, name: "reply-composer-whatsapp")
        try render(try composer(state), size: size, name: "reply-composer-whatsapp-light", appearance: .aqua)
    }

    func testSnapshotComposerWithAIDraft() throws {
        let state = try makeState()
        try seed(state, service: "imessage", conv: "any;-;+4917000", name: "Mum", [
            ("Mum", "Can you pick up wine on the way Sunday?", 180, false),
            ("Mum", "And is 1pm still good for you?", 179, false),
        ])
        state.openReplyComposer(service: "imessage", conversationId: "any;-;+4917000", conversationName: "Mum",
                                text: "Yes, 1pm works! I'll grab a bottle of red on the way — see you Sunday 🙂")
        try render(try composer(state), size: NSSize(width: 540, height: 470), name: "reply-composer-ai-draft")
    }

    // MARK: - Act

    private func act(_ state: AppState, height: CGFloat, name: String,
                     appearance: NSAppearance.Name = .darkAqua) throws {
        let chat = state.makeChatViewModel()
        let view = ActWorkspaceView()
            .environmentObject(state)
            .environmentObject(chat)
            .frame(width: 760, height: height)
            .background(Theme.bg)
        try render(view, size: NSSize(width: 760, height: height), name: name, appearance: appearance)
    }

    func testSnapshotActFailedSend() throws {
        let state = try makeState()
        var failed = action("#launch-room", "slack", "ops-1", "Got it — reviewing now, will sign off by 3.", id: 11)
        failed.status = AgentActionStatus.failed.rawValue
        failed.resolvedAt = Date()
        state.failedSends = [failed]
        state.sendFailureReasons = [11: "Slack refused the request — reconnect it in Settings."]
        state.agentActions = [action("Mum", "imessage", "fam-mum", "yeah 1pm works! i'll grab the wine on the way 🙂", id: 12)]
        try act(state, height: 420, name: "reply-act-failed")
        try act(state, height: 420, name: "reply-act-failed-light", appearance: .aqua)
    }

    func testSnapshotActExternalProposal() throws {
        let state = try makeState()
        state.agentActions = [
            action("Anna Keller", "signal", "ts-1", "Confirmed — the cap table will be in your inbox by Wednesday 5pm.",
                   reasoning: AgentAction.externalAgentReasoning, id: 21),
            action("Dad", "imessage", "fam-1", "1pm Sunday works, see you there.", id: 22),
        ]
        try act(state, height: 380, name: "reply-act-external")
    }

    func testSnapshotActCountingDown() throws {
        let state = try makeState()
        var staged = AgentAction.userComposed(service: "signal", conversationId: "ts-1", conversationName: "Anna Keller",
                                              text: "On it — sending the updated cap table by Wednesday EOD.",
                                              commitmentId: nil)
        staged.id = 31
        staged.status = AgentActionStatus.scheduled.rawValue
        staged.scheduledKind = AgentActionScheduleKind.manual.rawValue
        staged.scheduledWindow = AgentAction.manualApproveUndoWindow
        staged.scheduledAt = Date().addingTimeInterval(3.4)
        state.agentActions = [staged, action("Dad", "imessage", "fam-1", "1pm Sunday works, see you there.", id: 32)]
        try act(state, height: 340, name: "reply-act-countdown")
    }

    func testSnapshotActCaughtUp() throws {
        let state = try makeState()
        state.briefs = [Brief(id: 1, createdAt: Date(), status: "open", services: #"["signal"]"#,
                              notificationText: "x")]
        state.agentActions = [action("Old group", "telegram", "club-1", "Sounds good, count me in for the 28th.",
                                     reasoning: "Unanswered question.", id: 41, minutesAgo: 3 * 24 * 60)]
        state.commitments = waitingOn
        try act(state, height: 520, name: "reply-act-caught-up")
        try act(state, height: 520, name: "reply-act-caught-up-light", appearance: .aqua)
    }

    // MARK: - Ask panel

    func testSnapshotAskReviewAndSend() throws {
        let state = try makeState()
        let chat = state.makeChatViewModel()
        let draft = ReplyDraft(id: UUID(), text: "Thanks coach — he'll be there Thursday 6pm 👍",
                               serviceID: "telegram", conversationID: "bball-parents",
                               senderName: "Basketball Parents",
                               provenance: "Based on 6 recent local messages · 4 of your sent messages for tone · nothing has been sent.")
        chat.threadItems = [
            .userMessage(id: UUID(), text: "write to the basketball parents that he can make Thursday"),
            .replyDraft(id: draft.id, draft: draft),
        ]
        let view = VStack(spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    WireLabel("Ask about your messages")
                    Rule()
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 14)
                .padding(.bottom, 4)
                UserMessageView(text: "write to the basketball parents that he can make Thursday")
                ReplyDraftView(draftID: draft.id, draft: draft)
            }
            .padding(.bottom, 8)
            .background(Theme.surface.opacity(0.35))
            }
            Rule()
            ChatInputView()
        }
        .environmentObject(state)
        .environmentObject(chat)
        .environmentObject(state.contactDirectory)
        .frame(width: 760, height: 420)
        .background(Theme.bg)
        try render(view, size: NSSize(width: 760, height: 420), name: "reply-ask-review")
    }
}
