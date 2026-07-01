// AppState+Errors.swift
//
// Error mapping: raw adapter/DB errors to one-line user-facing text.

import AppKit
import Foundation
import GRDB

extension AppState {
    // MARK: - Error mapping

    /// Maps raw Swift/URLSession/Ollama errors to user-friendly one-liners.
    /// Call this instead of bare `error.localizedDescription` at user-visible boundaries.
    func friendly(_ error: Error) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("401") || raw.contains("unauthorized") || raw.contains("forbidden") || raw.contains("api key") {
            return "API key invalid or expired — check your AI settings."
        }
        if raw.contains("429") || raw.contains("rate limit") || raw.contains("too many") {
            return "Too many requests — try again in a moment."
        }
        if raw.contains("timeout") || raw.contains("timed out") {
            return "Request timed out — check your connection."
        }
        if raw.contains("connection refused") || raw.contains("ollama") || raw.contains("localhost") || raw.contains("127.0.0.1") {
            return "Couldn't reach Ollama — make sure it's running."
        }
        if raw.contains("network") || raw.contains("offline") || raw.contains("internet") || raw.contains("host") {
            return "Network error — check your connection."
        }
        return error.localizedDescription
    }
}
