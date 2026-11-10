// LLMessengerTests/LegacyRuleOrderTests.swift
//
// Rules saved by 2.4.0 all carry sortOrder 0; the Rules tab shows them renumbered
// 0…n. Editing, adding, deleting or reordering must persist the whole visible order
// in one go, or the untouched rules fall behind the edited one.

import XCTest
import GRDB
@testable import LLMessenger

final class LegacyRuleOrderTests: XCTestCase {

    private static func legacy(_ contact: String, created: TimeInterval) -> PriorityRule {
        PriorityRule(id: nil, contactPattern: contact, keywordPattern: nil, service: nil, setPriority: nil,
                     suppress: false, alwaysNotify: false, sortOrder: 0,
                     createdAt: Date(timeIntervalSince1970: created), quietStart: nil, quietEnd: nil)
    }

    private func storeWithLegacyRules() async throws -> (PriorityRuleStore, AppDatabase) {
        let db = try AppDatabase(inMemory: true)
        try await db.dbQueue.write { d in
            for (name, t) in [("A", 1.0), ("B", 2.0), ("C", 3.0)] {
                let r = Self.legacy(name, created: t)
                try r.insert(d)
            }
        }
        return (PriorityRuleStore(database: db), db)
    }

    private func rawOrder(_ db: AppDatabase) async throws -> [(String?, Int)] {
        try await db.dbQueue.read { d in
            try PriorityRule.fetchAll(d)
                .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
                .map { ($0.contactPattern, $0.sortOrder) }
        }
    }

    func testEditingTheMiddleLegacyRuleKeepsABCAndPersistsDenseOrder() async throws {
        let (store, db) = try await storeWithLegacyRules()
        var shown = try await store.loadAll()
        XCTAssertEqual(shown.map(\.contactPattern), ["A", "B", "C"])

        var edited = shown[1]          // carries its normalised sortOrder 1; A and C are still 0 in the database
        edited.contactPattern = "B2"
        try await store.update(edited)

        shown = try await store.loadAll()
        XCTAssertEqual(shown.map(\.contactPattern), ["A", "B2", "C"])
        let raw = try await rawOrder(db)
        XCTAssertEqual(raw.map(\.1), [0, 1, 2], "the full order is persisted, not just B")
        let stored = try await db.dbQueue.read { try PriorityRule.fetchAll($0) }
        XCTAssertEqual(PriorityRuleOrdering.normalised(stored).map(\.contactPattern), ["A", "B2", "C"])
    }

    func testEvaluationOrderIsStillABCAfterEditing() async throws {
        let db = try AppDatabase(inMemory: true)
        try await db.dbQueue.write { d in
            var a = Self.legacy("anna", created: 1); a.suppress = true
            var b = Self.legacy("anna", created: 2); b.setPriority = "high"
            var c = Self.legacy("anna", created: 3); c.alwaysNotify = true
            try a.insert(d); try b.insert(d); try c.insert(d)
        }
        let store = PriorityRuleStore(database: db)
        var shown = try await store.loadAll()
        var second = shown[1]
        second.setPriority = "urgent"
        try await store.update(second)

        shown = try await store.loadAll()
        let stored = try await db.dbQueue.read { try PriorityRule.fetchAll($0) }
        XCTAssertEqual(shown.map(\.suppress), [true, false, false])
        let match = RuleEvaluator.evaluate(contactName: "Anna", service: nil, messageText: "hi", rules: stored)
        guard case .suppress = match?.action else { return XCTFail("A (suppress) must still win, got \(String(describing: match))") }
        // Dropping A exposes B next — it must still come before C.
        let withoutA = stored.filter { $0.suppress == false }
        let next = RuleEvaluator.evaluate(contactName: "Anna", service: nil, messageText: "hi", rules: withoutA)
        guard case .setPriority("urgent") = next?.action else { return XCTFail("B must precede C, got \(String(describing: next))") }
    }

    func testAddDeleteAndMoveKeepADenseOrder() async throws {
        let (store, db) = try await storeWithLegacyRules()

        try await store.add(Self.legacy("D", created: 4))
        var raw = try await rawOrder(db)
        XCTAssertEqual(raw.map(\.0), ["A", "B", "C", "D"])
        XCTAssertEqual(raw.map(\.1), [0, 1, 2, 3])

        let shown = try await store.loadAll()
        try await store.delete(id: try XCTUnwrap(shown[1].id))
        raw = try await rawOrder(db)
        XCTAssertEqual(raw.map(\.0), ["A", "C", "D"])
        XCTAssertEqual(raw.map(\.1), [0, 1, 2], "no gap after a delete")

        let after = try await store.loadAll()
        try await store.move(id: try XCTUnwrap(after[2].id), by: -2)
        raw = try await rawOrder(db)
        XCTAssertEqual(raw.map(\.0), ["D", "A", "C"])
        XCTAssertEqual(raw.map(\.1), [0, 1, 2])
    }

    func testMovingALegacyRuleNormalisesEveryRow() async throws {
        let (store, db) = try await storeWithLegacyRules()
        let shown = try await store.loadAll()
        try await store.move(id: try XCTUnwrap(shown[2].id), by: -1)
        let raw = try await rawOrder(db)
        XCTAssertEqual(raw.map(\.0), ["A", "C", "B"])
        XCTAssertEqual(raw.map(\.1), [0, 1, 2])
    }
}
