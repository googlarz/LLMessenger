// LLMessenger/Core/Rules/PriorityRuleStore.swift
//
// Persistence, ordering and quiet-hours helpers for priority rules, kept out of the
// SwiftUI view so they can be tested. `RuleEvaluator` is the single reader: it sorts by
// `sortOrder` (lowest first) and the first matching rule wins.

import Foundation
import GRDB

/// Quiet hours are stored as "HH:mm" strings, the only format `RuleEvaluator` parses.
enum QuietHours {
    /// Minutes since midnight, or nil unless `text` is a real 24-hour "H:mm" / "HH:mm" time.
    static func minutes(from text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    static func string(fromMinutes minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return string(fromMinutes: (c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// Today at the given time, for seeding a time picker.
    static func date(fromMinutes minutes: Int, calendar: Calendar = .current, now: Date = Date()) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: now) ?? now
    }

    /// Why a window can't be saved, in plain words; nil when it is fine. A window whose start
    /// equals its end is rejected because the evaluator would read it as "the whole day".
    static func problem(start: String, end: String) -> String? {
        guard let s = minutes(from: start), let e = minutes(from: end) else {
            return "Choose both a start and an end time."
        }
        if s == e { return "Start and end can't be the same time." }
        return nil
    }
}

enum PriorityRuleOrdering {
    /// Sort order for a rule added at the bottom of the list.
    static func nextSortOrder(after rules: [PriorityRule]) -> Int {
        (rules.map(\.sortOrder).max() ?? -1) + 1
    }

    /// The list in evaluation order, with `sortOrder` renumbered 0…n-1. Rules saved before
    /// ordering existed all share 0; ties fall back to creation time, then id, so the
    /// order the user saw is the order they keep.
    static func normalised(_ rules: [PriorityRule]) -> [PriorityRule] {
        let ordered = rules.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return ($0.id ?? 0) < ($1.id ?? 0)
        }
        return ordered.enumerated().map { index, rule in
            var copy = rule
            copy.sortOrder = index
            return copy
        }
    }

    /// Moves a rule up (negative offset) or down by `offset` places; a no-op at the ends.
    static func moving(_ rules: [PriorityRule], id: Int64, by offset: Int) -> [PriorityRule] {
        var list = normalised(rules)
        guard let from = list.firstIndex(where: { $0.id == id }) else { return list }
        let to = min(max(from + offset, 0), list.count - 1)
        guard to != from else { return list }
        let rule = list.remove(at: from)
        list.insert(rule, at: to)
        return list.enumerated().map { index, rule in
            var copy = rule
            copy.sortOrder = index
            return copy
        }
    }
}

struct PriorityRuleStore {
    let database: AppDatabase

    /// Every rule in evaluation order.
    func loadAll() async throws -> [PriorityRule] {
        let rules = try await database.dbQueue.read { db in try PriorityRule.fetchAll(db) }
        return PriorityRuleOrdering.normalised(rules)
    }

    /// Every write below runs in one transaction and ends by persisting the whole
    /// visible order as a dense 0…n-1. Rules saved before ordering existed all share
    /// sortOrder 0; the list shows them renumbered, so writing only the edited rule's
    /// number would silently reshuffle the rest.
    private static func persistDense(_ db: Database, _ rules: [PriorityRule]) throws -> [PriorityRule] {
        let dense = PriorityRuleOrdering.normalised(rules)
        for rule in dense { try rule.update(db) }
        return dense
    }

    /// Adds a rule at the bottom of the list.
    func add(_ rule: PriorityRule) async throws {
        try await database.dbQueue.write { db in
            let existing = PriorityRuleOrdering.normalised(try PriorityRule.fetchAll(db))
            _ = try Self.persistDense(db, existing)
            var new = rule
            new.id = nil
            new.sortOrder = existing.count
            try new.insert(db)
        }
    }

    /// Saves changes to an existing rule, keeping its place in the list. The place is
    /// the one the list showed (normalised order), not whatever number the caller holds.
    func update(_ rule: PriorityRule) async throws {
        guard let id = rule.id else { return try await add(rule) }
        try await database.dbQueue.write { db in
            var current = PriorityRuleOrdering.normalised(try PriorityRule.fetchAll(db))
            guard let index = current.firstIndex(where: { $0.id == id }) else { return }
            var edited = rule
            edited.sortOrder = index
            current[index] = edited
            for r in current { try r.update(db) }
        }
    }

    func delete(id: Int64) async throws {
        try await database.dbQueue.write { db in
            let current = PriorityRuleOrdering.normalised(try PriorityRule.fetchAll(db))
            _ = try PriorityRule.deleteOne(db, key: id)
            _ = try Self.persistDense(db, current.filter { $0.id != id })
        }
    }

    /// Moves a rule and persists the renumbered order. Returns the new list.
    @discardableResult
    func move(id: Int64, by offset: Int) async throws -> [PriorityRule] {
        try await database.dbQueue.write { db in
            let current = try PriorityRule.fetchAll(db)
            let reordered = PriorityRuleOrdering.moving(current, id: id, by: offset)
            for rule in reordered { try rule.update(db) }
            return reordered
        }
    }
}
