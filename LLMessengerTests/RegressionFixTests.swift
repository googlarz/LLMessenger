// LLMessengerTests/RegressionFixTests.swift
//
// Regression guards for bugs found via manual code review (see commits
// 2ba90da, 8ca0210, a3cdcc4). Each test reproduces a bug that had no prior
// coverage and would have failed against the pre-fix code.

import XCTest
import AppKit
import SwiftUI
@testable import LLMessenger

// MARK: - Bug: AppState.selectedBriefID didSet leaked draft/reply-target
// across digest navigation. onBriefSelectionChanged must fire exactly when
// selectedBriefID actually changes (not on every write, and not for a
// same-value write).

@MainActor
final class AppStateSelectionCallbackTests: XCTestCase {

    func testOnBriefSelectionChangedFiresWhenSelectionChanges() throws {
        let db = try AppDatabase(inMemory: true)
        let appState = AppState(database: db, llmClient: MockLLMClient(), llmModel: "test", basePrompt: "BASE")

        var fireCount = 0
        appState.onBriefSelectionChanged = { fireCount += 1 }

        appState.selectedBriefID = 1
        XCTAssertEqual(fireCount, 1)

        appState.selectedBriefID = 2
        XCTAssertEqual(fireCount, 2)
    }

    func testOnBriefSelectionChangedDoesNotFireForSameValue() throws {
        let db = try AppDatabase(inMemory: true)
        let appState = AppState(database: db, llmClient: MockLLMClient(), llmModel: "test", basePrompt: "BASE")

        appState.selectedBriefID = 1
        var fireCount = 0
        appState.onBriefSelectionChanged = { fireCount += 1 }

        appState.selectedBriefID = 1 // same value, no real navigation

        XCTAssertEqual(fireCount, 0)
    }
}

// MARK: - Composer draft vs. digest navigation: user navigation clears the
// draft and @-mention target; a selection the app makes itself (refresh
// finishing) must keep what the user is typing.

@MainActor
final class ComposerDraftNavigationTests: XCTestCase {

    private func make() throws -> (AppState, ChatViewModel) {
        let db = try AppDatabase(inMemory: true)
        let appState = AppState(database: db, llmClient: MockLLMClient(), llmModel: "test", basePrompt: "BASE")
        let chat = ChatViewModel(appState: appState)
        appState.clearComposerOnBriefNavigation(chat)
        return (appState, chat)
    }

    private let mention = ChatViewModel.MentionTarget(
        service: "imessage", conversationId: "old", displayName: "Old Contact", isGroup: false
    )

    func testUserNavigationClearsDraftAndMentionTarget() throws {
        let (appState, chat) = try make()
        appState.selectedBriefID = 1
        chat.inputText = "half-typed question"
        chat.pendingTarget = mention

        appState.selectedBriefID = 2

        XCTAssertEqual(chat.inputText, "")
        XCTAssertNil(chat.pendingTarget)
    }

    func testRefreshSelectionKeepsDraft() throws {
        let (appState, chat) = try make()
        appState.selectedBriefID = 1
        chat.inputText = "half-typed question"

        appState.selectBriefKeepingDraft(2)

        XCTAssertEqual(appState.selectedBriefID, 2)
        XCTAssertEqual(chat.inputText, "half-typed question")
    }

    func testPrepareReplyDropsAbandonedMentionTarget() throws {
        let (_, chat) = try make()
        chat.pendingTarget = mention

        chat.prepareReply(service: "imessage", conversationID: "new", displayName: "New Contact")

        XCTAssertNil(chat.pendingTarget, "an old @-mention would redirect this reply to the wrong person")
        XCTAssertEqual(chat.inputText, "write to New Contact: ")
    }
}

// MARK: - Priority rule drafts: catch-all rules are savable, and a catch-all
// suppress is flagged so the UI can confirm before silencing everything.

final class RuleDraftValidationTests: XCTestCase {

    func testCatchAllRuleWithAnActionIsSavable() {
        XCTAssertTrue(RuleDraftValidation.canSave(contact: "", keyword: "", service: "any",
                                                  setPriority: "", suppress: false, alwaysNotify: true))
    }

    func testRuleWithNoConditionAndNoActionIsNotSavable() {
        XCTAssertFalse(RuleDraftValidation.canSave(contact: "", keyword: "", service: "any",
                                                   setPriority: "", suppress: false, alwaysNotify: false))
    }

