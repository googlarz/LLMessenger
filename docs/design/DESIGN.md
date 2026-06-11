# LLMessenger Design System — "The Wire Desk"

LLMessenger compiles messages into an intelligence brief, so the UI is typeset
like one. Reference: a private wire service — editorial serif headlines, mono
evidence metadata, ink-dark ground, paper-warm text.

## The one rule

**Colour means urgency. Nothing else gets colour.**

- `Theme.signal` (vermilion) — "needs you now": high-priority rules/stamps, unread dots. Small doses only.
- `Theme.standby` (amber) — partial states, warnings, confirm-send.
- `Theme.ok` (sage) — health OK, handled/filed.
- Service identity uses muted ink stamps (`ServiceStamp`), never saturated brand colours.
- Interactive/selected = paper (`Theme.textPrimary`) on ink, never a hue.

## Three typographic voices

| Voice | Font | Use |
|---|---|---|
| Editorial | `Theme.display(size)` — New York serif | Brief + card headlines, empty-state lines |
| Wire | `Theme.mono(size)` — SF Mono | Timestamps, counts, microlabels, evidence attribution |
| Interface | `Theme.sans(size)` — SF Pro | Body prose, controls, form fields |

Microlabels are uppercase mono with `tracking(Theme.labelTracking)` — use the
`WireLabel("…")` component. Quoted message text is set serif-italic (quotes
read as quotations).

## Components (Theme.swift)

- `WireLabel(_:color:)` — section/microlabel voice
- `Rule(color:)` — horizontal hairline (newspaper column rule). Vertical rules: `Theme.border.frame(width: Theme.hairline)`
- `ServiceStamp(service:size:)` — bordered mono service initials
- `PaperButtonStyle(prominent:)` — primary actions; prominent = paper fill on ink
- `WireActionStyle(tint:)` — quiet mono uppercase inline actions
- Metrics: `Theme.gutter` (32) page margins, `Theme.hairline` (0.5), `Theme.controlRadius` (5)
- Motion: `Theme.spring` for layout, `Theme.quick` for hover/press

## Hard rules

1. No `Divider()` — use `Rule()`.
2. No gray-box-with-border cards. Entries separate with hairline rules; emphasis via margin rules (2px colour bar on the left), not background washes.
3. No SF Symbols as decoration (no sparkles tiles). Symbols only when they carry meaning (chevrons, ✕, pin).
4. No raw `Color(red:green:blue:)` outside Theme.swift. No `.green/.orange/.red` system colours — use `Theme.ok/standby/signal`.
5. No `Theme.accent*` in new code — those are legacy aliases for `signal` and mean urgency.
6. Buttons: never colour-filled. Primary = `PaperButtonStyle(prominent: true)`, secondary = `PaperButtonStyle()`, inline = `WireActionStyle()`.
7. Forms (Settings/Onboarding): section titles are `WireLabel`, field captions `Theme.sans(11)` tertiary, group separation by `Rule()` + whitespace, never `GroupBox`.
8. Empty states: `WireLabel` kicker + one serif `Theme.display` line + one tertiary sans sentence. Write copy in the product's voice (calm, editorial, no exclamation marks).

## Snapshots

`LLMessengerTests/DesignSnapshotTests` renders fixture PNGs to
`docs/design/snapshots/<tag>/`:

```
TEST_RUNNER_SNAPSHOT_TAG=current xcodebuild test -scheme LLMessenger \
  -only-testing:LLMessengerTests/DesignSnapshotTests
```
