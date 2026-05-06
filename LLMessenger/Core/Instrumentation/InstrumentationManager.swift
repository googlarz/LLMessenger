// LLMessenger/Core/Instrumentation/InstrumentationManager.swift
import Foundation

enum BriefEvent: String {
    case briefOpened = "brief_opened"
    case sourceExpanded = "source_expanded"
    case followUpQuestionAsked = "follow_up_question_asked"
    case draftCreated = "draft_created"
    case refreshTriggered = "refresh_triggered"
}

final class InstrumentationManager {
    static let shared = InstrumentationManager()
    
    private init() {}
    
    func track(event: BriefEvent, metadata: [String: Any] = [:]) {
        // Simple local logging for now, as per PRD requirements.
        // In a production app, this would send to an analytics backend.
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] EVENT: \(event.rawValue) | Metadata: \(metadata)")
        
        // Future-proofing: persist to local SQLite if needed for local analytics.
    }
}
