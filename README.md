# LLMessenger

**A macOS menu bar app that reads your Signal, Telegram, and iMessage conversations and turns them into structured, AI-generated briefs — so you can catch up in seconds instead of scrolling for minutes.**

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

Click any brief in the sidebar to open it. Ask follow-up questions ("who confirmed attendance?"), or let the app draft a reply you can review and send.

---

## Features

- **Unified inbox** — Signal, Telegram, iMessage in one place
- **Structured briefs** — headline, prose summary, action items, key quotes, priority (`high` / `med` / `low`)
- **Flowing prose, no bubbles** — messages rendered as readable text with inline service badges (`iM` / `Tg` / `Sg`)
- **AI Q&A** — ask questions about any conversation in natural language
- **Reply drafting** — request a draft, review it, send or discard
- **Any LLM** — Ollama (local, free), Anthropic Claude, or OpenAI
- **Hourly auto-refresh** with countdown; "New Brief" and "Brief Last 48h" on demand from the menu bar
- **Episodic memory** — prior briefs are compressed into context so the LLM references previous threads
- **Parallel brief generation** — each service summarised concurrently; one failure doesn't drop the rest
- **Source grounding** — every card cites exact message IDs; quotes are validated against real messages
- **Conversation continuity** — rolling summaries and unresolved actions carried forward across brief cycles
- **Background poll errors surfaced** — adapter failures during automatic polling shown in the menu bar, not silently discarded
- **First-launch onboarding** — wizard walks through LLM setup, Signal, iMessage, and Telegram in one flow
- **Anthropic-inspired dark UI** — floating, resizable panel, remembers position and size
- **macOS notifications** — tap to jump directly to the brief
- **Auto-launch at login** via `SMAppService`

---

## How it works

```
Menu Bar Icon
     │
     ▼
PollEngine ──► Signal adapter    (signal-mcp SQLite + HTTP JSON-RPC)
             ├─► Telegram adapter (subprocess binary, NDJSON protocol)
             └─► iMessage adapter (~/Library/Messages/chat.db)
                         │
                         ▼
                   AppDatabase (GRDB / SQLite)
                         │
                         ▼
                   BriefEngine
                   ├─ PromptBuilder      (source-grounded prompt with conversation state)
                   ├─ LLMClient         (Ollama / Anthropic / OpenAI)
                   ├─ MemoryCompressor  (compress old briefs → episodic summaries)
                   └─ ConversationState (rolling summaries, unresolved actions)
                         │
                         ▼
                   Brief stored → UI notified → macOS notification sent
```

