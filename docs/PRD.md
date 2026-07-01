# LLMessenger — Product Requirements Document

**Version:** 1.2  
**Date:** 2026-05-08  
**Status:** Living document

---

## Current Product Status (v2.2.5+)

This PRD began as the v1 planning document. The shipped app has moved well past several sections below; treat older roadmap checkboxes as historical context, not the source of truth for current work.

Shipped since this document was first written:
- Act/Digest/Activity desk with owed replies, commitments, tasks, and suggested actions
- Review-first drafts with staged sends, undo windows, and per-conversation privacy controls
- Source-backed brief cards, confidence/trust explanation, local evidence drilldown, and learning controls
- Search, priority rules, quiet hours, notification firewall, demo mode, first-week guidance, and local product-health surfaces
- Local audit/proof surfaces for sent actions, held-back notifications, source-backed cards, and learning receipts

Current product principles:
- First run must be useful before private data is ready, via demo mode and clear setup diagnosis.
- No send should feel irreversible; visible undo/recovery is part of the product contract.
- Briefs should explain why each card appeared, how confident the app is, and what local sources support it.
- Privacy posture should be visible in-product, not only in documentation.

Next planning should start from the latest GitHub release notes and the current codebase, then update this document or replace it with a v2 PRD.

---

## 1. Problem Statement

Modern messaging is fragmented across Signal, Telegram, and iMessage. A typical user wakes up to dozens of unread conversations spread across three apps — and spends 20–40 minutes every morning just catching up, before doing any actual work. Important action items are buried in small talk; urgent requests are missed because the thread was long.

No existing tool solves this:
- Notification summaries (iOS 18, macOS Sequoia) are single-message, not thread-aware
- Third-party dashboards (Beeper, Franz) unify display but don't reduce reading load
- AI assistants require copy-pasting; they have no direct access to your messages

**LLMessenger turns scattered, raw message threads into structured, actionable briefs in under 30 seconds — entirely on your own machine.**

---

## 2. Vision

> *"Inbox zero for your messenger apps — without reading every message."*

LLMessenger is a private, local-first macOS tool that reads your Signal, Telegram, and iMessage conversations, synthesises them with an LLM, and delivers a structured brief you can act on in under two minutes. You can ask follow-up questions, draft replies, and send them — all from a single floating panel.

---

## 3. Target Users

**Primary:** Knowledge workers and developers on macOS who:
- Use 2–3 messaging apps simultaneously
- Have high message volume in group chats (sports teams, work groups, family)
- Value privacy — unwilling to route messages through cloud AI products
- Are comfortable with technical setup (Homebrew, API keys, Xcode)

**Secondary:** Non-technical users — unsigned DMG available since v1.2; notarized build follows once Developer ID is obtained.

---

## 4. Core Use Cases

| # | User Story | Priority |
|---|-----------|----------|
| UC1 | As a user, I open the app in the morning and see a brief of everything that happened overnight, so I don't have to read each app | P0 |
| UC2 | As a user, I can ask the app "what did Marta say about the dinner?" in natural language | P0 |
| UC3 | As a user, I can say "write to Joanna: running 10 min late" and have a draft appear for me to confirm before sending | P0 |
| UC4 | As a user, briefs run automatically every hour so I don't have to remember to refresh | P0 |
| UC5 | As a user, I get a macOS notification when a new brief is ready, and tapping it opens it directly | P0 |
| UC6 | As a user, I can generate a 48h on-demand brief to catch up after a weekend away | P1 |
| UC7 | As a user, the LLM remembers context from previous briefs ("following up on yesterday's outage discussion") | P1 |
| UC8 | As a user, I can choose between a local LLM (Ollama, fully private) and cloud APIs (Anthropic, OpenAI) | P1 |
| UC9 | As a user, I can configure per-service polling frequency and enable/disable each service independently | P1 |
| UC10 | As a user, iMessage is opt-in with clear guidance on Full Disk Access permission | P1 |

