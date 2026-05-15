import Foundation

struct ServiceHandle: Hashable {
    let service: String
    let conversationId: String
    let isGroup: Bool
}

struct Contact: Identifiable, Hashable {
    let id: String
    let displayName: String
    let handles: [ServiceHandle]

    var sortKey: String { displayName.lowercased() }
}
