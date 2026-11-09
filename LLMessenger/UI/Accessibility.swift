// LLMessenger/UI/Accessibility.swift
//
// One place for what VoiceOver hears. Toasts and banners are transient and
// never take focus, so each one is also *announced*; anything that offers an
// action (Undo, Show…) says so in the announcement.

import AppKit

enum A11y {
    /// Speaks `text` through VoiceOver without moving focus. Problems and
    /// anything the user may need to act on in a hurry use high priority so they
    /// are not dropped behind other speech.
    @MainActor static func announce(_ text: String, urgent: Bool = false) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text as NSString,
                .priority: (urgent ? NSAccessibilityPriorityLevel.high : .medium).rawValue as NSNumber
            ]
        )
    }

    static var isVoiceOverRunning: Bool { NSWorkspace.shared.isVoiceOverEnabled }

    /// How long a toast stays up. Six seconds is plenty to read; it is not
    /// enough to find the Undo control with a screen reader, so VoiceOver users
    /// get a much longer window. (This is only the toast — the 5-second send
    /// undo window itself is governed by the send pipeline.)
    static func toastDuration(hasAction: Bool, voiceOver: Bool = isVoiceOverRunning) -> TimeInterval {
        if voiceOver { return hasAction ? 30 : 15 }
        return 6
    }

    /// "Skipped" + "Undo" → "Skipped. Undo available."
    static func spoken(_ text: String, actionTitle: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")
            ? trimmed : trimmed + "."
        guard let actionTitle, !actionTitle.isEmpty else { return sentence }
        return "\(sentence) \(actionTitle) available."
    }
}

extension UserReceipt {
    var spokenText: String {
        let base = A11y.spoken(text, actionTitle: actionTitle)
        return tone == .problem ? "Problem. " + base : base
    }
}
