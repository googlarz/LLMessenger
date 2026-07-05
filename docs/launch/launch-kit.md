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
app — who's waiting, what needs your attention — and drafts the way out.
Local-first, and every AI claim cites the exact messages behind it.

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

**Tagline (≤60 chars) — tournament winner (5 writers × 3 judges, 9.0/10):**
> 214 unread. 4 people waiting. Only one number matters. (54)

Both numbers are true (the maker's badge; the app's real headline), zero
adjectives, numeric rhythm, screenshot-able as-is.

Alternates (previous recommendation and runners-up):
> Knows who's waiting on you. Drafts replies. Local-first. (56)
> Your unread count lies. Someone's been waiting all week. (56)

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
**Tagline:** 214 unread. 4 people waiting. Only one number matters.
**Description (255/260 chars):**
Unread counts show what you received. LLMessenger shows what you owe — who's
waiting on you across iMessage, Signal, Telegram & Slack — and drafts
replies you approve with one tap. Every claim cites its source messages.
Local AI, open source. Demo in 60s.

**First comment (maker):**
Last month I found out a friend had been waiting a week for an answer from
me. A week of him thinking I'd seen it and didn't care. My unread badge said
214 — a number that told me everything I'd received and nothing about what
I owed.

So I built the opposite of an unread count. LLMessenger tracks message debt
across iMessage, Signal, Telegram and Slack. The headline in the app isn't a
count — it's "4 people are waiting on you." Then it drafts the way out:
replies in your voice, queued for one-tap approval, with a visible 5-second
countdown and undo on every send. Auto-send exists only as an opt-in for
trivial templated acks — 30-second undo, audit log, kill switch.

I built it to be distrusted first. Every card cites the exact source
messages — tap a claim, read the evidence; anything that can't cite a real
message gets rejected. It runs on-device by default (Apple Intelligence or
Ollama), no server, no telemetry, and it's Apache 2.0 — don't take my word
for any of this, read the code.

Honesty corner: it's unsigned (I skipped Apple's $99/yr fee), so macOS will
grumble once — or skip that entirely:

    brew tap googlarz/tap && brew install --cask llmessenger

Demo Mode is the first button on the welcome screen — the entire product on
synthetic data, zero accounts connected. 60 seconds and you'll know.

So: what does your badge say right now — and do you know who's actually
waiting on you? 👇

**Launch tweet (268/280, attach launch-film.gif):**
214 unread. 4 people waiting. Only one number matters.

Unread counts show what you received. LLMessenger shows what you OWE —
across iMessage, Signal, Telegram & Slack — and drafts the way out. Local
AI, open source, nothing sends without you.

Live on Product Hunt 👇

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

- **T-7 days:** create the PH "coming soon" teaser page — followers collected
  there get auto-notified at launch (free first-hour velocity). Publish the
  googlarz/homebrew-tap repo so the install one-liner is live.
- **T-3 days:** schedule the launch on PH (their team feature-checks early
  submissions); pin launch-film.mp4 to the repo README; send beta users the
  quote ask (template below).
- **09:01** — launch goes live (00:01 PT). Post first comment immediately.
- **09:05** — personal messages (not blasts) to the 10–20 people who agreed
  to support; each gets the demo pitch, not "please upvote."
- **09:30** — tweet thread: hook ("your unread count is a lie — the real
  number is who's waiting on you") + launch-film.gif + PH link. Cross-post to
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

**Title:** Show HN: LLMessenger – local AI for iMessage/Signal/Slack, with citations
**Body:** macOS menu-bar app. Polls your messengers locally, compiles an
intelligence brief, and shows the source messages behind every claim. LLM
backend is your choice — local Ollama (nothing leaves the Mac), Anthropic, or
OpenAI; there's a live audit log of every cloud call. Replies are drafted, but
nothing sends without explicit confirmation. There's a demo mode with sample
data so you can see the whole product without connecting anything.

## Pre-launch checklist

- [x] ~~Sign + notarize~~ — **decision: launch unsigned** (see objection
  playbook). Mitigations shipped: Homebrew tap strips quarantine, SHA-256
  published per release, build-from-source documented. Signing revisits
  post-traction (`make dmg` stays wired for that day).
- [x] ~~Repo visibility~~ — repo is already public (verified 2026-07-04).
- [ ] **Publish googlarz/homebrew-tap** (built + install-tested locally;
  needs the public repo push).
- [ ] **Beta validation (3–5 users) before any launch:** ask (1) "what was the first moment it felt useful?", (2) "what would make you nervous handing this to someone you trust?", (3) "after a brief, did you feel you missed anything — how would you know?" **Then the quote ask** (template in Social proof section) — 3 one-liners become gallery card 07.
- [ ] **Record the 60-second demo video** using the shot list above (the
  11s launch-film covers the hook; the 60s walkthrough covers understanding).
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

**Gallery order on PH:** launch-film.mp4 first (PH plays the first video
slot inline), then 01, 04 (sources — the differentiator), 03, 07 (quote
card, once beta quotes are harvested), 05, 02, 06. tour.mp4 is the fallback
if the film needs re-rendering after a UI change.

**Topics (PH lets you pick 3):** Artificial Intelligence (traffic), Mac
(relevance), Privacy (differentiation — the local-first crowd browses it).

## Social proof — quote card (gallery slot 07)

The one asset money can't render: real humans. After the beta round, send
each user this (personal, not a blast):

> You've been using LLMessenger for a bit — would you give me one honest
> sentence about it I can put on the launch page? Anything real: the moment
> it was useful, or what surprised you. First name + role is enough
> ("Marta, product manager"). And if the honest sentence is critical,
> tell me that instead — more useful before launch than after.

Three quotes → one 2540×1520 gallery card on the Wire Desk ground: serif
quotes, mono attribution, same typographic system as the app. The target
quote is the debt frame in a user's own words — e.g. "I found out someone
had been waiting on me for four days." Do not paraphrase; verbatim or not
at all.

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
