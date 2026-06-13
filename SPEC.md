# SPEC — LLMessenger v2.0 "Understand"

Status: **approved** · Target: v2.0.0 · Baseline: v1.7.0 (main, 451 tests) · Release: one cohesive 2.0.0 (Owed Replies built first, shipped with the whole)

## 1. Objective

1.7 protected your **attention** (real-time firewall: stop noise reaching you). 2.0 protects your **relationships**: it learns who matters and what's important to you, and makes sure you never drop the people who count.

The release has one thesis — **Understand** — with three reinforcing pillars:

- **Spine — Context.** You teach it, or it learns, who matters and what's important per conversation. (Priors.)
- **Brain — People memory.** A local model of your people, built from your own history. (Derived knowledge.)
- **Payoff — Owed Replies.** Because once it understands who matters, the most valuable thing it can do is surface the people waiting on you, ranked by who counts. (Application.)

Context is the input, people-memory is the model, Owed Replies is the feature the model unlocks. **Owed Replies ships first** — it's the cheapest (reuses 1.7's TriageEngine output), the most novel, and it proves the thesis before we invest in the context-authoring UX.

**Target users** (priority order):
1. The overwhelmed multi-chat user — five group chats, family iMessage. Their real fear isn't noise; it's *"did I forget to reply to someone important?"*
2. The privacy-conscious Mac user — adopts because the relationship model is local-only and never leaves the machine.
3. The contributor — extends context/triage via the existing protocols.

**Why this is a major version:** a new mental model (attention *debt*, not just attention *defense*), a personal relationship model, and context that re-grounds triage + summarization at the root. Not version theater.

### Non-goals (explicitly out of scope for 2.0)
- **Cross-conversation entity resolution** ("Mike" in two chats = same person?) — deferred to 2.1. Hard, privacy-sensitive, and the core ships without it.
- Email / WhatsApp / mobile companion — breadth dilutes an Understand release (different thesis).
- Auto-sending anything — boundary holds; every send is your click.
- Any server-side relationship model or sync.

---

## 2. Features & acceptance criteria

### F1 — Owed Replies (the payoff — ships first)

A surface that answers *"who's waiting on me that I care about?"*, ranked by who matters and how long they've waited.

**Mechanism**
- A reply is **owed** when a conversation has an incoming message that needed a reply (a `triageEvents` row with `needsReply = true`, OR a question-shaped incoming message found during history backfill) and **no** `isSent = true` message exists in that conversation after it.
- Backfill: on first run, derive owed replies from existing `chat.db` / `messages` history — value on day one, no weeks of observation.
- Ranked by: conversation context priority (F2) × age. A reply to "Mum" outranks a reply to a muted group.
- This is a **query over data 1.7 already produces** (`triageEvents` + `messages`), not new ML.
- New **Owed** view in the Desk (4th altitude alongside Now / Today / Archive): list of people waiting, each with the triggering message, age ("5 days"), and why it ranks ("Mum · always-prioritized"). Tap → reply in place.
- Per-entry actions: reply, snooze, mark handled, dismiss. A sent message anywhere after the trigger auto-clears the entry.
- Menu-bar surfacing: optional "N owed" count (off by default; respects firewall calm).

**Acceptance criteria**
- [ ] A conversation with a `needsReply=true` event and no later sent message appears in Owed; sending any reply clears it within one poll cycle
- [ ] Backfill derives owed replies from history on first launch with no real-time events present (tested against a fixture `chat.db`)
- [ ] Ranking puts high-context-priority conversations above low/muted ones regardless of age ties
- [ ] **Conservative by default**: a reply sent on any device (any `isSent=true` after the trigger) never shows as owed — under-flagging is preferred to false "you forgot X"
- [ ] Snooze hides an entry until its snooze date; dismiss suppresses it permanently for that message
- [ ] Owed count in menu bar is opt-in and zero when nothing is owed

### F2 — Conversation Context (the spine)

Per-conversation priors that re-ground triage, summarization, and Owed-Replies ranking.

**Mechanism**
- Extend the existing `conversationContexts` table (migration v8 already has `service`, `conversationId`, `label`, `priorityHint`) with:
  - `relationship` (text — "family", "work", "vendor", freeform)
  - `importantTopics` (JSON array — "training", "game times", "payments")
  - `noiseTopics` (JSON array — "carpool chatter", "reactions")
  - `keySenders` (JSON array — within a group, senders whose messages are signal: "Coach Mike")
  - `contextNote` (freeform — "my son's basketball team; coach posts announcements")
  - `responseExpectation` (text — "fast", "evening ok", "no reply needed")
- Context feeds three consumers:
  1. **TriageEngine** (1.7) — context becomes a prior *before* the LLM call; `keySenders` and `importantTopics` raise priority, `noiseTopics` lower it. Same short-circuit pattern as `RuleEvaluator`.
  2. **BriefEngine** — context note + glossary injected into the summarization prompt so summaries use your vocabulary and weight what you flagged.
  3. **Owed Replies** (F1) — `priorityHint` drives ranking.
