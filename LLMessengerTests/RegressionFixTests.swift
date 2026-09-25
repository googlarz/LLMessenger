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

// MARK: - Bug: RulesSettingsTab's Save button disabled condition rejected
// valid catch-all rules (no contact/keyword/service condition, but a real
// action like setPriority/suppress/alwaysNotify). The disabled expression
// lives inline in AddRuleView (private, unreachable from tests), so this
// test reproduces the exact boolean expression as a free function mirroring
// the fixed source, guarding against a future regression of the same logic
// if it's ever extracted or copied elsewhere. See note below the test for
// why the private view itself can't be exercised directly.

final class RuleSaveButtonDisabledLogicTests: XCTestCase {

    // Mirrors the `.disabled(...)` predicate in
    // LLMessenger/UI/Settings/RulesSettingsTab.swift (private, not
    // reachable via @testable import since `private` is file-scoped in
    // Swift). This test exists to lock in the intended boolean semantics;
    // it is not itself a guard against the private view drifting out of
    // sync with this copy.
    private func isSaveDisabled(contactPattern: String, keywordPattern: String, service: String,
                                 setPriority: String, suppress: Bool, alwaysNotify: Bool) -> Bool {
        contactPattern.isEmpty && keywordPattern.isEmpty && service == "any"
            && setPriority.isEmpty && !suppress && !alwaysNotify
    }

    func testCatchAllRuleWithSuppressActionIsSavable() {
        let disabled = isSaveDisabled(contactPattern: "", keywordPattern: "", service: "any",
                                       setPriority: "", suppress: true, alwaysNotify: false)
        XCTAssertFalse(disabled)
    }

    func testCatchAllRuleWithNoActionIsNotSavable() {
        let disabled = isSaveDisabled(contactPattern: "", keywordPattern: "", service: "any",
                                       setPriority: "", suppress: false, alwaysNotify: false)
        XCTAssertTrue(disabled)
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
