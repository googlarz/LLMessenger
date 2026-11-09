// LLMessenger/UI/Settings/WhatsAppCardPresentation.swift
//
// What the WhatsApp card in Settings → Services says and offers, as a pure function of
// the stored health record and two facts about this Mac. The card used to show the same
// "Grant Full Disk Access" block for every failure; each real cause now has its own fix.

import Foundation

struct WhatsAppCardPresentation: Equatable {
    enum Kind: Equatable {
        case notInstalled
        case needsFullDiskAccess
        case waiting
        case busy
        case formatChanged
        case other
    }

    enum Action: Equatable {
        case none
        case grantFullDiskAccess
        case reportOnGitHub
    }

    let kind: Kind
    /// Short line under the service name.
    let headline: String
    /// What to do about it.
    let guidance: String
    let action: Action
    /// Waiting and busy are expected, temporary states: no warning colour, no buttons.
    let isCalm: Bool

    static let issuesURL = URL(string: "https://github.com/googlarz/LLMessenger/issues")!

    /// - Parameters:
    ///   - health: the stored health record for WhatsApp, nil before the first check.
    ///   - storeExists: whether WhatsApp's chat store is visible at its usual path right now.
    ///   - appInstalled: whether WhatsApp Desktop is installed.
    static func make(health: ServiceHealth?, storeExists: Bool, appInstalled: Bool) -> WhatsAppCardPresentation {
        // Live facts beat a stale record: the user may have just installed WhatsApp, and
        // the record only updates on the next poll.
        let recorded = health?.lastError.map(WhatsAppHealthIssue.classify)
        switch recorded {
        case .some(.other(let reason)):
            return Self.other(reason)
        case .some(.notInstalled) where storeExists:
            return waiting
        case .some(.notInstalled):
            return notInstalled
        case .some(.needsFullDiskAccess):
            return needsFullDiskAccess
        case .some(.busy):
            return busy
        case .some(.formatChanged):
            return formatChanged
        case .none:
            if storeExists { return waiting }
            return appInstalled ? needsFullDiskAccess : notInstalled
        }
    }

    private static let notInstalled = WhatsAppCardPresentation(
        kind: .notInstalled,
        headline: "WhatsApp Desktop isn't installed",
        guidance: "Install WhatsApp Desktop and sign in. LLMessenger only reads its history on this Mac; it can't send.",
        action: .none, isCalm: false)

    private static let needsFullDiskAccess = WhatsAppCardPresentation(
        kind: .needsFullDiskAccess,
        headline: "Needs Full Disk Access",
        guidance: "macOS is keeping LLMessenger out of WhatsApp's data. Give LLMessenger Full Disk Access, then choose Retry now. If you haven't signed in to WhatsApp Desktop yet, do that first.",
        action: .grantFullDiskAccess, isCalm: false)

    private static let waiting = WhatsAppCardPresentation(
        kind: .waiting,
        headline: "Checking WhatsApp…",
        guidance: "Waiting for the first check. This usually takes a moment.",
        action: .none, isCalm: true)

    private static let busy = WhatsAppCardPresentation(
        kind: .busy,
        headline: "WhatsApp is busy",
        guidance: "WhatsApp is using its data right now. LLMessenger will try again shortly.",
        action: .none, isCalm: true)

    private static let formatChanged = WhatsAppCardPresentation(
        kind: .formatChanged,
        headline: "Can't read WhatsApp's data",
        guidance: "WhatsApp's data isn't laid out the way LLMessenger expects, probably after a WhatsApp update. Update LLMessenger, or report this on GitHub.",
        action: .reportOnGitHub, isCalm: false)

    private static func other(_ reason: String) -> WhatsAppCardPresentation {
        WhatsAppCardPresentation(kind: .other, headline: reason, guidance: reason, action: .none, isCalm: false)
    }
}

/// Facts about this Mac the Services pane reads. Injectable so snapshots and tests don't
/// depend on whether WhatsApp happens to be installed on the machine running them.
struct ServiceHostFacts: Sendable {
    var whatsAppStoreExists: @Sendable () -> Bool
    var whatsAppInstalled: @Sendable () -> Bool
    /// Reads the Keychain, so snapshots and tests inject a constant.
    var slackWorkspaceCount: @Sendable () -> Int = { SlackWorkspaceStore.load().count }

    static let live = ServiceHostFacts(
        whatsAppStoreExists: { FileManager.default.fileExists(atPath: WhatsAppAdapter.defaultStorePath) },
        whatsAppInstalled: { WhatsAppAdapter.isDesktopAppInstalled() })
}

/// Wording for the Full Disk Access explainer, shared by every service that needs it.
enum FullDiskAccessCopy {
    static func informativeText(for service: String) -> String {
        let what = service == WhatsAppAdapter.id ? "WhatsApp history" : "iMessage history"
        return """
        macOS needs you to add LLMessenger to Full Disk Access before it can read your \(what).

        Manual steps (works on every Mac):
          1. Apple menu  →  System Settings…
          2. Privacy & Security  →  Full Disk Access
          3. Click the +
          4. Choose LLMessenger.app
          5. Quit and reopen LLMessenger

        The buttons below can speed it up but don't always work — some Macs immediately quit System Settings on URL hand-off ("is not open anymore"). If that happens, just use the Apple menu manually.
        """
    }
}