---

## 5. Features (Current — v1.0)

### 5.1 Brief Engine

- **Automatic polling** via `PollEngine` — hourly by default, configurable per service
- **On-demand briefs** — "New Brief" from menu bar triggers immediate poll + summarise
- **48h lookback brief** — "Brief Last 48h" for catch-up after absence
- **Per-service LLM calls** — each service summarised independently, cards merged
- **Conversation caps** — max 30 conversations per service (ranked by activity), 100 messages per conversation, to keep prompts manageable
- **Episodic memory** — prior briefs are compressed into 2–3 sentence summaries and injected into subsequent prompts for continuity
- **Partial success** — if one service's LLM call fails, others still attach to the brief; failed service messages stay unattached for the next cycle

### 5.2 AI Brief Format

Each brief contains JSON cards rendered as:
- **Headline** — one specific sentence ("Marta moved dinner to Friday")
- **Priority** — `high` (reply needed today) / `med` (read soon) / `low` (FYI)
- **Summary** — 2–3 sentence prose, no markdown
- **Action items** — concrete next steps, max 3 (empty if none required)
- **Quotes** — 1–3 verbatim quotes that earn their place (key decisions, strong opinions)
- **Callback** — reference to relevant prior context from episodic memory

### 5.3 Chat & Reply Drafting

- Natural language Q&A about any conversation in the current brief
- Named-send shortcut: `"write to Joanna: :-*"` → bypasses LLM, resolves contact client-side, drafts immediately
- Ambiguous targets → conversation picker UI (numbered list)
- LLM draft format: `DRAFT:<n>: text` — conversation number parsed, draft shown with Send / Discard
- Full conversation history replayed in LLM context for multi-turn chat

### 5.4 Messaging Adapters

**Signal**
- Reads `~/.local/share/signal-mcp/messages.db` (signal-mcp daemon)
- Name resolution: `listContacts` RPC (with `allNumbers: true`, 97 contacts) + group member cross-reference + direct read of signal-cli's `account.db` recipient table (covers group members not exposed via RPC)
- Sends via JSON-RPC to `http://localhost:7583/api/v1/rpc`

**Telegram**
- PyInstaller-bundled Python adapter via stdin/stdout NDJSON protocol
- Time-based fetch skips inactive dialogs (top message before `since`) to prevent prompt flooding
- Sends via `app.send_message()`

**iMessage**
- Reads `~/Library/Messages/chat.db` (requires Full Disk Access)
- Disabled by default; Settings shows FDA guidance + deep-link to Privacy & Security
- Falls back to stored DB messages when adapter unavailable

### 5.5 LLM Backends

| Backend | Selection logic | Default model |
|---------|----------------|---------------|
| Ollama | No API keys set | User-configured |
| Anthropic | API key present | `claude-haiku-4-5` |
| OpenAI | API key present | `gpt-4o-mini` |

Anthropic takes priority over OpenAI when both keys are set.

### 5.6 UI

- macOS menu bar app (`NSStatusItem`) — envelope icon with unread badge
- Floating `NSPanel` — resizable, remembers position/size across launches
- Anthropic-inspired dark theme — warm charcoal (`#1C1917`), coral accent (`#E87B5E`)
- Sidebar — brief history grouped by date, preview of first card headline
- Main pane — brief rendered as flowing prose with service badges (`Sg` / `Tg` / `iM`)
- Chat panel — Claude-style always-visible input composer at the bottom
- Source filter chips — toggle visibility by service
- Settings — tabbed: LLM, Services (per-service cards), Instructions, General

### 5.7 Privacy & Storage

- All messages stored locally in SQLite via GRDB
- Messages only sent to LLM when brief is generated (never silently)
- Ollama path: zero bytes leave the machine
- No telemetry, no analytics, no third-party SDKs beyond chosen LLM API
- Cloud consent is enforced at runtime — revoking it in Settings takes effect on the next brief cycle without restarting the app
- All credentials (Signal phone number, API keys, Slack token) stored in macOS Keychain via `SettingsRepository`

