// LLMessenger/Core/WidgetDataProvider.swift
import Foundation

struct BriefWidgetSnapshot: Codable {
    let headline: String
    let highCount: Int
    let medCount: Int
    let totalCards: Int
    let updatedAt: Date
    let briefID: Int64?
}

@MainActor
enum WidgetDataProvider {
    static let appGroupID = "group.com.llmessenger.app"
    static let snapshotKey = "briefWidgetSnapshot"

    /// Write a snapshot so the Notification Center widget can show it.
    /// Uses App Group UserDefaults when the app is signed with a team ID;
    /// falls back to a JSON file in Application Support for unsigned builds.
    static func write(briefID: Int64, cards: [BriefCardRecord], openingSummary: String?) {
        let sorted = cards.sorted { priorityRank($0.priority) < priorityRank($1.priority) }
        let snapshot = BriefWidgetSnapshot(
            headline: sorted.first?.headline ?? openingSummary ?? "New brief ready",
            highCount: cards.filter { $0.priority == "high" }.count,
            medCount: cards.filter { $0.priority == "med" || $0.priority == "medium" }.count,
            totalCards: cards.count,
            updatedAt: Date(),
            briefID: briefID
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }

        // Primary: App Group shared container (requires team signing + entitlement)
        if let defaults = UserDefaults(suiteName: appGroupID) {
            defaults.set(data, forKey: snapshotKey)
        }

        // Secondary: flat file the widget extension can read via a known path.
        // On macOS, widget extensions can read from ~/Library/Application Support
        // when the parent app writes there and the widget has the same bundle prefix.
        let fileURL = snapshotFileURL
        try? data.write(to: fileURL, options: .atomic)

        // Signal the widget to reload its timeline.
        if #available(macOS 14.0, *) {
            postWidgetReloadNotification()
        }
    }

    /// URL that the widget extension reads to display brief data.
    static var snapshotFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("LLMessenger", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-snapshot.json")
    }

    @available(macOS 14.0, *)
    private static func postWidgetReloadNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.llmessenger.widgetReload" as CFString),
            nil, nil, true
        )
    }

    private static func priorityRank(_ p: String) -> Int {
        switch p {
        case "high":            return 0
        case "med", "medium":   return 1
        default:                return 2
        }
    }
}
