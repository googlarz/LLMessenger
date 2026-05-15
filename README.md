# LLMessenger

**A macOS menu bar app that reads your iMessage, Signal, Telegram, and Slack conversations and turns them into structured, AI-generated briefs — so you can catch up in seconds instead of scrolling for minutes.**

![LLMessenger screenshot](docs/screenshot.png)

---

## What it does

LLMessenger sits in your menu bar. Every hour (or on demand) it polls your connected messaging services, feeds the messages to a local or cloud LLM, and produces per-conversation cards — each with a headline, prose summary, key quotes, and action items:

- **iMessage** — *Mum confirmed Sunday lunch — needs a reply* — REPLY NEEDED
  > Mum sent six messages confirming she's bringing the casserole and asking if you can pick up wine on the way.
  > **NEXT** Reply by 12:00 · Pick up wine

- **Telegram** — *Lisbon trip group narrowed dates to May 22–26* — HEADS-UP
  > The five of you converged on May 22–26 after Priya pushed back on the late-May option. Sam booked refundable flights.
  > **NEXT** Confirm flights by tonight · Vote on Airbnb

- **Slack** — *#eng-pricing settled on the new tier structure* — INFO
  > The team converged on three tiers after a 90-message debate. Engineering scoped the work to two sprints.
  > **NEXT** Acknowledge the proposal in #eng-pricing

Click any brief in the sidebar to open it. Ask follow-up questions ("who confirmed attendance?"), draft a reply by typing `@John …`, or have the AI write a draft you can review and send.

---

## Features

### Briefs
- **Unified inbox** — iMessage, Signal, Telegram, Slack (multi-workspace) in one place
- **Structured briefs** — headline, prose summary, action items, key quotes, priority (`high` / `med` / `low`)
- **Brief-card count first** — the header shows "1 brief across 1 app" so you see at a glance how much there is to read, not just raw message counts
- **Source grounding** — every card cites exact message IDs; quotes are validated against real messages
- **Sent-message context** — your replies (in iMessage, Signal, Slack) are captured and treated as conversation context, so the LLM knows when you've already responded
- **Conversation continuity** — rolling per-conversation summaries and unresolved actions carry forward across brief cycles
- **Episodic memory** — older briefs are compressed into context so the LLM references previous threads
- **Parallel brief generation** — each service summarised concurrently; one failure doesn't drop the rest
- **"Build 7-day summary" button** in Settings → Services → Data — bootstraps rolling per-conversation summaries when you first install, so the AI has memory of older threads

### Composing
- **AI Q&A** — ask questions about any conversation in natural language
- **Reply drafting** — request a draft, review it, send or discard
- **`@` mention picker** — type `@` in the chat input to write to anyone in any service. Suggestions are deduplicated by name across services and remember which service you used last
- **Quick-reply chips** — one-tap style-matched reply suggestions on brief cards

### LLM backends
- **Ollama (local, free)** — recommended for full privacy
- **Anthropic Claude** — best brief quality
- **OpenAI** GPT-4o / GPT-4o-mini

### Privacy (see [`PRIVACY.md`](PRIVACY.md))
- **Local-only mode** — single toggle that forces Ollama and skips cloud adapters. With it on, no message content leaves your Mac
- **Network audit log** — Settings → Privacy shows every cloud HTTPS call this session (provider, endpoint, status, bytes; never message content)
- **Pre-send redaction** — opt-in regex pass that replaces credit cards / SSNs / IBANs / email addresses with `[REDACTED:…]` tokens before sending to a cloud LLM
- **No telemetry, no analytics, no auto-update beacon**

### macOS integration
- **Hourly auto-refresh** with countdown; "New Brief", "Last 48h", and "Last 7d" on demand from the menu bar
- **macOS notifications** — tap to jump directly to the brief
- **Auto-launch at login** via `SMAppService`
- **Background poll errors surfaced** in the menu bar, not silently discarded
- **First-launch onboarding** — wizard walks through LLM, Signal, iMessage, Telegram, Slack in one flow
- **Anthropic-inspired dark UI** — floating, resizable panel, remembers position and size

---

## How it works

```
Menu Bar Icon
     │
     ▼
PollEngine ──► iMessage adapter   (~/Library/Messages/chat.db)
             ├─► Signal adapter   (signal-mcp SQLite + HTTP JSON-RPC)
             ├─► Telegram adapter (subprocess binary, NDJSON protocol)
             └─► Slack adapter    (Slack Web API, multi-workspace, native Swift)
                         │
                         ▼
                   AppDatabase (GRDB / SQLite)
                         │
                         ▼
                   BriefEngine
                   ├─ PromptBuilder      (source-grounded prompt with conversation state)
                   ├─ LLMClient          (Ollama / Anthropic / OpenAI)
                   ├─ MemoryCompressor   (compress old briefs → episodic summaries)
                   └─ ConversationState  (rolling summaries, unresolved actions)
                         │
                         ▼
                   Brief stored → UI notified → macOS notification sent
```

