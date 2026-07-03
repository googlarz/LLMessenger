# LLMessenger Launch Kit

Prep material for the later Product Hunt / Show HN launch. Nothing here is
published — it's staged so launch day is an execution day, not a writing day.

## Positioning

**Lead frame: MESSAGE DEBT — not message overload.**

"Morning brief" was the v1 frame and it's retired for launch, for three reasons:

1. It positions us in the *summarization* category, which Apple Intelligence
   now gives away free at the OS level. A summaries-led launch hands the top
   comment to "doesn't Apple already do this?" and has no answer.
2. It markets the feature the product itself demoted. The Act queue is the
   default tab; the digest is the archive. The product's arc was
   Summarize → Guard → Understand → Act — launch on where it arrived.
3. It names the wrong pain. "Too many messages" is an information problem.
   The real pain is social: **someone is waiting on you and you don't know
   who.** Unread count tells you what you received. Nothing on earth tells
   you what you OWE — until this. The product's own headline is literally
   "4 people are waiting on you."

**One-liner:** LLMessenger tracks what you owe people across every messaging
app — who's waiting, what you promised — and drafts the way out. Local-first,
and every AI claim cites the exact messages behind it.

**Category of one:** the first *message-debt* tracker. Every competitor
(Beeper, Texts, Apple Intelligence) organizes what arrived. LLMessenger is
organized around the only number that matters: how many people are waiting
on you. Everything else is proof stacked behind that hook:

1. **It acts, safely.** Replies drafted in your voice, queued for one-tap
   approval. Nothing ever sends without you: review-first by default,
   opt-in delegation only for low-risk acks with a 30s undo, audit log,
   and a kill switch. (This is the wow; the trust model is the moat.)
2. **Accountable AI.** Every card cites the exact source messages — tap any
   claim, read the evidence. Beeper's summarization and Apple Intelligence
   are black boxes. *(Verified 2026-06-12: no competitor has citation UI.)*
3. **Local-first, inspectable.** On-device / Ollama by default, live network
   audit log, no server, no telemetry, open source. The privacy story isn't
   a policy page — it's grep-able.
4. **Demo mode = zero-friction conversion.** The entire product runs on
   synthetic data with no accounts connected. "See it working in 60 seconds"
   is the CTA everywhere: first comment, video, README.

**Tagline (≤60 chars), recommended:**
> Knows who's waiting on you. Drafts replies. Local-first. (56)

Alternates:
> Stop counting unread. Start knowing who's waiting on you. (57)
> It tracks what you owe people — then drafts the way out. (56)

Fallback (if the debt frame tests badly with beta users):
> Your messages, briefed. Every claim, sourced. (45)

## 60-second demo video — shot list

Record in **Demo Mode** (fresh install → "Explore the demo desk") at 1280×800,
2× scale. No real messages on screen, no face cam needed.

| # | Seconds | Shot | Overlay text |
|---|---------|------|--------------|
| 1 | 0–6 | Menu bar glyph with badge. Click — Desk opens on the Act tab, "4 people are waiting on you." headline. | "Your unread count is a lie. This is the real number." |
| 2 | 6–16 | Owed Replies list: who's waiting, ranked, with "you promised the deck by Friday" callback line. | "It tracks what you owe — who's waiting, what you promised." |
| 3 | 16–28 | Click "3 SOURCES" on the Meridian card — evidence drawer opens, exact quoted messages. | "Every claim cites its source messages. No black-box AI." |
| 4 | 28–38 | Act queue: drafted reply ready → APPROVE → "SENDING IN 5s" countdown with UNDO. | "Replies drafted in your voice. Nothing sends without you." |
| 5 | 38–48 | Settings → AI tab: On-Device / Ollama / Anthropic picker. Privacy tab → live network audit log. | "Local AI by default. Audit every byte that leaves." |
| 6 | 48–60 | Clear the last item. Empty desk: "You're clear. Nothing needs you right now." | "Leave with confidence. — LLMessenger" |

GIF export (for HN): shots 1–3 only, 15s loop.

## Product Hunt draft

**Name:** LLMessenger
**Tagline:** Knows who's waiting on you. Drafts replies. Local-first.
**Description (260 chars):**
Unread counts show what you received. LLMessenger shows what you OWE — who's
waiting on you across iMessage, Signal, Telegram & Slack, and what you
promised. It drafts replies in your voice; nothing sends without your OK.
Local AI, open source, sourced claims.

**First comment (maker):**
I built this after realizing — days too late, again — that a friend had been
waiting on an answer from me all week. My unread badge said 214. Useless
number. The number I actually needed was: *3 people are waiting on you, and
you promised one of them a document by Friday.*

So LLMessenger tracks message debt, not message volume. It reads iMessage,
Signal, Telegram and Slack locally, keeps a ledger of who's waiting and what
you promised (both directions), and queues drafted replies in your voice for
one-tap approval.

Three things I refused to compromise on, because I have to trust this with
my own messages:
• **No black-box AI.** Every claim cites the exact source messages — tap and
  read the evidence. If a card says "Anna needs the cap table Thursday,"
  you can see the message where she said it.
• **Local-first.** On-device / Ollama by default, live network audit log,
  no server, no telemetry. It's open source — don't trust me, read it.
• **Nothing sends without you.** Every reply is review-first. Even the
  opt-in auto-send for trivial acks has a 30-second undo, an audit trail,
  and a kill switch.