    func testCatchAllSuppressIsFlagged() {
        XCTAssertTrue(RuleDraftValidation.silencesEverything(contact: "", keyword: "", service: "any", suppress: true))
    }

    func testScopedSuppressIsNotFlagged() {
        XCTAssertFalse(RuleDraftValidation.silencesEverything(contact: "", keyword: "", service: "slack", suppress: true))
        XCTAssertFalse(RuleDraftValidation.silencesEverything(contact: "Bob", keyword: "", service: "any", suppress: true))
    }
}

// MARK: - Undo cancels the send the user staged last.

final class UndoTargetSelectionTests: XCTestCase {

    private func scheduled(_ name: String, createdAt: Date, firesAt: Date,
                           kind: AgentActionScheduleKind) -> AgentAction {
        var action = AgentAction(
            id: nil, kind: AgentActionKind.reply.rawValue, service: "imessage",
            conversationId: name, conversationName: name, title: name,
            payload: AgentAction.encodeReplyPayload("hi"), reasoning: "fixture",
            confidence: 0.9, riskLevel: AgentActionRisk.low.rawValue,
            status: AgentActionStatus.scheduled.rawValue, createdAt: createdAt, resolvedAt: nil
        )
        action.scheduledAt = firesAt
        action.scheduledKind = kind.rawValue
        return action
    }

    func testPicksLatestStagedNotLatestFiringOrCreated() {
        let now = Date()
        // Delegated: staged at now-20s (fires now+10s, 30s window), created most recently.
        let delegated = scheduled("delegated", createdAt: now, firesAt: now.addingTimeInterval(10), kind: .delegated)
        // Manual: staged at now-2s (fires now+3s, 5s window) — the one the user just approved.
        let manual = scheduled("manual", createdAt: now.addingTimeInterval(-3600),
                               firesAt: now.addingTimeInterval(3), kind: .manual)

        XCTAssertEqual(AgentAction.mostRecentlyStaged(in: [delegated, manual])?.conversationId, "manual")
    }

    func testIgnoresActionsThatAreNotScheduled() {
        var pending = scheduled("pending", createdAt: Date(), firesAt: Date().addingTimeInterval(60), kind: .manual)
        pending.status = AgentActionStatus.pending.rawValue
        XCTAssertNil(AgentAction.mostRecentlyStaged(in: [pending]))
    }
}

// MARK: - Bug: MainToolbar's ToolbarSearchField.Coordinator restored
// `selectedSection` to the pre-search section even if the user had manually
// navigated away from .digests while search was active — stomping on their
// manual navigation. Fix: only restore if still on .digests.

@MainActor
final class ToolbarSearchCoordinatorTests: XCTestCase {

    private func makeField(selectedSection: Binding<AppSection>) -> ToolbarSearchField {
        let db = try! AppDatabase(inMemory: true)
        let appState = AppState(database: db, llmClient: MockLLMClient(), llmModel: "test", basePrompt: "BASE")
        return ToolbarSearchField(appState: appState, selectedSection: selectedSection)
    }

    private func typeAndClear(_ coordinator: ToolbarSearchField.Coordinator, text: String) {
        let searchField = NSSearchField()
        searchField.stringValue = text
        let notification = Notification(name: NSControl.textDidChangeNotification, object: searchField)
        coordinator.controlTextDidChange(notification)
    }

    func testRestoresPriorSectionWhenStillOnDigestsAfterSearchCleared() {
        var section = AppSection.act
        let binding = Binding(get: { section }, set: { section = $0 })
        let field = makeField(selectedSection: binding)
        let coordinator = field.makeCoordinator()

        typeAndClear(coordinator, text: "hello") // starts search from .act -> jumps to .digests
        XCTAssertEqual(section, .digests)

        typeAndClear(coordinator, text: "") // clears search, still on .digests -> restore .act
        XCTAssertEqual(section, .act)
    }

    func testDoesNotStompManualNavigationAwayFromDigestsDuringSearch() {
        var section = AppSection.act
        let binding = Binding(get: { section }, set: { section = $0 })
        let field = makeField(selectedSection: binding)
        let coordinator = field.makeCoordinator()

        typeAndClear(coordinator, text: "hello") // starts search from .act -> jumps to .digests
        XCTAssertEqual(section, .digests)

        section = .activity // user manually navigates away while search is active

        typeAndClear(coordinator, text: "") // clearing search must NOT stomp the manual nav
        XCTAssertEqual(section, .activity)
    }
}
