import Foundation

struct ProductLoveMetrics: Equatable {
    var activeDays: Int
    var firstSeenAt: Date?
    var handledCards: Int
    var priorityCorrections: Int
    var quietedThreads: Int
    var openedDigests: Int

    var firstWeekDay: Int {
        guard let firstSeenAt else { return 1 }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: firstSeenAt), to: Date()).day ?? 0
        return min(7, max(1, days + 1))
    }

    var hasLearningSignal: Bool {
        priorityCorrections > 0 || quietedThreads > 0
    }

    func shouldShowFirstWeekGuide(suggestionCount: Int) -> Bool {
        firstWeekDay <= 7 && (
            openedDigests == 0 ||
            handledCards == 0 ||
            !hasLearningSignal ||
            activeDays < 2 ||
            suggestionCount > 0
        )
    }

    var shouldShowLearningReceipt: Bool {
        hasLearningSignal
    }

    var learningReceipt: String {
        if quietedThreads > 0 && priorityCorrections > 0 {
            return "You quieted \(quietedThreads) \(quietedThreads == 1 ? "thread" : "threads") and corrected \(priorityCorrections) \(priorityCorrections == 1 ? "priority" : "priorities"). Future digests use that signal."
        }
        if quietedThreads > 0 {
            return "You quieted \(quietedThreads) \(quietedThreads == 1 ? "thread" : "threads"). Similar low-signal updates will be held back more often."
        }
        if priorityCorrections > 0 {
            return "You corrected \(priorityCorrections) \(priorityCorrections == 1 ? "priority" : "priorities"). Future digests use that feedback."
        }
        return "No learning signal yet."
    }

    var learningNextStep: String {
        if quietedThreads > 0 && priorityCorrections > 0 {
            return "Next digest: fewer low-signal repeats, sharper priority on familiar people."
        }
        if quietedThreads > 0 {
            return "Next digest: similar low-signal threads stay quieter."
        }
        if priorityCorrections > 0 {
            return "Next digest: that priority correction becomes a ranking hint."
        }
        return "Next digest: no learning signal yet."
    }

    static let empty = ProductLoveMetrics(
        activeDays: 0,
        firstSeenAt: nil,
        handledCards: 0,
        priorityCorrections: 0,
        quietedThreads: 0,
        openedDigests: 0
    )
}

enum ProductLoveMetricStore {
    private static let firstSeenKey = "loveMetrics.firstSeenAt"
    private static let activeDaysKey = "loveMetrics.activeDays"
    private static let handledCardsKey = "loveMetrics.handledCards"
    private static let priorityCorrectionsKey = "loveMetrics.priorityCorrections"
    private static let quietedThreadsKey = "loveMetrics.quietedThreads"
    private static let openedDigestsKey = "loveMetrics.openedDigests"
    private static let activeDayPrefix = "loveMetrics.activeDay."

    static func markActiveToday(defaults: UserDefaults = .standard, now: Date = Date()) -> ProductLoveMetrics {
        if defaults.object(forKey: firstSeenKey) == nil {
            defaults.set(now, forKey: firstSeenKey)
        }
        let key = activeDayPrefix + dayKey(now)
        if !defaults.bool(forKey: key) {
            defaults.set(true, forKey: key)
            defaults.set(defaults.integer(forKey: activeDaysKey) + 1, forKey: activeDaysKey)
        }
        return load(defaults: defaults)
    }

    static func recordHandledCard(defaults: UserDefaults = .standard) -> ProductLoveMetrics {
        increment(handledCardsKey, defaults: defaults)
    }

    static func recordPriorityCorrection(defaults: UserDefaults = .standard) -> ProductLoveMetrics {
        increment(priorityCorrectionsKey, defaults: defaults)
    }

    static func recordQuietedThread(defaults: UserDefaults = .standard) -> ProductLoveMetrics {
        increment(quietedThreadsKey, defaults: defaults)
    }

    static func recordOpenedDigest(defaults: UserDefaults = .standard) -> ProductLoveMetrics {
        increment(openedDigestsKey, defaults: defaults)
    }

    static func load(defaults: UserDefaults = .standard) -> ProductLoveMetrics {
        ProductLoveMetrics(
            activeDays: defaults.integer(forKey: activeDaysKey),
            firstSeenAt: defaults.object(forKey: firstSeenKey) as? Date,
            handledCards: defaults.integer(forKey: handledCardsKey),
            priorityCorrections: defaults.integer(forKey: priorityCorrectionsKey),
            quietedThreads: defaults.integer(forKey: quietedThreadsKey),
            openedDigests: defaults.integer(forKey: openedDigestsKey)
        )
    }

    private static func increment(_ key: String, defaults: UserDefaults) -> ProductLoveMetrics {
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
        return load(defaults: defaults)
    }

    private static func dayKey(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }
}