---

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ (to build from source)
- One or more messaging services (mix and match):
  - **iMessage** — Full Disk Access granted to LLMessenger in System Settings → Privacy & Security
  - **Signal** — [signal-mcp](https://github.com/googlarz/signal-mcp) running as a local daemon
  - **Telegram** — `telegram-adapter` binary (bundled or in `~/.config/llmessenger/adapters/telegram/`)
  - **Slack** — a Slack app you create at [api.slack.com/apps](https://api.slack.com/apps); paste the User OAuth Token (`xoxp-…`) into Settings → Services → Slack → Manage. Multi-workspace supported.
- One LLM backend:
  - **Ollama** (recommended for local use) — `brew install ollama && ollama pull llama3.1`
  - **Anthropic API key** — best brief quality
  - **OpenAI API key**

---

## Quick start

### Download (macOS)

Grab the latest DMG from the [Releases page](https://github.com/googlarz/LLMessenger/releases/latest).

> **Gatekeeper note:** the DMG is currently unsigned. On first open, macOS will block it.
> Right-click the app → **Open** → **Open**, or go to **System Settings → Privacy & Security → Open Anyway**.

A GitHub Actions workflow ([`.github/workflows/release.yml`](.github/workflows/release.yml)) builds an unsigned `.app` from any tagged commit on a clean `macos-14` runner and uploads it as an artifact with a SHA-256 of the binary, so anyone can re-run the workflow to verify the binary matches the source.

### Build from source

```bash
git clone https://github.com/googlarz/LLMessenger
cd LLMessenger
brew install xcodegen
xcodegen generate
open LLMessenger.xcodeproj
```

Build and run in Xcode (`⌘R`). The app appears in the menu bar (envelope icon).

On first launch, the **onboarding wizard** guides you through:
1. Choosing your AI backend and entering credentials
2. iMessage Full Disk Access
3. Signal phone number
4. Telegram sign-in (if you have the adapter binary)
5. Slack — add later via Settings → Services → Slack → Manage

### Settings tabs

All settings are also available under the menu bar icon → **Settings**:

**AI tab** — pick Ollama / Anthropic / OpenAI; enter the API key for cloud providers; pick an Ollama model.

**Services tab** — per-service config:
- **iMessage** — toggle on; grant Full Disk Access when prompted
- **Signal** — enter your phone number (`+491234567890`); requires a local Signal daemon
- **Telegram** — click "Connect Telegram" to sign in interactively (phone → code → optional 2FA)
- **Slack** — click "Manage…" to add one or more workspace tokens

There's also a **Data** section at the bottom:
- **Build 7-day summary** — runs a 7-day brief that also populates rolling per-conversation summaries so future briefs have memory
- **Sync contacts** — refreshes the `@` mention picker

**Privacy tab** — Local-only mode toggle, redaction toggle, full data-flow explainer, and a live network audit log of every cloud HTTPS call this session.

**Instructions tab** — base prompt + per-service guidance.

**About tab** — version, source link, Run Setup Wizard button.

### Trigger your first brief

Click the envelope icon → **New Brief**. Subsequent briefs run automatically every hour. If this is your first time, also click **Build 7-day summary** in Settings → Services → Data so the LLM has rolling memory of older threads.

---

## Project structure

```
LLMessenger/
├── AppDelegate.swift                  # App bootstrap, service wiring, onboarding gate
├── Core/
│   ├── Adapters/
│   │   ├── MessengerAdapter.swift      # Protocol: fetch / send / healthCheck / listContacts
│   │   ├── iMessageAdapter.swift       # Reads ~/Library/Messages/chat.db
│   │   ├── SignalCLIAdapter.swift      # Reads signal-mcp SQLite, sends via HTTP RPC
│   │   ├── SubprocessAdapter.swift     # Generic NDJSON subprocess adapter (Telegram)
│   │   └── Slack/
│   │       ├── SlackAdapter.swift      # Multi-workspace Slack adapter
│   │       ├── SlackAPIClient.swift    # Slack Web API HTTPS client with rate-limit pacing
│   │       └── SlackWorkspace.swift    # Workspace model + Keychain storage
│   ├── Brief/
│   │   ├── BriefEngine.swift           # Orchestrates polling → LLM → storage
│   │   ├── BriefJSON.swift             # Type-safe Codable structs for LLM output
│   │   ├── BriefRepository.swift       # GRDB queries for briefs, cards, messages, contacts
│   │   ├── MemoryCompressor.swift      # Compress old briefs into episodic summaries
│   │   └── QuickReply.swift            # Style-matched quick-reply suggestions
│   ├── Contacts/
│   │   ├── Contact.swift               # Unified contact model
│   │   └── ContactDirectory.swift      # Aggregates contacts across adapters; preferred-service tracking
│   ├── Instrumentation/
│   │   ├── InstrumentationManager.swift
│   │   ├── NetworkAuditLog.swift       # In-memory record of every cloud HTTPS call
│   │   └── MessageSanitizer.swift      # Opt-in CC/SSN/IBAN/email redaction
│   ├── LLM/
│   │   ├── LLMClient.swift             # Protocol + Ollama/Anthropic/OpenAI impls
│   │   ├── LLMProvider.swift           # Provider enum + factory
│   │   ├── IntentRoute.swift           # Structured intent routing for the chat input
│   │   └── PromptBuilder.swift         # Prompt templates per LLM mode
│   ├── PollEngine.swift                # Hourly scheduler, adapter registry
│   ├── Settings/
│   │   └── SettingsRepository.swift    # UserDefaults + Keychain config store
│   └── Store/
│       ├── AppDatabase.swift           # GRDB setup + migrations (v1..v10)
│       └── Models/                     # Brief, BriefCard, Message, ConversationState, ConversationContext, PriorityCorrection, …
├── MenuBar/
│   └── MenuBarController.swift         # NSStatusItem, menu, brief list, unread badge
└── UI/
    ├── Theme.swift                      # Dark palette + service colors
    ├── ChatInputView.swift              # Composer with @ mention picker
    ├── MentionPickerView.swift          # Popover for the @ mention picker
    ├── ChatPanelView.swift              # Main panel: prose + AI thread + composer
    ├── ChatViewModel.swift              # Q&A + reply draft + mention target state
    ├── BriefListView.swift              # Sidebar with grouped brief history
    ├── BriefHeaderView.swift            # Brief-count headline + status pill
    ├── BriefProseView.swift             # Flowing prose view, source filter chips
    ├── ContentView.swift
    ├── Onboarding/
    │   └── OnboardingWindowController.swift  # First-launch wizard
    └── Settings/
        ├── SettingsView.swift
        ├── LLMSettingsTab.swift
        ├── ServiceSettingsTab.swift      # Per-service config + Data Maintenance
        ├── PrivacySettingsTab.swift      # Local-only / redaction / network audit log
        ├── InstructionsSettingsTab.swift
        ├── AboutSettingsTab.swift
        ├── SlackWorkspacesView.swift     # Slack workspace list + Add sheet
        └── TelegramSignInView.swift      # Interactive Telegram auth flow
```

---

## Privacy & Safety

See [`PRIVACY.md`](PRIVACY.md) for the full data-flow story. TL;DR:

- **There is no LLMessenger server.** The developer cannot see your messages.
- **Your data lives only on your Mac** in `~/Library/Application Support/LLMessenger/`.
- **Cloud egress only happens if you configure it.** With Ollama + no Anthropic/OpenAI/Slack: zero message content leaves your machine.
- **Local-only mode** is one toggle in Settings → Privacy. Forces Ollama and skips the Slack adapter.
- **Network audit log** in Settings → Privacy lets you verify outbound calls live — metadata only, never message content.
- **API keys and Slack tokens** are in the macOS Keychain, never in plain files.
- **No telemetry, no analytics, no auto-update beacon.**

---

## Distribution & notarization

See [`docs/NOTARIZATION.md`](docs/NOTARIZATION.md) for instructions on building a signed, notarized `.app` for distribution. A `Makefile` provides `build`, `archive`, `export`, `notarize`, and `dmg` targets.

For reproducible verification, the [`release.yml`](.github/workflows/release.yml) GitHub Actions workflow builds the `.app` on a clean `macos-14` runner from any tag and uploads it with a SHA-256 of the binary.

---

## Roadmap

### Shipped (v1.4)
- ✅ Search across messages and briefs
- ✅ Brief history date filter
- ✅ Pin important briefs
- ✅ Slack adapter (multi-workspace)
- ✅ `@` mention picker
- ✅ Sent-message capture (replies appear as context)
- ✅ Local-only mode + network audit + redaction
- ✅ Reproducible release workflow

### v1.5
- [ ] WhatsApp adapter (pending viable local API)
- [ ] Per-conversation quiet hours
- [ ] User-defined priority rules
- [ ] Adapter plugin API for third-party services

---

## License

MIT