---

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ (to build from source)
- One or more messaging services:
  - **Signal** — [signal-mcp](https://github.com/arian-gg/signal-mcp) running as a local daemon
  - **Telegram** — `telegram-adapter` binary (bundled or in `~/.config/llmessenger/adapters/telegram/`)
  - **iMessage** — Full Disk Access granted to LLMessenger in System Settings → Privacy & Security
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

### Build from source

```bash
git clone https://github.com/googlarz/LLMessenger
cd LLMessenger
open LLMessenger.xcodeproj
```

Build and run in Xcode (`⌘R`). The app appears in the menu bar (envelope icon).

On first launch, the **onboarding wizard** guides you through:
1. Choosing your AI backend and entering credentials
2. Signal phone number
3. iMessage Full Disk Access
4. Telegram sign-in (if you have the adapter binary)

### Manual setup (Settings)

All settings are also available under the menu bar icon → **Settings**:

**LLM tab:**

| Backend | What to set |
|---------|-------------|
| Ollama (local) | Model name, e.g. `llama3.1` or `gemma3` |
| Anthropic | API key (`sk-ant-…`) |
| OpenAI | API key (`sk-…`) |

**Services tab:**

- **Signal** — enter your phone number (`+491234567890`); requires [signal-mcp](https://github.com/arian-gg/signal-mcp)
- **Telegram** — click "Connect Telegram" to sign in interactively (phone → code → optional 2FA)
- **iMessage** — enable and grant Full Disk Access when prompted

### Trigger your first brief

Click the envelope icon → **New Brief**. Subsequent briefs run automatically every hour.

---

## Project structure

```
LLMessenger/
├── AppDelegate.swift                  # App bootstrap, service wiring, onboarding gate
├── Core/
│   ├── Brief/
│   │   ├── BriefEngine.swift          # Orchestrates polling → LLM → storage
│   │   ├── BriefJSON.swift            # Type-safe Codable structs for LLM output
│   │   ├── BriefRepository.swift      # GRDB queries for briefs, cards, messages
│   │   └── MemoryCompressor.swift     # Compress old briefs into episodic summaries
│   ├── Adapters/
│   │   ├── SignalCLIAdapter.swift      # Reads signal-mcp SQLite, sends via HTTP RPC
│   │   ├── SubprocessAdapter.swift     # Generic NDJSON subprocess adapter (Telegram)
│   │   └── iMessageAdapter.swift       # Reads ~/Library/Messages/chat.db
│   ├── LLM/
│   │   ├── LLMClient.swift            # Protocol + Ollama/Anthropic/OpenAI impls
│   │   ├── LLMProvider.swift          # Provider enum + factory
│   │   └── PromptBuilder.swift        # Prompt templates per LLM mode
│   ├── Polling/
│   │   └── PollEngine.swift           # Hourly scheduler, adapter registry
│   ├── Settings/
│   │   └── SettingsRepository.swift   # UserDefaults + Keychain config store
│   └── Store/
│       ├── AppDatabase.swift          # GRDB setup + migrations
│       └── Models/                    # Brief, BriefCard, Message, ConversationState, …
├── MenuBar/
│   └── MenuBarController.swift        # NSStatusItem, menu, brief list, unread badge
├── Notifications/
│   └── NotificationManager.swift      # UNUserNotificationCenter integration
└── UI/
    ├── Theme.swift                     # Dark palette + service colors
    ├── Onboarding/
    │   └── OnboardingWindowController.swift  # First-launch wizard
    ├── Settings/
    │   ├── SettingsWindowController.swift
    │   ├── LLMSettingsTab.swift
    │   ├── ServiceSettingsTab.swift
    │   └── TelegramSignInView.swift    # Interactive Telegram auth flow
    ├── BriefListView.swift             # Sidebar with grouped brief history
    ├── BriefProseView.swift            # Flowing prose view, source filter chips
    ├── ChatPanelView.swift             # Main panel: prose + AI thread + composer
    ├── ChatViewModel.swift             # Q&A + reply draft state
    └── ContentView.swift
```

---

## Privacy & Safety

Your messages never leave your machine silently.

| Data | Where it goes |
|------|--------------|
| Raw message text | Stored locally in SQLite — never sent without your action |
| Messages → LLM | Only when a brief is generated (manual or scheduled) |
| LLM: Ollama | Processed entirely on your machine — nothing leaves |
| LLM: Anthropic / OpenAI | Message text sent to the API over HTTPS to generate the brief, then discarded |
| Brief content | Stored locally in SQLite |
| Credentials (API keys, Signal number) | Stored in the macOS Keychain — never transmitted |

Cloud consent is enforced at runtime — toggling it off in Settings takes effect on the next brief cycle without requiring a restart.

No telemetry, no analytics, no third-party SDKs beyond the LLM API you choose.

---

## Distribution & notarization

See [`docs/NOTARIZATION.md`](docs/NOTARIZATION.md) for instructions on building a signed, notarized `.app` for distribution. A `Makefile` provides `build`, `archive`, `export`, `notarize`, and `dmg` targets.

---

## Roadmap

### v1.3 — Search & History
- [ ] Full-text search across all stored messages and briefs
- [ ] Brief history date-range picker
- [ ] Pin important briefs

### v1.4 — Richer Briefs
- [ ] Weekly digest (Monday morning: last 7 days)
- [ ] Per-conversation quiet hours
- [ ] User-defined priority rules

### v1.5 — Extensibility
- [ ] WhatsApp adapter (pending viable local API)
- [ ] Adapter plugin API for third-party services

---

## License

MIT
