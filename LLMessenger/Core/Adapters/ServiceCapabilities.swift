// LLMessenger/Core/Adapters/ServiceCapabilities.swift
import Foundation

/// What a service can do beyond reading. Today the only capability that varies is
/// sending: some stores can be read locally but offer no way to send (WhatsApp).
/// Keyed by service id so code without an adapter in hand (the agent engine, the
/// MCP server, the draft view) can ask the same question.
enum ServiceCapabilities {
    /// Services LLMessenger ingests but can never send to.
    static let readOnlyServices: Set<String> = [WhatsAppAdapter.id]

    static func canSend(service: String) -> Bool {
        !readOnlyServices.contains(service)
    }

    /// "WhatsApp is read-only in LLMessenger — reply in WhatsApp"
    static func readOnlyMessage(for service: String) -> String {
        let name = Theme.serviceName(service)
        return "\(name) is read-only in LLMessenger — reply in \(name)"
    }

    /// Everything except a calendar hold ends in a message to the other person.
    static func sendsMessage(_ kind: AgentActionKind?) -> Bool {
        kind != .calendarHold
    }
}

struct ReadOnlyServiceError: LocalizedError {
    let service: String
    var errorDescription: String? { ServiceCapabilities.readOnlyMessage(for: service) }
}