Fastest way to judge it: **the demo desk** — the entire product on sample
data, zero accounts connected, first button on the welcome screen. 60
seconds and you'll know if it's for you. Happy to answer anything, including
the hard privacy questions.

## Objection playbook (pre-write these — top comments decide PH fate)

| Objection (will appear) | Answer |
|---|---|
| "Apple Intelligence already summarizes notifications" | Summaries tell you what happened. This tracks what you *owe* — who's waiting, what you promised — and drafts the way out. Also: Apple's summaries are black boxes; every LLMessenger claim cites its source messages. |
| "I would never give an app my messages" | Neither would I — it never leaves your Mac. Local model by default, live network audit log of every byte, no server, open source. And the demo needs zero accounts. |
| "Why is the app unsigned?" | Free community app, no $99 Apple fee baked in. CI publishes a SHA-256 of every build and you can build from source; signing lands if traction warrants it. |
| "WhatsApp?" | Adapter plugin API is on the roadmap (protocol already designed) — WhatsApp is the first target once there's a reliable local bridge. |
| "How accurate is the AI on a real inbox?" | Honest answer: it's grounded — cards that can't cite real source messages get rejected before you see them, and 'Check sources' confidence labels flag anything shaky. The demo shows exactly what the output looks like. |
| "Auto-send AI = scary" | Off by default, forever. The only auto-send possible is per-conversation opt-in, low-risk templated acks only, never free-form content, 30s undo, audit log, global kill switch — and message content can never enable it (injection-tested). |

## Launch-day run sheet (Sunday, times CET)

- **T-3 days:** schedule the launch on PH; repo public; pin the tour.mp4 to
  the repo README; ship page teaser live for early "notify me" subscribers.
- **09:01** — launch goes live (00:01 PT). Post first comment immediately.
- **09:05** — personal messages (not blasts) to the 10–20 people who agreed
  to support; each gets the demo pitch, not "please upvote."
- **09:30** — tweet thread: hook ("your unread count is a lie — the real
  number is who's waiting on you") + tour.gif + PH link. Cross-post to
  relevant subreddits (r/macapps, r/LocalLLaMA — the local-first angle
  lands there) spaced through the day.
- **09:00–15:00** — live in PH comments. Answer everything within minutes;
  maker responsiveness is a ranking input. Use the objection playbook.
- **15:00** — status check: if top-5, push the second wave (newsletter
  mentions, Discord/Slack communities). If not, keep engaging — evening PT
  traffic (18:00–24:00 CET) is the second surge.
- **Do NOT:** launch Show HN the same day. HN is a separate audience and a
  separate day (Tue/Wed following week, citations-led frame — HN cares more
  about the accountable-AI + local architecture than the debt hook).

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

## Product Hunt assets (generated 2026-07-03 — docs/launch/producthunt/)

All rendered from demo-fixture screenshots — no real message data anywhere.
Every frame shows the DEMO badge + "Example data — not your messages" banner.

- `01`–`06` gallery PNGs at 2540×1520 (2× PH's 1270×760 minimum), padded onto
  the Wire Desk dark ground for a uniform look.
- **`launch-film.mp4` (11.4s) — THE primary video.** Real product frames
  rendered through the offscreen snapshot harness: the queue ("4 people are
  waiting on you") → APPROVE → the "SENDING IN 5s" countdown genuinely
  draining (verified pixel-linear) → UNDO → end card with the tagline. Not a
  slideshow — the drain is real UI physics. `launch-film.gif` for tweets.
  Regenerate: TEST_RUNNER_SNAPSHOT_TAG=film TEST_RUNNER_RENDER_LAUNCH_FILM=1
  xcodebuild test -only-testing:.../testRenderLaunchFilmFrames + the ffmpeg
  assembly (see session notes).
- `thumbnail-animated-240.gif` — animated PH thumbnail: badge counts message
  debt 3 → 2 → 1 → ✓ → calm. Use INSTEAD of the static thumbnail; animated
  thumbnails stand out in the feed list.
- `tour.mp4` / `tour.gif` — crossfade stills tour (fallback/secondary).
- `thumbnail-240.png` — PH logo slot, from the 512px app icon.

**Gallery order on PH:** tour.mp4 first, then 01, 04 (sources — the
differentiator), 03, 05, 02, 06.

**Tagline:** superseded — see Positioning section (message-debt frame).
Gallery hero should show the "N people are waiting on you" headline; if the
current 01 frame leads with "One thing needs you," re-render the demo shot
with the Owed state front and center before launch.

**Topics:** Mac, Artificial Intelligence, Productivity, Privacy, Open Source

## Launch timing

PH days reset **12:01 AM Pacific** = **9:01 AM CET** — comfortable morning
start, no all-nighter.

Recommendation for a first launch with no follower base: **Sunday, 12:01 AM PT
(Sunday ~9:01 AM CET)**. Weekends have meaningfully less competition, so a
small launch can realistically reach top 5 and get the badge + newsletter
mention; weekday launches (Tue–Thu) have the most traffic but are dominated
by launches with prepared audiences. Saturday works too; Sunday is typically
the quietest. Plan to be responsive in comments for the first 4–6 hours
(9:00–15:00 CET) — early velocity and maker replies drive the ranking.

Submit the product a few days early as "scheduled" so PH's team can feature-
check it, and make sure the repo is public before the launch goes live.