---

## 6. Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                    macOS Menu Bar                    │
│                  MenuBarController                   │
└──────────────────────┬──────────────────────────────┘
                       │ triggers
┌──────────────────────▼──────────────────────────────┐
│                    PollEngine                        │
│  Timer-based scheduler, per-adapter config           │
│  ┌─────────────┐ ┌──────────────┐ ┌──────────────┐  │
│  │SignalCLI    │ │Subprocess    │ │iMessage      │  │
│  │Adapter      │ │Adapter(Tg)   │ │Adapter       │  │
│  └──────┬──────┘ └──────┬───────┘ └──────┬───────┘  │
└─────────┼───────────────┼────────────────┼──────────┘
          │ AdapterFetchResult              │
┌─────────▼───────────────▼────────────────▼──────────┐
│                 BriefRepository (GRDB)               │
│              messages · briefs · health              │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│                   BriefEngine                        │
│  PromptBuilder → LLMClient → JSON parsing → storage  │
└──────────────────────┬──────────────────────────────┘
                       │ briefID
┌──────────────────────▼──────────────────────────────┐
│              SwiftUI + AppKit UI layer               │
│   BriefListView · BriefProseView · ChatViewModel     │
└─────────────────────────────────────────────────────┘
```

**Tech stack:** Swift 5.9 · SwiftUI + AppKit · GRDB (SQLite) · async/await · `@MainActor`

---

## 7. Constraints & Non-Goals

**Constraints:**
- macOS only (14 Sonoma+) — no iOS, no web app
- Requires external daemons for Signal (signal-mcp) and Telegram adapter binary
- LLM quality is bounded by chosen backend; local models may produce lower-quality briefs

**Non-goals (v1.0):**
- Multi-account per service
- End-to-end encrypted storage of brief content
- Real-time push (the app is pull-based by design)
- WhatsApp support (no viable local API)

---

## 8. Roadmap

> **Status key:** ✅ Shipped · 🔲 Planned

---

### ✅ v1.1 — Distribution & Onboarding *(shipped)*

- Unsigned DMG for direct download (Gatekeeper bypass via right-click → Open)
- First-launch onboarding wizard: LLM → Signal → iMessage → Telegram
- Telegram interactive sign-in flow (phone → code → 2FA) from within the app
- All credentials migrated to macOS Keychain via `SettingsRepository`

---

### ✅ v1.2 — Stability & Edge-Case Fixes *(shipped 2026-05-08)*

- `PollEngine`: fetch and store errors separated — `lastCheck` not updated on store failure
- `MemoryCompressor`: infinite-retry loop closed; empty-string sentinel written on permanent failure; `fetchOldestUncompressedBrief` filters `episodicSummary IS NULL` only
- Cloud consent enforced at runtime via `llmProviderDidChange` notification and `BriefEngine.client` hot-swap; `UnconfiguredLLMClient` returned when consent is off
- `onPollFailed` callback wires timer-triggered adapter failures to the menu bar error label
- Unattached messages capped at 7 days in `fetchUnattachedMessages()` to prevent stale-message prompt bloat
- CI test-registration guard script (`scripts/check-test-registration.sh`)

---

### 🔲 v1.3 — Search, History & Ollama UX

**Goal:** Let users find any message or brief instantly and remove friction from Ollama setup.

#### 3.1 Full-Text Search

**Data model**

| Object | Change |
|--------|--------|
| `messages` | No schema change — indexed via FTS5 external content table |
| `messages_fts` | New FTS5 virtual table: `content="messages"`, columns `text`, `sender`, `conversationName` |
| Migration | `AppDatabase` migration N: `CREATE VIRTUAL TABLE messages_fts USING fts5(...)` + three triggers (`after insert`, `after update`, `after delete` on `messages`) to keep FTS in sync |
| `briefs_fts` | New FTS5 virtual table on `briefs.rawContent`; same trigger pattern |

**Repository API** (add to `BriefRepository`)
```swift
struct SearchResult {
    let messageRowId: Int64
    let service: String
    let conversationId: String
    let conversationName: String
    let snippet: String       // FTS5 snippet(), max 64 tokens, highlighted
    let timestamp: Date
}

