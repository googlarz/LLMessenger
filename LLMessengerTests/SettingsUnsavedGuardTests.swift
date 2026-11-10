// LLMessengerTests/SettingsUnsavedGuardTests.swift
//
// Closing Settings with unsaved credentials or prompts asks first (Save / Discard /
// Cancel); a failed save keeps the window open; a clean window closes without a prompt.

import XCTest
import AppKit
@testable import LLMessenger

@MainActor
final class SettingsUnsavedGuardTests: XCTestCase {

    @MainActor
    private final class Fixture {
        var dirty = true
        var saveWorks = true
        var saved = 0, discarded = 0, asked = 0
        let guardian = SettingsUnsavedGuard()
        init() {
            guardian.hasUnsaved = { [unowned self] in dirty }
            guardian.saveAll = { [unowned self] in saved += 1; if saveWorks { dirty = false } }
            guardian.discardAll = { [unowned self] in discarded += 1; dirty = false }
        }
        func close(_ choice: SettingsUnsavedGuard.Choice) -> Bool {
            guardian.shouldClose { asked += 1; return choice }
        }
    }

    func testCleanWindowClosesWithoutAsking() {
        let f = Fixture(); f.dirty = false
        XCTAssertTrue(f.close(.cancel))
        XCTAssertEqual(f.asked, 0)
    }

    func testCancelKeepsTheWindowAndTheTypedValues() {
        let f = Fixture()
        XCTAssertFalse(f.close(.cancel))
        XCTAssertEqual(f.asked, 1)
        XCTAssertEqual(f.saved + f.discarded, 0)
        XCTAssertTrue(f.dirty)
    }

    func testSaveThenClose() {
        let f = Fixture()
        XCTAssertTrue(f.close(.save))
        XCTAssertEqual(f.saved, 1)
        XCTAssertEqual(f.discarded, 0)
    }

    func testFailedSaveKeepsTheWindowOpen() {
        let f = Fixture(); f.saveWorks = false
        XCTAssertFalse(f.close(.save), "the typed values must survive a save that failed")
        XCTAssertTrue(f.dirty)
    }

    func testDiscardThenClose() {
        let f = Fixture()
        XCTAssertTrue(f.close(.discard))
        XCTAssertEqual(f.discarded, 1)
        XCTAssertEqual(f.saved, 0)
    }

    func testTheRealModelsAreWiredIntoTheGuard() throws {
        // The models SettingsView registers: unsaved credentials make the window dirty,
        // discard clears them.
        let db = try AppDatabase(inMemory: true)
        let defaults = UserDefaults(suiteName: "SettingsUnsavedGuardTests-\(UUID().uuidString)")!
        let repo = SettingsRepository(keychainStore: KeychainStore(service: "test.guard.\(UUID().uuidString)"),
                                      database: db, userDefaults: defaults)
        let services = ServiceSettingsModel(repo: repo)
        let instructions = InstructionsSettingsModel(repo: repo)
        instructions.values.prompt = "a prompt nobody saved"
        XCTAssertTrue(instructions.isDirty)
        instructions.discard()
        XCTAssertFalse(instructions.isDirty)
        XCTAssertFalse(services.hasUnsavedCredentials)
    }

    func testWindowControllerAsksThroughTheGuardAndClosesWhenClean() throws {
        let controller = SettingsWindowController(database: try AppDatabase(inMemory: true))
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.windowShouldClose(window), "nothing registered or dirty: no prompt, closes")
    }
}
