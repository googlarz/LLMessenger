# LLMessenger — Product Requirements Document

**Version:** 1.0  
**Date:** 2026-05-06  
**Status:** Living document

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

**Secondary (future):** Non-technical users once a packaged .app distribution exists.

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
- Signal credentials stored in `UserDefaults` (not Keychain — see roadmap)

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
- macOS only (13 Ventura+) — no iOS, no web app
- Requires external daemons for Signal (signal-mcp) and Telegram adapter binary
- LLM quality is bounded by chosen backend; local models may produce lower-quality briefs

**Non-goals (v1.0):**
- Multi-account per service
- End-to-end encrypted storage of brief content
- Real-time push (the app is pull-based by design)
- WhatsApp support (no viable local API)

---

## 8. Roadmap

### v1.1 — Distribution & Onboarding
- [ ] Signed `.app` bundle for direct download (no Xcode required)
- [ ] First-launch onboarding wizard (connect services, pick LLM, test brief)
- [ ] Telegram credential setup directly in the Settings UI (currently requires manual session file)
- [ ] Move Signal phone number from UserDefaults to Keychain

### v1.2 — Search & History
- [ ] Full-text search across all stored messages and briefs
- [ ] Brief history beyond the current sidebar (date-range picker)
- [ ] Pin important briefs to the top of the sidebar

### v1.3 — Richer Briefs
- [ ] Weekly digest brief (Monday morning: last 7 days across all services)
- [ ] Per-conversation quiet hours (suppress from auto-brief, still available on demand)
- [ ] User-defined priority rules ("always mark messages from +491234... as high")

### v1.4 — WhatsApp / Extensibility
- [ ] WhatsApp adapter (if a viable local API emerges)
- [ ] Adapter plugin API so third parties can add services without forking

### v2.0 — Team / Shared Contexts *(exploratory)*
- [ ] Shared brief workspace for small teams (opt-in, self-hosted)
- [ ] Calendar integration — surface meetings mentioned in threads

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

1. **Packaging** — Ship as open-source build-from-source only, or signed notarized .app? (Notarization requires Apple Developer account + sandboxing audit)
2. **Keychain vs UserDefaults** — Signal phone number and API keys currently in UserDefaults; should migrate to Keychain for security
3. **Signal name resolution completeness** — Group members with `number: null` not in any contact list are shown as "Unknown"; acceptable UX or worth a deeper Signal-cli protocol investigation?
4. **Telegram session management** — Current flow requires running `pyrogram` interactively once to create a session file; this is a significant onboarding hurdle for non-technical users
5. **LLM cost transparency** — Should the app show estimated token usage / API cost per brief?