func searchMessages(query: String, service: String? = nil, since: Date? = nil, limit: Int = 50) throws -> [SearchResult]
func searchBriefs(query: String, since: Date? = nil, limit: Int = 20) throws -> [Brief]
```

Implementation uses `fts5` `MATCH` with FTS5 `snippet()` for highlighted excerpts. Query is sanitised (append `*` for prefix search, escape double quotes) before passing to `MATCH`.

**UI — `SearchView`**
- Search bar appears at the top of the `ChatPanelView` sidebar when user presses `⌘F` or clicks a magnifier icon in the sidebar header
- Results in a scrollable list; each row: service badge + conversation name + highlighted snippet + relative timestamp
- Filter chips below the search bar: `All` / `Signal` / `Telegram` / `iMessage` / `Briefs`
- Date-range filter: "Any time", "Last 7 days", "Last 30 days" segmented control
- Debounce: 300 ms after last keystroke before firing query
- Tapping a result: closes search, opens the corresponding brief or scrolls the chat panel to the conversation; if no brief contains the message, opens a "Messages from this conversation" view
- Empty state: "No results for «query»" with a hint to widen the date range
- Error state (FTS unavailable): "Search unavailable — try rebuilding the index in Settings"

**Success criteria**
- Query returning ≤ 50 results completes in < 200 ms on a database with 50 000 messages
- FTS5 triggers keep the index in sync with no manual rebuild required
- Prefix search (`tes*`) works; accent-insensitive matching works for Latin characters

---

#### 3.2 Brief History Date-Range Picker

**Data model:** No schema change. `Brief.createdAt` already stored.

**Repository API**
```swift
func fetchBriefs(from: Date, to: Date) throws -> [Brief]
```

**UI — `BriefListView` sidebar**
- A calendar/filter icon in the sidebar header opens a popover
- Popover contains: `DatePicker` (start) + `DatePicker` (end) + three quick-select buttons: "Last 7 days", "Last 30 days", "Last 90 days"
- When a range is active, a dismissible chip appears above the brief list: "📅 May 1–7 ✕"
- Clearing the chip resets to the default "show all" state (current behavior)
- The sidebar list groups briefs by day as before, limited to the selected range

**Success criteria**
- Picker opens and closes without jank; selection is reflected immediately
- Range filter state is not persisted across launches (always resets to "all")

---

#### 3.3 Pin Briefs

**Data model**
```sql
ALTER TABLE briefs ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
```
(Added as `AppDatabase` migration N+1.)

**Repository API**
```swift
func setPinned(briefID: Int64, pinned: Bool) throws
func fetchPinnedBriefs() throws -> [Brief]
```

**UI**
- Pinned briefs appear in a dedicated **"Pinned"** section at the top of the `BriefListView` sidebar, above the date-grouped list
- Right-click (or long-press on trackpad) on any brief row shows a context menu: **Pin** / **Unpin** (mutually exclusive based on current state)
- The pin icon (📌) appears on pinned rows in both the sidebar and the menu bar brief list
- Pinned briefs are excluded from the normal date-grouped list (no duplication)
- Maximum 10 pinned briefs; attempting to pin an 11th shows an alert: "Unpin an existing brief first"

**Success criteria**
- Pin state survives app restarts
- Context menu appears on right-click within 100 ms
- Pinned section is hidden when no briefs are pinned

---

#### 3.4 Ollama Model Listing

**Background:** Today the user must type the model name manually. Ollama exposes `GET http://localhost:11434/api/tags` which returns all pulled models.

