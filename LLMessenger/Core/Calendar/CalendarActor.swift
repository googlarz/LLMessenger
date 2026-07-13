// LLMessenger/Core/Calendar/CalendarActor.swift
//
// Minimal, local-only calendar writer. Wraps EKEventStore to create events in the
// user's default calendar after an approved calendar_hold. No network, no reads of
// existing events beyond what EventKit needs to write. Authorization is requested
// lazily; on macOS 14+ we ask for write-only access (the least privilege that lets
// us create events), falling back to full access on older systems.

import EventKit
import Foundation

enum CalendarActorError: Error, LocalizedError {
    case notAuthorized
    case noDefaultCalendar

    var errorDescription: String? {
        switch self {
        case .notAuthorized:    return "Calendar access has not been granted."
        case .noDefaultCalendar: return "No default calendar is available to write to."
        }
    }
}

actor CalendarActor {
    private let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    nonisolated func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestAccess() async -> Bool {
        // Completion-handler variants throughout: awaiting EKEventStore's async
        // methods sends the non-Sendable store out of the actor region, which
        // Swift 6 strict concurrency rejects.
        if #available(macOS 14.0, *) {
            return await withCheckedContinuation { continuation in
                store.requestWriteOnlyAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Creates a local event in the default calendar. Throws if not authorized.
    func createEvent(title: String, start: Date, end: Date, notes: String?) async throws {
        let status = authorizationStatus()
        let authorized: Bool
        if #available(macOS 14.0, *) {
            authorized = status == .fullAccess || status == .writeOnly
        } else {
            authorized = status == .authorized
        }
        guard authorized else { throw CalendarActorError.notAuthorized }

        guard let calendar = store.defaultCalendarForNewEvents else {
            throw CalendarActorError.noDefaultCalendar
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
    }
}
