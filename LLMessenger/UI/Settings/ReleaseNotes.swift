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
