# LLMessenger Launch Kit

Prep material for the later Product Hunt / Show HN launch. Nothing here is
published — it's staged so launch day is an execution day, not a writing day.

## Positioning

**One-liner:** The morning brief for your messages — every claim sourced, any model you choose.

Two structural angles no current competitor owns together:

1. **Source-backed AI.** Every card shows its evidence: tap any claim and read
   the exact messages behind it. Beeper's AI summarization (in beta) and
   Apple Intelligence summaries are black boxes — LLMessenger is the only
   client where the AI is accountable. *(Verified 2026-06-12: Beeper desktop
   has summarization in beta + "BeepMate" assistant on roadmap; no source
   citation UI.)*
2. **Bring your own model.** Ollama (fully local, nothing leaves the Mac),
   Anthropic, or OpenAI — user's choice, disclosed per call in the Privacy
   tab's live network audit log.

Tagline candidates:
- "Your messages, briefed. Every claim, sourced."
- "Stop reading 400 messages. Read one brief that cites them."
- "A private intelligence desk for your group chats."

## 60-second demo video — shot list

Record in **Demo Mode** (fresh install → "Explore the demo desk") at 1280×800,
2× scale. No real messages on screen, no face cam needed.

| # | Seconds | Shot | Overlay text |
|---|---------|------|--------------|
| 1 | 0–6 | Menu bar, brief glyph with unread badge "1". Click it. | "It watches Signal, Telegram, iMessage and Slack…" |
| 2 | 6–16 | The morning brief opens: "One thing needs you." serif masthead, 4 cards. Slow scroll. | "…and writes you a brief instead of 400 unread messages." |
| 3 | 16–28 | Click "3 SOURCES" on the Meridian card — evidence drawer opens, citations in serif italic. | "Every claim shows its sources. No black-box AI." |
| 4 | 28–38 | Click REPLY → type "tell her the cap table lands Wednesday morning" → AI draft appears → confirm-send screen with "Nothing sends until you confirm." | "Draft replies in your voice. Nothing sends without you." |
| 5 | 38–48 | Open Settings → AI tab: Ollama / Anthropic / OpenAI picker. Then Privacy tab → network audit log. | "Run it on your own model. Audit every byte that leaves." |
| 6 | 48–60 | Back to the brief. Press H — card files itself. Final card: "FILE ALL". Empty desk: "The desk is clear." | "Inbox zero, for everything. — LLMessenger" |

GIF export (for HN): shots 1–3 only, 15s loop.

## Product Hunt draft

**Name:** LLMessenger
**Tagline:** Your messages, briefed. Every claim, sourced.
**Description (260 chars):**
A macOS menu-bar app that reads your Signal, Telegram, iMessage and Slack so
you don't have to. It writes a sourced intelligence brief — tap any claim to
see the exact messages behind it. Runs on your own model (Ollama) or
Anthropic/OpenAI. Nothing sends without your confirmation.

**First comment (maker):**
I built this because I was drowning: 4 messaging apps, ~40 group chats, and
the constant fear of missing the one message that mattered. Existing unified
inboxes just put all the noise in one place. LLMessenger reads everything and
hands me a morning brief instead — and because I don't trust black-box AI
with my messages either, every card cites its sources and you can run the
whole thing on a local Ollama model. Try the demo desk (no accounts needed) —
it's the first button on the welcome screen.

## Show HN draft

**Title:** Show HN: LLMessenger – a morning brief for Signal/Telegram/iMessage/Slack, with citations
**Body:** macOS menu-bar app. Polls your messengers locally, compiles an
intelligence brief, and shows the source messages behind every claim. LLM
backend is your choice — local Ollama (nothing leaves the Mac), Anthropic, or
OpenAI; there's a live audit log of every cloud call. Replies are drafted, but
nothing sends without explicit confirmation. There's a demo mode with sample
data so you can see the whole product without connecting anything.

## Pre-launch checklist

- [ ] **Sign + notarize the DMG** (Makefile `make dmg` already wired; needs Developer ID cert). Unsigned Gatekeeper-blocked installs will kill non-technical conversions.
- [ ] **Decide repo visibility** — HN audience converts on inspectable code; currently private.
- [ ] **Beta validation (3–5 users) before any launch:** ask (1) "what was the first moment it felt useful?", (2) "what would make you nervous handing this to someone you trust?", (3) "after a brief, did you feel you missed anything — how would you know?"
- [ ] **Record demo video** using shot list above.
- [ ] **Landing page** with the video above the fold + the two positioning angles.
- [ ] Verify brief quality on real noisy data (the demo promise must survive first contact with the user's own messages).
