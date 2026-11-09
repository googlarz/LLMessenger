// AppState+Errors.swift
//
// Error mapping: raw adapter/DB errors to one-line user-facing text.

import AppKit
import Foundation
import GRDB

/// Where an error came from decides how it is explained. A messaging service
/// refusing a send must never read as an AI-key problem, and vice versa.
enum ErrorSource: Equatable {
    case ai
    case messaging(service: String?)
    case other

    /// LLM clients wrap every failure in LLMError; adapters throw their own types.
    static func infer(from error: Error) -> ErrorSource {
        switch error {
        case is LLMError:
            return .ai
        case is SlackAPIError:
            return .messaging(service: "slack")
        case is AdapterError:
            return .messaging(service: nil)
        case let readOnly as ReadOnlyServiceError:
            return .messaging(service: readOnly.service)
        default:
            return .other
        }
    }
}

extension AppState {
    // MARK: - Error mapping

    /// Maps raw Swift/URLSession/LLM/adapter errors to user-friendly one-liners.
    /// Call this instead of bare `error.localizedDescription` at user-visible boundaries.
    /// `source` defaults to what the error's type says about where it came from.
    func friendly(_ error: Error, source: ErrorSource? = nil) -> String {
        Self.friendlyMessage(for: error, source: source ?? ErrorSource.infer(from: error))
    }

    static func friendlyMessage(for error: Error, source: ErrorSource) -> String {
        if error is ReadOnlyServiceError { return error.localizedDescription }
        let raw = error.localizedDescription.lowercased()
        let messagingName: String = {
            if case .messaging(let service?) = source { return Theme.serviceName(service) }
            return "The messaging service"
        }()

        if raw.contains("401") || raw.contains("unauthorized") || raw.contains("forbidden")
            || raw.contains("api key") || raw.contains("invalid_auth") || raw.contains("token_revoked") {
            switch source {
            case .ai: return "API key invalid or expired — check your AI settings."
            case .messaging: return "\(messagingName) refused the request — reconnect it in Settings."
            case .other: return "Not authorized — check the account in Settings."
            }
        }
        if raw.contains("429") || raw.contains("rate limit") || raw.contains("ratelimited") || raw.contains("too many") {
            return "Too many requests — try again in a moment."
        }
        if raw.contains("timeout") || raw.contains("timed out") {
            return "Request timed out — check your connection."
        }
        if raw.contains("connection refused") || raw.contains("ollama") || raw.contains("localhost") || raw.contains("127.0.0.1") {
            switch source {
            case .ai: return "Couldn't reach Ollama — make sure it's running."
            case .messaging: return "\(messagingName) isn't reachable on this Mac — make sure it's running."
            case .other: return "Couldn't reach a service on this Mac — make sure it's running."
            }
        }
        if raw.contains("network") || raw.contains("offline") || raw.contains("internet") || raw.contains("host") {
            return "Network error — check your connection."
        }
        return error.localizedDescription
    }
}