**API shape (Ollama)**
```json
{
  "models": [
    { "name": "llama3.1:8b", "size": 4661211136, "modified_at": "2025-09-26T..." },
    { "name": "mistral:7b",  "size": 4109854720, "modified_at": "2025-08-01T..." }
  ]
}
```

**New component: `OllamaModelPicker`**
```swift
struct OllamaModelPicker: View {
    @Binding var selectedModel: String
    // Loads available models from /api/tags on appear; falls back to text field if Ollama is not running
}
```

**UI changes in `AISettingsTab` (Ollama section)**
- Replace `TextField("Model name…")` with `OllamaModelPicker`
- On appear: fire `GET http://localhost:11434/api/tags` (2 s timeout)
  - **Success:** show `Picker` with model names formatted as `llama3.1:8b (4.3 GB)`; selected value bound to `ollamaModel` state
  - **Timeout / connection refused:** show the original `TextField` with placeholder "Enter model name (Ollama not running)" and a ↺ retry button
- Model size formatted as GB (1 decimal place)
- A "Refresh" button (↺) re-fires the request without navigating away
- Selected model name (e.g. `llama3.1:8b`) is saved as-is to `SettingsRepository.ollamaModel`

**Success criteria**
- If Ollama is running with ≥ 1 model, picker shows within 500 ms of tab appear
- If Ollama is not running, text field appears and is editable
- Selecting a model from the picker and saving stores the exact model name string

---

### 🔲 v1.4 — Richer Briefs & Slack

**Goal:** Add recurring digest formats, per-conversation control, user-defined prioritisation, and a Slack adapter.

#### 4.1 Weekly Digest Brief

**What:** A Monday-morning brief covering all activity from the past 7 days, across all enabled services. Distinct from the standard hourly brief: narrative in style, surfaces themes and unresolved threads rather than listing every conversation.

**Data model**
```sql
-- briefs.type column distinguishes brief flavours
ALTER TABLE briefs ADD COLUMN type TEXT NOT NULL DEFAULT 'standard';
-- Values: 'standard' | 'weeklyDigest' | 'last48h'
```

**Scheduling**
- `PollEngine` gains a `WeeklyDigestTimer` that fires every Monday at 07:00 local time (using `Calendar.current.nextDate(after:matching:)`)
- Timer survives app relaunches: on `start()`, recalculate next Monday 07:00 and set timer accordingly
- The weekly digest is skipped if the app was not running at 07:00 (no catch-up; user can trigger manually via menu bar → "Weekly Digest" menu item)

**Prompt mode: `PromptBuilder.buildWeeklyDigestPrompt`**
- System message: instructs the LLM to produce a weekly digest — identify 3–5 recurring themes across all services, call out unresolved action items from the week, note significant changes in relationships or projects
- Output JSON schema identical to standard briefs (array of cards) but with `type: "weeklyDigest"` at the envelope level
- Per-service per-conversation breakdown still present but grouped under theme cards

**UI**
- Weekly digest cards render with a "🗓 Weekly" badge (teal colour) instead of the standard service badges
- Menu bar → "Weekly Digest" item triggers an immediate 7-day brief on demand (same as `summarizeLast(hours: 168, adapters:)`)
- Sidebar groups weekly digests under a "Weekly Digests" section, separate from daily briefs

**Success criteria**
- Timer fires within ±60 s of 07:00 Monday
- Digest covers messages from `now - 7 days` to `now` inclusive
- Manual trigger via menu bar completes within the standard 30 s brief-generation SLA

---

#### 4.2 Per-Conversation Quiet Hours

**What:** Users can suppress specific conversations from automatic briefs (e.g. a noisy family group) while still reading them on demand.

