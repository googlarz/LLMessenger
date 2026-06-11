import Foundation
import GRDB

@MainActor
final class ContactDirectory: ObservableObject {
    @Published private(set) var contacts: [Contact] = []
    private let adapters: () -> [any MessengerAdapter]
    private let repository: BriefRepository
    private var refreshTask: Task<Void, Never>?

    init(adapters: @escaping () -> [any MessengerAdapter], repository: BriefRepository) {
        self.adapters = adapters
        self.repository = repository
    }

    /// Pulls contacts from every adapter, dedupes by display name (case-insensitive),
    /// and sorts alphabetically. Safe to call repeatedly — previous refreshes are cancelled.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = self.adapters()
            var perAdapter: [[Contact]] = []
            for adapter in snapshot {
                if Task.isCancelled { return }
                let list = await adapter.listContacts()
                perAdapter.append(list)
            }
            let merged = Self.dedupe(perAdapter.flatMap { $0 })
            if Task.isCancelled { return }
            self.contacts = merged.sorted { $0.sortKey < $1.sortKey }
        }
    }

    /// Returns the service the user most recently picked for this display name,
    /// or nil if they haven't picked one before.
    func preferredService(for displayName: String) -> String? {
        try? repository.preferredService(for: displayName)
    }

    /// Records that the user picked (service, conversationId) for this display name.
    /// The next `serviceOrder(for:)` call will rank that service first.
    func recordPick(displayName: String, service: String) {
        try? repository.recordContactPick(displayName: displayName, service: service)
    }

    /// Orders the handles for display: preferred service first, then by service ID alphabetically.
    func orderedHandles(for contact: Contact) -> [ServiceHandle] {
        let preferred = preferredService(for: contact.displayName)
        return contact.handles.sorted { a, b in
            if a.service == preferred && b.service != preferred { return true }
            if b.service == preferred && a.service != preferred { return false }
            return a.service < b.service
        }
    }

    // MARK: - Contact Profiles

    /// Returns the stored ContactProfile for the given service+conversationId pair, or nil if none exists.
    func loadProfile(service: String, conversationId: String) -> ContactProfile? {
        try? repository.database.dbQueue.read { db in
            try ContactProfile
                .filter(Column("service") == service)
                .filter(Column("conversationId") == conversationId)
                .fetchOne(db)
        }
    }

    /// Upserts a ContactProfile. Called by BriefEngine after brief generation.
    func upsertProfile(_ profile: ContactProfile) {
        try? repository.database.dbQueue.write { db in
            try profile.save(db)
        }
    }

    // MARK: - Dedup

    /// Merges contacts that share a display name into a single Contact with combined handles.
    /// Display-name comparison is case-insensitive, whitespace-trimmed.
    private static func dedupe(_ contacts: [Contact]) -> [Contact] {
        var grouped: [String: (displayName: String, handles: [ServiceHandle])] = [:]
        var order: [String] = []
        for c in contacts {
            let key = c.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            if grouped[key] == nil {
                grouped[key] = (c.displayName, c.handles)
                order.append(key)
            } else {
                grouped[key]!.handles.append(contentsOf: c.handles)
            }
        }
        return order.compactMap { key in
            guard let entry = grouped[key] else { return nil }
            // Dedupe handles within the merged contact.
            let unique = Array(Set(entry.handles))
            return Contact(
                id: "merged:\(key)",
                displayName: entry.displayName,
                handles: unique
            )
        }
    }
}