- **Sender-weighting within groups**: `keySenders` means "Coach Mike is signal, parent banter is noise" — often more powerful than topic weighting.

**Entry modes** (recommend learned + conversational; form is the escape hatch):
- **Conversational** — "This is my son's basketball team; the coach posts about training and games, flag those, ignore the rest." Parsed into structured context fields by the LLM.
- **Learned** — see F3.
- **Manual** — a context editor in the conversation/settings view (power-user fallback).

**Acceptance criteria**
- [ ] Setting `keySenders=["Coach Mike"]` causes his messages to triage higher and parent banter lower, verified in TriageEngine tests
- [ ] A conversational context sentence is parsed into the correct structured fields (mock-LLM test with a fixed response)
- [ ] BriefEngine summaries for a contexted conversation reflect `importantTopics` (prompt-construction test asserts the fields are injected)
- [ ] Context survives migration; conversations with no context behave exactly as 1.7 (no regression)
- [ ] Editing context is reachable from the conversation surface without going into Settings

### F3 — Learned Context Suggestions (extends RuleSuggestionEngine)

The app proposes context from behavior; you confirm. Zero-effort, high-trust.

**Mechanism**
- Extend the existing `RuleSuggestionEngine` (1.7): beyond fast-reply detection, surface context suggestions from backfill + behavior — "You reply to Coach Mike within 2 min and ignore the other parents here. Prioritize his messages in this group?"
- Reuse 1.7's **dismissal logic** (confidence threshold, permanent dismissal in UserDefaults) to avoid nagging. Add a **rate limit**: at most N suggestion cards surfaced per day.
- **First suggestion within week one** — driven off `chat.db` backfill, not weeks of live observation.
- Accepting a suggestion writes a `conversationContexts` row (F2). Dismissing never re-asks for that conversation.

**Acceptance criteria**
- [ ] A fast-reply pattern across ≥5 conversations with one sender surfaces a `keySenders` suggestion
- [ ] Accepting writes the correct context field; dismissing records permanent suppression and never re-surfaces
- [ ] No more than the configured number of suggestions appear per day (rate-limit test)
- [ ] Suggestions are derivable from backfilled history alone (no dependency on live triage events)

### F4 — Learning Loop + Context-aware Privacy

Corrections teach the model; sensitive conversations get hard privacy boundaries.

**Learning loop**
- Inline correction on Triage/Owed/Brief decisions: "this wasn't important" / "this didn't need a reply" writes back to context — appends to `noiseTopics` or lowers `priorityHint` for that conversation.
- Persisted via the existing `priorityCorrections` table (migration v8). Next triage for that conversation reflects the correction.

**Context-aware privacy** (cheap, on-brand)
- Per-conversation `privacyOverride` field on `conversationContexts`: e.g. "local model only", "never draft replies".
- Enforced in TriageEngine, BriefEngine, and reply drafting: a conversation marked local-only is never sent to a cloud backend even if the global backend is cloud.

**Acceptance criteria**
- [ ] Marking a triage decision "not important" lowers that conversation's priority on the next triage (round-trip test)
- [ ] A conversation with `privacyOverride="local_only"` is never dispatched to a cloud LLM client, asserted at the dispatch boundary
- [ ] "Never draft" hides reply-draft affordances for that conversation
- [ ] Corrections and overrides survive migration and are visible/editable in the context editor

### F5 — Minimal Glossary + Context-aware Digest

Small surface, rounds out the thesis.

- **Glossary (minimal, per-conversation)**: aliases in context ("'The Hall' = home venue", "Coach = official announcements") injected into BriefEngine prompts so summaries use your words. *Per-conversation only* — cross-conversation entity resolution stays in 2.1.
- **Context-aware digest**: the Morning Digest leads with high-context-priority conversations; `noiseTopics`-dominated conversations collapse to a single line.

**Acceptance criteria**
- [ ] A per-conversation alias appears in the summarization prompt and is used in the resulting summary (mock-LLM test)
- [ ] Digest ordering places high-priority-context conversations above low ones (ordering test)

---

## 3. Phasing (ship order, each phase lands green on main)

| Phase | Scope | Exit gate |
|---|---|---|
| **P0 Foundation** | Schema: extend `conversationContexts` (F2 fields, `privacyOverride`); Owed-Replies derivation + history backfill; context→triage/brief wiring scaffold | All tests green; backfill runs on fixture `chat.db` |
| **P1 Owed Replies** | The payoff surface (F1) — Owed view, ranking, backfill, snooze/dismiss, opt-in menu-bar count | F1 criteria; screenshots committed |
| **P2 Context** | F2 — extended model, manual + conversational entry, sender-weighting, wired into TriageEngine/BriefEngine/Owed ranking | F2 criteria |
| **P3 Learned suggestions** | F3 — extend RuleSuggestionEngine, dismissal + rate limit, week-one backfill, accept→write context | F3 criteria |
| **P4 Loop + Privacy** | F4 — correction write-back, per-conversation privacy override enforced at dispatch | F4 criteria |
| **P5 Glossary + Digest** | F5 — per-conversation aliases, context-aware digest ordering | F5 criteria |
| **P6 Release** | Migration test from v1.7.0 DB snapshot, README/PRIVACY updates, security pass on new surfaces (context parsing, privacy override, backfill), v2.0.0 tag | Full suite green on CI; upgrade-in-place verified |