**Data model**
```sql
CREATE TABLE conversationPreferences (
    service       TEXT NOT NULL,
    conversationId TEXT NOT NULL,
    quietEnabled  INTEGER NOT NULL DEFAULT 0,   -- 0 = off, 1 = quiet at all times, 2 = time-windowed
    quietStart    INTEGER,                        -- minutes since midnight, e.g. 1320 = 22:00
    quietEnd      INTEGER,                        -- minutes since midnight, e.g. 480 = 08:00
    PRIMARY KEY (service, conversationId)
);
```

**Repository API**
```swift
func upsertConversationPreference(_ pref: ConversationPreference) throws
func fetchConversationPreference(service: String, conversationID: String) throws -> ConversationPreference?
func fetchQuietConversationIDs(service: String, at date: Date) throws -> Set<String>
```

**BriefEngine integration**
- Before building the LLM prompt, `BriefEngine.processNewMessages` calls `fetchQuietConversationIDs(service:at:)` and filters those conversations out of the per-service message set for automatic briefs
- Messages from quiet conversations are still stored and attached to the brief record (so they appear on demand); they just do not contribute cards to the auto-brief
- The 48h on-demand brief and weekly digest **ignore** quiet hours (always includes all conversations)

**UI**
- In `BriefProseView`, each conversation card has a `…` overflow menu (top-right of card): **"Mute from auto-briefs"**, **"Set quiet hours…"**, **"Unmute"**
- "Mute from auto-briefs": sets `quietEnabled = 1`, no time window — the conversation never appears in automatic briefs
- "Set quiet hours…": opens a sheet with two `DatePicker` (time-only mode) for start and end, plus a toggle to enable/disable the time window. Example: mute 22:00–08:00 to keep late-night group chats out of the morning brief
- A muted conversation shows a 🔕 icon on its card; hovering reveals "Muted — tap ··· to unmute"
- Settings > Services tab > per-service section lists all muted conversations with an Unmute button

**Success criteria**
- A muted conversation does not appear in the next automatic brief
- Unmuting takes effect on the next brief cycle without restarting
- Time-windowed quiet hours use the device's local timezone

---

#### 4.3 User-Defined Priority Rules

**What:** Users can define rules that override the LLM's priority assignment. Example: "any message from +491234567890 → always high"; "anything in the #alerts channel → always high".

**Data model**
```sql
CREATE TABLE userPriorityRules (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    enabled   INTEGER NOT NULL DEFAULT 1,
    field     TEXT NOT NULL CHECK(field IN ('sender', 'conversationName', 'text')),
    pattern   TEXT NOT NULL,          -- case-insensitive substring match
    priority  TEXT NOT NULL CHECK(priority IN ('high', 'med', 'low')),
    createdAt REAL NOT NULL
);
```

**Repository API**
```swift
func fetchEnabledPriorityRules() throws -> [UserPriorityRule]
func insertPriorityRule(_ rule: UserPriorityRule) throws -> Int64
func updatePriorityRule(_ rule: UserPriorityRule) throws
func deletePriorityRule(id: Int64) throws
```

**BriefEngine integration**
- After LLM response is parsed into `[BriefCard]`, `BriefEngine` calls `applyPriorityRules(_ cards: inout [BriefCard])` which:
  1. Fetches all enabled rules
  2. For each card, checks the card's `sender` / `conversationName` / `summary` fields against each rule's pattern (case-insensitive `contains`)
  3. If any rule matches, the card's `priority` field is overwritten with the rule's priority value
  4. All applied overrides are logged to `os_log` at `.debug` level for auditability

**UI — Settings > Instructions tab (or new "Rules" sub-tab)**
- List of rules, each row: `[field] contains "[pattern]" → [priority]` with enabled toggle and delete button
- "Add Rule" button opens a sheet:
  - Segmented control: Sender / Conversation / Message text
  - Text field: pattern (substring)
  - Priority picker: High / Medium / Low
  - "Add" button disabled until pattern is non-empty
