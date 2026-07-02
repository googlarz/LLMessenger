// LLMessenger/Core/Brief/RetentionPruner.swift
//
// Runs BriefRepository.pruneOldData at most once per day, off the main thread.
// Without this, messages/triageEvents/actionAudit grow forever — see the
// architecture-limits audit that flagged this as the first ceiling a heavy
// user hits (unbounded storage + FTS5 index bloat).

import Foundation

enum RetentionPruner {
    static let retentionDays = 90
    private static let lastPruneKey = "retentionPruner.lastRunAt"
    private static let minInterval: TimeInterval = 24 * 3600

    static func pruneIfDue(repository: BriefRepository, defaults: UserDefaults = .standard,
                           now: Date = Date()) {
        if let last = defaults.object(forKey: lastPruneKey) as? Date,
           now.timeIntervalSince(last) < minInterval {
            return
        }
        defaults.set(now, forKey: lastPruneKey)
        Task.detached(priority: .utility) {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
            let deleted = (try? repository.pruneOldData(olderThan: cutoff)) ?? 0
            if deleted > 0 {
                NSLog("[RetentionPruner] removed %d rows older than %d days", deleted, retentionDays)
            }
        }
    }
}