**Ship Owed Replies first (P1)**: it validates the thesis, is the cheapest (reuses 1.7), and gives the learned-context engine (P3) real signal to work from. P2–P5 are sequential refinements on the context spine.

## 4. Commands

```bash
xcodegen generate                                  # after any project.yml change
xcodebuild -scheme LLMessenger -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  OTHER_LDFLAGS="" test                            # full suite — keep at 0 failures
make build / archive / notarize / dmg              # release packaging
```

CI (`.github/workflows/ci.yml`, macos-15): every push to main stays green; color-lint gate stays enforced. Test count only goes up.

## 5. Project structure (new/changed)

```
LLMessenger/Core/Owed/                 # NEW — OwedReplyDeriver, OwedReply model, backfill
LLMessenger/Core/Context/              # NEW — ContextStore, ContextParser (conversational entry)
LLMessenger/Core/Store/Models/ConversationContext.swift  # CHANGED — extended fields
LLMessenger/Core/Rules/RuleSuggestionEngine.swift        # CHANGED — context suggestions
LLMessenger/Core/Realtime/TriageEngine.swift             # CHANGED — context as prior
LLMessenger/Core/Brief/BriefEngine.swift                 # CHANGED — context + glossary in prompt
LLMessenger/UI/Desk/OwedView.swift     # NEW — the payoff surface
LLMessenger/UI/Context/ContextEditor.swift               # NEW — manual context editor
docs/...                                # PRIVACY.md update for the local relationship model
```

Existing layers keep their role: adapters feed GRDB, TriageEngine/BriefEngine consume, UI reads stores. Owed Replies and Context are new *consumers/producers* of existing tables, not rewrites. Reuses 1.7: `conversationContexts`, `priorityCorrections`, `triageEvents`, `RuleSuggestionEngine` dismissal logic, `RuleEvaluator` short-circuit pattern.

## 6. Code style

Match existing conventions: Wire Desk components (WireLabel, Rule, ServiceStamp, Theme.* tokens — no hard-coded colors, enforced by CI lint), GRDB record structs, protocol-first, `// MARK:` sections, comments only for non-obvious *why*. No new package dependencies (GRDB stays the only one). Light + dark must both render.

## 7. Testing strategy

- TDD for all engine logic: Owed-Replies derivation, context evaluation in TriageEngine, suggestion confidence/rate-limit, learning-loop write-back, privacy-override enforcement — failing test first.
- Backfill + migration test: open a committed v1.7.0 DB snapshot + a fixture `chat.db`, run migrations and Owed-Replies backfill, assert correctness and data integrity.
- Mock LLM for context parsing and prompt-construction tests (no real LLM, no network — same as today).
- Privacy: an explicit test asserting a `local_only` conversation never reaches a cloud client at the dispatch boundary.
- Suite stays fast (< 60 s) and deterministic.

## 8. Boundaries

**Always**
- Local-first: the relationship/people model lives only on the user's machine; never synced, fully visible, one-tap deletable
- Every Owed/triage decision explainable (persisted reason)
- Owed Replies **under-flags** — a wrong "you forgot someone" is a trust-killer; prefer silence to a false positive
- Atomic commits per slice; CI green before the next phase; additive-only migrations

**Ask first**
- Any new package dependency
- Raising minimum macOS above 13.0
- Any change that makes the relationship model leave the device
- Touching the brief-generation pipeline beyond adding context hooks

**Never**
- Auto-send messages or emails
- Telemetry/analytics of any kind
- Write access to `chat.db` (read-only, forever)
- Cross-conversation entity resolution in 2.0 (it's a 2.1 decision with its own privacy review)
- Ship a phase with failing or skipped-because-broken tests

---

## Decisions (locked)

1. **Owed-reply derivation = Balanced** — owed when the latest inbound message has a `triageEvents.needsReply=true` row OR is question-shaped, AND no `isSent=true` message exists after it. **~14-day backfill** from `chat.db` history. Ranked by conversation context priority. Under-flags by default.
2. **One cohesive 2.0.0 release** — build P0–P6, ship together. Owed Replies (P1) is built first to de-risk the thesis but released with the whole.
3. **Owed Replies ships first in build order**, before the context-authoring UX — it proves the thesis and feeds the learned engine.
4. **Cross-conversation entity resolution is deferred to 2.1** — 2.0's people-memory stays per-conversation; no cross-chat identity graph.
5. **People-memory is local-only** — no sync, no server model; visible and deletable.
6. **Glossary is per-conversation aliases only** in 2.0.
7. **Email / WhatsApp / mobile remain out** — held for a later "Everywhere" release.
8. Existing `conversationContexts` and `priorityCorrections` schemas are **extended, not replaced**.