- Rules are applied immediately to the next brief cycle (no restart required)
- Empty state: "No rules yet. Add one to always prioritise messages from specific people or groups."

**Success criteria**
- A rule matching a sender overrides LLM priority in the next brief
- Disabling a rule takes effect on the next brief cycle
- Rules survive app restarts

---

#### 4.4 Slack Adapter

**What:** Read Slack DMs, group DMs, and all joined channels using a user token (xoxp-). Send messages via the same token.

**Authentication**

Slack user tokens do not require an OAuth redirect server. The user generates one at `api.slack.com/apps` → "OAuth & Permissions" → "User Token Scopes". Required scopes:

| Scope | Purpose |
|-------|---------|
| `channels:history` | Read public channel messages |
| `channels:read` | List public channels |
| `groups:history` | Read private channel messages |
| `groups:read` | List private channels |
| `im:history` | Read DM messages |
| `im:read` | List DM conversations |
| `mpim:history` | Read group DM messages |
| `mpim:read` | List group DMs |
| `users:read` | Resolve user IDs to display names |

Token stored in Keychain via `SettingsRepository.loadSlackToken() / saveSlackToken(_ token: String)`.

**Settings UI**
- Settings > Services > Slack card: text field labelled "User Token (xoxp-…)" + Save button
- On save: call `auth.test` to validate; display workspace name + user on success; display error on failure
- Link: "How to get a user token →" opens `api.slack.com/apps` in the default browser

**`SlackAdapter` — `MessagingAdapter` conformance**

```swift
struct SlackAdapter: MessagingAdapter {
    let serviceID = "slack"
    // Fetches conversations in [since, now] using conversations.list + conversations.history
    func fetch(since: Date) async throws -> AdapterFetchResult
    // Sends a message via chat.postMessage
    func send(text: String, conversationID: String) async throws
    func stop() {}
}
```

**Fetching algorithm**
1. `conversations.list(types: "public_channel,private_channel,im,mpim", exclude_archived: true, limit: 200)` — paginate until all conversations retrieved; filter to `is_member: true`
2. For each conversation, check `last_message_ts`: if `last_message_ts < since`, skip (no new messages)
3. For conversations with activity: `conversations.history(channel: id, oldest: since.timeIntervalSince1970, limit: 100)` — paginate if `has_more: true`
4. User ID resolution: maintain an in-memory cache `[String: String]` (userID → displayName); on cache miss call `users.info(user: id)`; cache entries expire after 24 h

**Rate limiting**
- Slack Tier 3 allows 50+ calls/min for history methods
- After any `429` response: back off for `Retry-After` seconds (provided in response header) before retrying
- Maximum 3 retries per conversation before skipping with a warning logged to `os_log`

**Name resolution**
- Conversation names: `name` field for channels; `user` (resolved) for DMs; comma-joined user names for group DMs (truncated at 3 names + "and N others" if > 3)

**Send**
- `chat.postMessage(channel: conversationID, text: text)` via POST to `https://slack.com/api/chat.postMessage`
- On success: store sent message via `BriefRepository.storeSentMessage`
- On failure: surface error via `appState.lastError`

**Success criteria**
- With a valid user token, `fetch(since:)` returns messages from all joined channels and DMs within the time window
- Sending a message via LLMessenger appears in Slack within 5 s
- Adapter correctly skips conversations with no new messages (no unnecessary history calls)
- Rate-limit backoff prevents `429` cascades

---

### 🔲 v1.5 — Extensibility & WhatsApp

**Goal:** Open LLMessenger to third-party adapters and add WhatsApp if a viable local API becomes available.

#### 5.1 Adapter Plugin API

**What:** Allow third parties to write and distribute custom messaging adapters without forking the app.

**Design principle:** Plugins run as subprocesses communicating via the existing NDJSON protocol (same as the Telegram adapter). This gives isolation for free — a crashing plugin does not crash LLMessenger.

