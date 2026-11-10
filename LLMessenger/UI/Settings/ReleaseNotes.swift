// LLMessenger/UI/Settings/ReleaseNotes.swift
//
// Curated in-app release notes, newest first. Shown in the About tab so users
// of a fast-moving app can see what changed without visiting GitHub.
// Convention: add an entry in the same commit that bumps Info.plist.

import Foundation

struct ReleaseNote: Identifiable {
    let version: String
    let title: String
    let highlights: [String]

    var id: String { version }
}

enum ReleaseNotes {
    static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "2.5.0",
            title: "Easier to reply, easier to start",
            highlights: [
                "One Reply window: it shows who you're writing to and on which service, and sends exactly the text you see. Every send still waits 5 seconds so you can undo it.",
                "The Ask panel only answers questions now. It can no longer send anything.",
                "A send that fails stays in your Act queue with Try again, instead of disappearing. That includes a service that isn't connected.",
                "First launch starts with sample messages, so you can try the whole app before granting any access. Nothing is sent while you're in the sample.",
                "Settings: service switches save right away, unsaved fields are no longer lost when you close the window, and the WhatsApp card says exactly what is missing.",
                "MCP: turning it on asks you to confirm, shows setup steps for Claude and Cursor, and shows when an agent last asked for something.",
                "Privacy fixes for MCP: digests that draw on Local-only conversations are withheld, and an outside agent can no longer change a reply you already reviewed.",
                "Plainer labels in digests and the Act queue, and the sample now includes a WhatsApp chat.",
                "Better VoiceOver announcements, visible keyboard focus, larger small text and stronger contrast.",
                "LLMessenger no longer asks for microphone or speech recognition access."
            ]),
        ReleaseNote(
            version: "2.4.0",
            title: "WhatsApp and MCP",
            highlights: [
                "WhatsApp, read-only: LLMessenger can read WhatsApp Desktop's local history, so WhatsApp chats show up in digests and owed replies. You reply in WhatsApp itself, with the draft ready to copy. Off by default — enable it in Settings → Services.",
                "MCP server mode, opt-in: let Claude, Cursor, or another MCP client ask what you owe people, read the latest digest, and search your messages locally. Enable it in Settings → AI & Privacy → Privacy.",
                "Replies an outside agent proposes wait in your Act queue, labelled External Agent, and are never part of a batch send.",
                "Conversations marked Local-only are never exposed over MCP, and are left out of digests while MCP is on.",
                "If the database fails to open, the app now asks before moving it aside instead of silently starting fresh."
            ]),
        ReleaseNote(
            version: "2.3.3",
            title: "Fixes from an adversarial re-review",
            highlights: [
                "Refresh no longer clears a question you were mid-typing — only navigating to a different digest yourself clears the composer.",
                "Fixed an abandoned @-mention target silently redirecting a reply to the wrong person.",
                "A priority rule that suppresses every message (no contact, keyword, or service condition) now asks for confirmation before saving.",
                "Closed a narrow window where auto-send could be saved without the confirmation dialog actually being shown.",
                "The About tab now correctly says Apache 2.0 instead of MIT, and reports this version instead of 2.3.1."
            ]),
        ReleaseNote(
            version: "2.3.2",
            title: "Bug-hunt hardening pass",
            highlights: [
                "Fixed 15 bugs found in a manual audit: state leaking across digest navigation, wrong row expanding after a reload, a settings sub-tab silently resetting, a rule that could never be saved, and more.",
                "Fixed a flaky accessibility-audit test and a latent build-analyzer warning found during a full pre-release verification pass.",
                "6 new regression tests added."
            ]),
        ReleaseNote(
            version: "2.3.1",
            title: "Activity becomes a trend, not just today",
            highlights: [
                "Activity now covers the last 14 days instead of just today — a real trail of when things needed you, not a single snapshot.",
                "Grouped by day: today stays open, older days collapse to a header with a \"N needed you\" count and expand on tap, so two weeks of history isn't a wall of rows.",
                "Quiet days show no badge at all — the count only appears when something actually needed you, so a clear stretch reads as calm, not as a row of zeros.",
                "The messy \"old ledger\" look in Activity and per-conversation history is gone: entries now separate by whitespace with one clear headline per row, not a hairline after every line."
            ]),
        ReleaseNote(
            version: "2.3.0",
            title: "The Mac-native redesign",
            highlights: [
                "New navigation: a proper sidebar (Act, Digests, Activity) where every selection drives the main content — Act and Activity go full-width, Digests pairs the archive with the open digest.",
                "Native title-bar toolbar with search, refresh, service status, and digest back/forward — plus a real macOS menu bar with every command and shortcut.",
                "Digest cards start compact (headline, two lines, one action) and expand on demand; only the top card opens expanded.",
                "Reading is reading: the AI composer is now an Ask panel you open from the toolbar, and the disclaimer moved into the status popover.",
                "Act is one ranked queue — Needs your decision, Ready to send, Waiting on others, Later — with ⌘-click multi-select for batch sends.",
                "Settings consolidated to five panes. Reduce Motion and Increase Contrast are honored everywhere; no text renders below 10pt.",
                "Calmer feedback: refresh is a toolbar spinner and confirmations are floating toasts that never push your content around."
            ]),
        ReleaseNote(
            version: "2.2.7",
            title: "Cleaner internals, faster Desk, in-app release notes",
            highlights: [
                "Fixed several runtime crash-risk force-unwraps in the message adapters and poll pipeline.",
                "AppState split into focused files — no behavior change, easier to review going forward.",
                "Brief JSON is now cached instead of re-decoded on every render — noticeably snappier with a full inbox.",
                "Menu bar updates coalesce into one rebuild per refresh instead of dozens.",
                "About tab now shows a \"What's new\" section — this list — without leaving the app."
            ]),
        ReleaseNote(
            version: "2.2.6",
            title: "First-run trust and recovery polish",
            highlights: [
                "Live setup diagnosis (AI, services, messages, privacy) while your first digest loads.",
                "First real digest arrives with counts and a short guided checklist.",
                "Cards show plain confidence labels — High confidence, Context assisted, Check sources.",
                "Undo receipts for skips, snoozes, completions, and archive actions.",
                "Reply drafts carry provenance: why the draft exists and what shaped it."
            ]),
        ReleaseNote(
            version: "2.2.5",
            title: "Calmer Desk layout",
            highlights: [
                "Act tab now leads with what needs you; retrospective stats moved to Activity.",
                "First-week guide can be dismissed for good."
            ]),
        ReleaseNote(
            version: "2.2.4",
            title: "Trust, demo, and product love",
            highlights: [
                "Try the full command center on sample data before connecting accounts.",
                "Per-conversation privacy controls: Normal, Local-only, Never draft.",
                "Cards cite their sources — see exactly which messages back each claim."
            ]),
        ReleaseNote(
            version: "2.2.3",
            title: "Better briefs",
            highlights: [
                "Cards separate urgency from actionability with an explicit reply-needed state.",
                "One conversation can produce multiple cards for distinct asks and decisions."
            ])
    ]
}
