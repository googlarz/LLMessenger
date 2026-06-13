// LLMessengerTests/DelegationTests.swift
//
// Exhaustive guard coverage for AgentDelegation.decide — the ONLY function that
// may authorize the app's first programmatic auto-send. Every guard gets a test
// that proves it BLOCKS when violated, plus the single happy path.

import XCTest
@testable import LLMessenger

final class DelegationTests: XCTestCase {

    // A fresh, isolated UserDefaults so kill-switch tests never touch standard.
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "DelegationTests-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: d.dictionaryRepresentation().description)
        return d
    }

    private func action(kind: AgentActionKind = .ack,
                        risk: AgentActionRisk = .low,
                        confidence: Double = 0.9,
                        payload: String = "Got it, thanks!") -> AgentAction {
        AgentAction(
            id: 1, kind: kind.rawValue, service: "signal", conversationId: "c1",
            conversationName: "Coach", title: "Ack", payload: payload,
            reasoning: "templated", confidence: confidence, riskLevel: risk.rawValue,
            status: AgentActionStatus.pending.rawValue, createdAt: Date(), resolvedAt: nil)
    }

    private func context(delegated: [AgentActionKind] = [.ack],
                         privacy: String? = nil) -> ConversationContext {
        var ctx = ConversationContext(service: "signal", conversationId: "c1",
                                      label: "", priorityHint: "auto", updatedAt: Date(),
                                      privacyOverride: privacy)
        ctx.delegationKinds = delegated.map { $0.rawValue }
        return ctx
    }

    // MARK: - Happy path

    func testHappyPathAcksKnownRecipientAutoSends() {
        let d = decide(action: action(), context: context())
        XCTAssertTrue(d.autoSend, d.reason)
    }

    // MARK: - One blocking test per guard

    func testNonDelegatableKindBlocks() {
        // reply is never delegatable, even if "delegated" and low risk.
        let d = decide(action: action(kind: .reply), context: context(delegated: [.reply]))
        XCTAssertFalse(d.autoSend)
    }

    func testKindNotDelegatedForConversationBlocks() {
        let d = decide(action: action(kind: .ack), context: context(delegated: [.rsvp]))
        XCTAssertFalse(d.autoSend)
    }

    func testNoContextBlocks() {
        let d = AgentDelegation.decide(action: action(), context: nil,
                                       isKnownRecipient: true, clientIsLocal: true,
                                       defaults: defaults())
        XCTAssertFalse(d.autoSend)
    }

    func testRiskNotLowBlocks() {
        let d = decide(action: action(risk: .normal), context: context())
        XCTAssertFalse(d.autoSend)
    }

    func testConfidenceBelowThresholdBlocks() {
        let d = decide(action: action(confidence: 0.79), context: context())
        XCTAssertFalse(d.autoSend)
    }

    func testUnknownRecipientBlocks() {
        let d = AgentDelegation.decide(action: action(), context: context(),
                                       isKnownRecipient: false, clientIsLocal: true,
                                       defaults: defaults())
        XCTAssertFalse(d.autoSend)
    }

    func testPayloadWithUrlBlocks() {
        let d = decide(action: action(payload: "sure, see https://evil.example"), context: context())
        XCTAssertFalse(d.autoSend)
    }

    func testPayloadWithMoneyBlocks() {
        let d = decide(action: action(payload: "send me $40"), context: context())
        XCTAssertFalse(d.autoSend)
    }

    func testNeverDraftBlocks() {
        let d = decide(action: action(), context: context(privacy: "never_draft"))
        XCTAssertFalse(d.autoSend)
    }

    func testLocalOnlyWithCloudClientBlocks() {
        let d = AgentDelegation.decide(action: action(), context: context(privacy: "local_only"),
                                       isKnownRecipient: true, clientIsLocal: false,
                                       defaults: defaults())
        XCTAssertFalse(d.autoSend)
    }

    func testLocalOnlyWithLocalClientPasses() {
        let d = AgentDelegation.decide(action: action(), context: context(privacy: "local_only"),
                                       isKnownRecipient: true, clientIsLocal: true,
                                       defaults: defaults())
        XCTAssertTrue(d.autoSend, d.reason)
    }

    // MARK: - Kill switches

    func testKillSwitchBlocks() {
        let d = defaults()
        d.set(true, forKey: AgentDelegation.killSwitchKey)
        let r = AgentDelegation.decide(action: action(), context: context(),
                                       isKnownRecipient: true, clientIsLocal: true, defaults: d)
        XCTAssertFalse(r.autoSend)
    }

    func testAgentDisabledBlocks() {
        let d = defaults()
        d.set(true, forKey: "agentDisabled")
        let r = AgentDelegation.decide(action: action(), context: context(),
                                       isKnownRecipient: true, clientIsLocal: true, defaults: d)
        XCTAssertFalse(r.autoSend)
    }

    // MARK: - Helper

    private func decide(action: AgentAction, context: ConversationContext?) -> DelegationDecision {
        AgentDelegation.decide(action: action, context: context,
                               isKnownRecipient: true, clientIsLocal: true, defaults: defaults())
    }
}