**`AdapterManifest.json`** (placed in the plugin bundle)
```json
{
  "id": "com.example.whatsapp-adapter",
  "displayName": "WhatsApp",
  "iconName": "whatsapp",
  "minimumAppVersion": "1.5.0",
  "binaryName": "whatsapp-adapter",
  "protocol": "ndjson-v1"
}
```

**Discovery**
- On launch, scan `~/.config/llmessenger/adapters/*/AdapterManifest.json`
- Parse each manifest; validate `minimumAppVersion` against the running app version
- Register valid adapters with `PollEngine` using `SubprocessAdapter` (existing class)
- Invalid or incompatible manifests logged to `os_log` and skipped

**Settings UI**
- Settings > Services shows a "Community Adapters" section listing all discovered plugins
- Each plugin card: icon + displayName + version + enable/disable toggle + "Remove" button
- "Remove" deletes the directory under `~/.config/llmessenger/adapters/<id>/`
- "Install from file…" button: opens file picker for a `.llmadapter` bundle (zip rename); extracts to `~/.config/llmessenger/adapters/<id>/`

**Protocol documentation**
- Published as `docs/adapter-protocol.md` in the repo
- Covers: NDJSON message shapes for `fetch`, `send`, `auth`, `health`; expected stdin/stdout framing; error codes

**Success criteria**
- A third-party adapter following the protocol specification works without any LLMessenger source changes
- An adapter with `minimumAppVersion` higher than the running version is rejected with a clear log message
- Removing an adapter via Settings stops its subprocess immediately

---

#### 5.2 WhatsApp Adapter *(speculative)*

**Status:** Blocked on a viable local API. No WhatsApp adapter will ship until a solution is found that meets the privacy bar (local-only, no message routing through third-party servers).

**Candidates being monitored:**
- **WA Web protocol** reverse-engineered implementations (e.g. Baileys, go-whatsapp) — historically fragile; WhatsApp regularly breaks them
- **WhatsApp Business API** — requires a Business account and routes messages through Meta servers; does not meet the local-first privacy requirement

**Trigger for development:** A stable, local-only, open-source WA client library that has been maintained for ≥ 6 months without a forced break by WhatsApp. Track at `docs/whatsapp-research.md`.

---

### v2.0 — Team / Shared Contexts *(exploratory)*

- Shared brief workspace for small teams (opt-in, self-hosted relay)
- Calendar integration — surface meeting references from message threads
- Multi-account per service

---

## 9. Success Metrics

| Metric | Target |
|--------|--------|
| Time to first brief after setup | < 5 minutes |
| Brief generation time (3 services, ~200 messages) | < 30 seconds |
| False-positive rate on "high" priority cards | < 10% (user feedback) |
| Message volume handled without LLM timeout | 500 messages / brief cycle |
| Crash-free sessions | > 99% |

---

## 10. Open Questions

1. ~~**Packaging** — Ship as open-source build-from-source only, or signed notarized .app?~~ **Resolved (v1.2):** Unsigned DMG shipped via GitHub Releases. Notarization deferred until a Developer ID is obtained.
2. ~~**Keychain vs UserDefaults** — Signal phone number and API keys currently in UserDefaults; should migrate to Keychain.~~ **Resolved (v1.1):** All credentials migrated to Keychain via `SettingsRepository`.
3. **Signal name resolution completeness** — Group members with `number: null` not in any contact list are shown as "Unknown"; acceptable UX or worth a deeper Signal-cli protocol investigation?
4. **Telegram session management** — Current flow requires running `pyrogram` interactively once to create a session file; this is a significant onboarding hurdle for non-technical users (addressed in v1.1 via `TelegramSignInView`, but session expiry recovery is not yet handled gracefully).
5. **LLM cost transparency** — Should the app show estimated token usage / API cost per brief?
6. **Slack token security** — User tokens (xoxp-) have broad access and do not expire. Should LLMessenger display a warning about token scope and link to token revocation instructions?
