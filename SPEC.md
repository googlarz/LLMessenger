# SPEC — LLMessenger v1.7 "Real-Time Desk"

Status: **approved** · Target: v1.7.0 · Baseline: v1.6.1 (main, CI green, 430 tests)

## 1. Objective

v1.x summarizes messages every hour. **v2.0 guards attention in real time.** The release re-centers the product on one promise: *a message that needs you reaches you in seconds; everything else waits silently for your digest.*

**Target users** (in priority order):
1. The overwhelmed multi-chat user — five group chats, two Slack workspaces, family iMessage. Wants to stop checking apps.
2. The privacy-conscious Mac user — adopts only because triage is on-device.
3. The contributor — wants to plug a new service in without forking.

**Why this is a major version:** new always-on triage engine, UI reorganized around a new mental model, plugin ABI freeze, and DB schema additions. Not version theater.

### Non-goals (explicitly out of scope for 1.7)
- Email adapter (on roadmap, deferred to a future release)
- WhatsApp adapter (blocked on viable local API — plugin API is the answer instead)
- iOS companion, multi-Mac sync, audio briefings
- Auto-sending anything, ever
- Cloud-LLM real-time triage by default (cost + privacy; see Boundaries)

---

## 2. Features & acceptance criteria

### F1 — Real-Time Firewall (the headline)

Watch for new messages as they arrive; triage each conversation within seconds using a local LLM; interrupt only when the triage says REPLY NEEDED (or a rule says so). Hourly brief generation remains, but as the *summarization* cycle, no longer the *notification* cycle.

**Mechanism**
- New `RealtimeMonitor` (Core/Realtime/): a `DispatchSourceFileSystemObject` watcher on `~/Library/Messages/chat.db-wal` for iMessage (hard guarantee); Signal and Telegram use best-effort short-interval poll (30 s) — no viable file-system hook exists for either; Slack tightens to adapter-supported minimum. Plugin adapters: opt-in short-interval poll.
- Debounce window 3 s; coalesce per conversation. Incremental fetch through the existing adapter `fetchMessages(since:)` path — no new DB readers.
- `TriageEngine` (Core/Realtime/): rules first (short-circuit, no LLM), then a single small prompt per changed conversation → `{priority, needsReply, reason}` JSON. Triage prompt budget ≤ 1k tokens in, ≤ 100 out.
- Triage runs **only** on local backends (On-Device or Ollama). If the user's backend is cloud-only, real-time triage requires an explicit per-setting consent toggle (reuse `cloud_auto_briefs_consent` pattern) and is off by default.
- Triage decisions are persisted (`triageEvents` table) so the Today view and digest can explain *why* you were or weren't interrupted.

**Acceptance criteria**
- [ ] New iMessage with "can you call me?" from a contact → notification within 15 s on a warm engine (measured in an integration test with a fixture chat.db)
- [ ] Routine group-chat message → no notification; held-back counter increments; appears in next digest
- [ ] Engine survives chat.db WAL checkpoints, Messages.app restarts, and sleep/wake (unit-tested via simulated file events)
- [ ] CPU: idle monitor ≤ 0.5% sustained; no LLM call when no conversation changed
- [ ] Full Disk Access revoked mid-session → monitor degrades to hourly polling with a menu-bar health warning, no crash
- [ ] Kill switch: Settings toggle reverts the entire app to v1.x hourly behavior

### F2 — "The Desk" redesign (Now / Today / Archive + light mode)

One window, three altitudes, replacing the brief-list-as-inbox.

- **Now** — answers "does anything need me?": calm empty state ("Nothing needs you · 14 held back") or 1–3 priority cards with inline reply. Menu-bar icon reflects this state (filled = needs you, outline = calm).
- **Today** — chronological feed of today's conversations as they resolved: triage decisions, briefs, your replies, firewall holds. Each entry expandable to the full card.
- **Archive** — existing search/pins/history, restyled.
- **Light mode** — `Theme` tokens become semantic (`Theme.bg` etc. resolve per appearance); follow system, manual override in Settings. Wire Desk identity is preserved in both appearances.
- Reply-in-place: composer expands inside any card (Now/Today) without navigation.

**Acceptance criteria**
- [ ] All v1.x capabilities reachable in the new shell (search, pins, Q&A, drafts, @-mentions, settings) — no feature regressions
- [ ] Light + dark verified: zero hard-coded colors outside Theme.swift (lint check in CI: `grep` gate)
- [ ] Empty Now state renders correctly on first launch and in Demo Mode
- [ ] Menu-bar icon state changes are driven by the same store as the Now view (single source of truth)
- [ ] Before/after screenshots captured to `docs/design/snapshots/v2/`

### F3 — Priority rules v2 (extend existing engine)

`PriorityRule` (model, BriefEngine integration, RulesSettingsTab) already exists. v2.0 adds:

- **Quiet hours per conversation/service** (new fields: `quietStart`, `quietEnd`)
- **Rule suggestions from behavior**: if reply latency to a contact is consistently < 5 min across ≥ 5 conversations, surface "Always interrupt for X?" as a dismissible card in Today. Computed locally from existing sent-message data; no LLM needed.
- Rules drive the **real-time** path (TriageEngine consults rules before the LLM), not just brief post-processing.

**Acceptance criteria**
- [ ] "Always interrupt for Mum" fires through the real-time path even when triage says low priority
- [ ] "Never interrupt" + quiet hours suppress real-time notifications but items still appear in Today/digest
- [ ] Suggestion appears only with sufficient evidence; accepting creates a visible rule in Settings → Rules; dismissing never re-asks for that contact
- [ ] Migration preserves all existing v1 rules untouched

### F4 — Adapter plugin API v1 (ABI freeze)

