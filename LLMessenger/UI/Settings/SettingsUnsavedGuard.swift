// LLMessenger/UI/Settings/SettingsUnsavedGuard.swift
//
// Closing the Settings window used to throw away typed-but-unsaved credentials and
// prompts without a word. SettingsView registers what it holds; the window
// controller asks before the window goes away.
import Foundation

@MainActor
final class SettingsUnsavedGuard {
    enum Choice { case save, discard, cancel }

    var hasUnsaved: () -> Bool = { false }
    var saveAll: () -> Void = {}
    var discardAll: () -> Void = {}

    /// Whether the window may close now. `ask` shows the Save / Discard / Cancel prompt
    /// and is only called when there is something unsaved. A save that fails keeps the
    /// window open: the tab shows the error and the typed values are still there.
    func shouldClose(ask: () -> Choice) -> Bool {
        guard hasUnsaved() else { return true }
        switch ask() {
        case .cancel:
            return false
        case .discard:
            discardAll()
            return true
        case .save:
            saveAll()
            return !hasUnsaved()
        }
    }
}
