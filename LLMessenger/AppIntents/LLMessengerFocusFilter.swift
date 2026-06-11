import AppIntents
import Foundation

// MARK: - Focus Filter Parameters

struct LLMessengerFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "LLMessenger"
    static var description = IntentDescription("Filter which messages LLMessenger surfaces during this Focus.")
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "LLMessenger Focus Filter"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "LLMessenger Focus Filter") }

    @Parameter(title: "Suppress Services", default: [])
    var suppressedServices: [String]   // e.g. ["slack", "telegram"]

    @Parameter(title: "Minimum Priority", default: "low")
    var minimumPriority: String   // "high" | "med" | "low"

    func perform() async throws -> some IntentResult {
        // Store the current filter state to UserDefaults so the main app can read it
        let defaults = UserDefaults.standard
        defaults.set(suppressedServices, forKey: "focusFilter.suppressedServices")
        defaults.set(minimumPriority, forKey: "focusFilter.minimumPriority")
        defaults.synchronize()
        // Post a notification so the running app picks it up immediately
        NotificationCenter.default.post(name: NSNotification.Name("LLMessengerFocusFilterChanged"), object: nil)
        return .result()
    }
}

// MARK: - Focus filter state accessor (used by AppState/PollEngine)
struct FocusFilterState {
    static var suppressedServices: [String] {
        UserDefaults.standard.stringArray(forKey: "focusFilter.suppressedServices") ?? []
    }
    static var minimumPriority: String {
        UserDefaults.standard.string(forKey: "focusFilter.minimumPriority") ?? "low"
    }
}