Freeze the subprocess NDJSON protocol (already proven by the Telegram adapter) as a versioned public interface.

- `docs/PLUGIN-API.md`: protocol version handshake (`{"v":1}`), the 6 methods, message/contact JSON schemas, error contract, health-check semantics.
- Discovery: `~/.config/llmessenger/adapters/<name>/manifest.json` (`name`, `binary`, `protocolVersion`, `services`). App lists discovered plugins in Settings → Services with an enable toggle.
- Security: plugins are user-installed executables — manifest path validation, no shell interpolation (direct `Process` argv), plugin stdout size limits, malformed-NDJSON fuzz tests. Plugins are clearly labeled third-party in UI.
- Reference plugin: `examples/echo-adapter/` (tiny script) used by integration tests.

**Acceptance criteria**
- [ ] Echo adapter discovered, enabled, polled, and appears in briefs without any app code change
- [ ] Protocol version mismatch → plugin disabled with a clear message, app unaffected
- [ ] Malformed/oversized plugin output cannot crash or hang the app (fuzz-tested)
- [ ] PLUGIN-API.md is sufficient for a third party: the echo adapter is written against the doc only

---

## 3. Phasing (ship order, each phase lands green on main)

| Phase | Scope | Exit gate |
|---|---|---|
| **P0 Foundation** | Schema migrations (triageEvents, rule fields), semantic Theme tokens + light mode, hard-coded-color CI lint | All tests green; both appearances render |
| **P1 Desk UI** | Now/Today/Archive shell, menu-bar state, reply-in-place, Demo Mode updated | F2 criteria; screenshots committed |
| **P2 Rules v2** | Quiet hours, suggestions, rules wired for triage consumption | F3 criteria |
| **P3 Real-time** | RealtimeMonitor + TriageEngine + notifications path; longest soak | F1 criteria + 48 h personal soak (battery, dupes) |
| **P4 Plugin API** | Docs, discovery, echo adapter, fuzz tests | F4 criteria |
| **P5 Release** | Migration test from v1.6.1 DB snapshot, README/PRIVACY updates, security pass on new surfaces (plugins, file watcher), v1.7.0 tag | Full suite green on CI; upgrade-in-place verified |

P1 and P2 are parallelizable after P0. P3 depends on P0+P2. P4 is independent after P0. Estimated relative weight: P3 ≈ P1 > P2 ≈ P4 > P0.

## 4. Commands

```bash
xcodegen generate                                  # after any project.yml change
xcodebuild -scheme LLMessenger -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO test   # full suite — keep at 0 failures
make build / archive / notarize / dmg              # release packaging
```

CI (`.github/workflows/ci.yml`, macos-15): every push to main must stay green. Test count only goes up.

## 5. Project structure (new/changed)

```
LLMessenger/Core/Realtime/        # NEW — RealtimeMonitor, TriageEngine, TriageEvent model
LLMessenger/Core/Adapters/Plugins/# NEW — PluginDiscovery, PluginManifest (SubprocessAdapter reused)
LLMessenger/UI/Desk/              # NEW — NowView, TodayView, DeskShellView (Archive reuses restyled views)
LLMessenger/UI/Theme.swift        # CHANGED — semantic appearance-aware tokens
docs/PLUGIN-API.md                # NEW — frozen protocol v1
examples/echo-adapter/            # NEW — reference plugin
```

Existing layers unchanged in role: adapters feed GRDB, BriefEngine summarizes, UI reads stores. Realtime is a new consumer of adapters + producer of triage events, *not* a rewrite of PollEngine.

## 6. Code style

Match existing conventions: Wire Desk components (WireLabel, Rule, Theme tokens), GRDB record structs, protocol-first adapters, `// MARK:` sections, comments only for non-obvious *why*. No new dependencies without approval (GRDB stays the only package by default).

## 7. Testing strategy

- TDD for all engine logic (TriageEngine decisions, rule evaluation, IMAP parsing, plugin protocol handshake) — failing test first.
- Contract test suite shared across all adapters; email and echo-plugin adapters must pass it.
- File-watcher tests use a temp SQLite fixture + simulated WAL writes; no dependency on the real Messages DB in CI.
- Migration test: open a committed v1.6.1 database snapshot, run migrations, assert data integrity.
- Fuzz tests for plugin NDJSON input and IMAP server responses.
- UI: keep logic in view models where testable; visual verification via Demo Mode screenshots per phase.
- Suite stays fast (< 60 s) and deterministic — no network, no real LLM in tests (mock LLMClient as today).

## 8. Boundaries

**Always**
- Local-first: real-time triage on local models only, unless the user explicitly opts cloud in
- Every notification decision explainable (persisted triage event with reason)
- Atomic commits per slice; CI green before the next phase starts; migrations reversible-safe (additive only)

**Ask first**
- Any new package dependency (esp. IMAP)
- Any change to the frozen plugin protocol after PLUGIN-API.md lands
- Raising minimum macOS above 13.0
- Touching the existing brief-generation pipeline beyond adding triage hooks

**Never**
- Auto-send messages or emails
- Telemetry/analytics of any kind
- Write access to chat.db (read-only, forever)
- Ship a phase with failing or skipped-because-broken tests
- Cloud calls in real-time triage without the explicit consent toggle

---

## Decisions recorded

1. **Email adapter deferred** — not in v1.7; on roadmap for a future release.
2. **Signal/Telegram real-time**: best-effort 30 s poll — no viable file-system hook; iMessage gets FSEvents hard guarantee.
3. **No paid Apple developer account** — App Group/signed-widget paths stay on the file-fallback approach from v1.6.
4. Existing `PriorityRule` schema is extended, not replaced.
5. GRDB remains the only package dependency; no new external libraries without approval.
