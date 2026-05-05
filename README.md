# LLMessenger

**A macOS menu bar app that reads your Signal, Telegram, and iMessage conversations and turns them into structured, AI-generated briefs — so you can catch up in seconds instead of scrolling for minutes.**

---

## What it does

LLMessenger sits in your menu bar. Every hour (or on demand) it polls your connected messaging services, feeds the messages to a local or cloud LLM, and produces a structured brief:

```
## MU11 Weddinger Wiesel – Group Chat Summary

### Timeline of Key Events

Mon, 5 May
- Ephraim confirmed training at Pankstraße 21, 16:00

Yesterday
- Last-minute venue change to Wiesenstraße — Gernot noted Ilan arrives 10 min late

### ⚡ Action Items
| # | Action | Owner | Status |
|---|--------|-------|--------|
| 1 | Share Teamplus access code | Ephraim | ⚠️ Pending |

### 🔔 Notable Notes
- gulizemzem033 left the group — M/W split is now permanent
```

Click any brief in the sidebar to open it. Ask follow-up questions ("who confirmed attendance?"), or let the app draft a reply you can review and send.

---

## Features

- **Unified inbox** — Signal, Telegram, iMessage in one place  
- **Structured briefs** — timeline of key events, action items table, notable notes  
- **Flowing prose, no bubbles** — messages shown as readable blockquote-style text with inline service badges (`iM` / `Tg` / `Sg`)  
- **AI Q&A** — ask questions about your messages in natural language  
- **Reply drafting** — request a draft, review it, send or discard  
- **Any LLM** — Ollama (local, free), Anthropic Claude, or OpenAI  
- **Hourly auto-refresh** with countdown; "New Brief" on demand from the menu bar  
- **Anthropic-inspired dark UI** — floating, resizable, remembers position and size  
- **Auto-launch at login** via `SMAppService`  
- **Privacy modes** — `on_demand` (summaries only when you ask) or `eager` (auto-summarise every poll)  
- **Episodic memory** — previous briefs are compressed into context so the LLM knows prior threads  
- **macOS notifications** — tap a notification to jump directly to the brief  

---

## How it works

```
Menu Bar Icon
     │
     ▼
PollEngine ──► Signal adapter (signal-mcp SQLite + HTTP JSON-RPC)
             ├─► Telegram adapter (subprocess binary)
             └─► iMessage adapter (future)
                         │
                         ▼
                   AppDatabase (GRDB / SQLite)
                         │
                         ▼
                   BriefEngine
                   ├─ MemoryCompressor  (compress old briefs → episodic summary)
                   ├─ LLMClient         (Ollama / Anthropic / OpenAI)
                   └─ PromptBuilder     (structured brief format)
                         │
                         ▼
                   Brief stored → UI notified → macOS notification sent
```

The UI is SwiftUI + AppKit. The main window is a floating `NSPanel` with an Anthropic-style dark theme (warm charcoal, coral accent). The sidebar shows brief history grouped by date; the main pane shows the selected brief as flowing prose.

---

## Requirements

- macOS 13 Ventura or later  
- Xcode 15+  
- One or more of:
  - **Signal** — [signal-mcp](https://github.com/arian-gg/signal-mcp) running as a local daemon  
  - **Telegram** — `telegram-adapter` binary in `~/.config/llmessenger/adapters/telegram/`  
- One LLM backend:
  - **Ollama** (recommended for local use) — `brew install ollama && ollama pull gemma3` or similar  
  - **Anthropic API key** — best brief quality  
  - **OpenAI API key**

---

## Quick start

```bash
git clone https://github.com/googlarz/LLMessenger
cd LLMessenger
open LLMessenger.xcodeproj
```

Build and run in Xcode (`⌘R`). The app appears in the menu bar (envelope icon).

### Configure Signal

1. Install and run [signal-mcp](https://github.com/arian-gg/signal-mcp)
2. Open LLMessenger → menu bar icon → **Settings → Services**
3. Enter your Signal phone number (e.g. `+491234567890`)

### Configure the LLM

Open **Settings → LLM**:

| Backend | What to set |
|---------|-------------|
| Ollama (local) | Model name, e.g. `gemma3` or `llama3.2` |
| Anthropic | API key (uses `claude-haiku-4-5` by default) |
| OpenAI | API key (uses `gpt-4o-mini` by default) |

Ollama is chosen automatically when no API key is set. Anthropic takes priority if both are present.

### Trigger your first brief

Click the envelope icon → **New Brief**. The app polls your services, sends messages to the LLM, and displays the structured brief. Subsequent briefs run automatically every hour.

---

## Project structure

```
LLMessenger/
├── AppDelegate.swift              # App bootstrap, service wiring
├── Core/
│   ├── Brief/
│   │   ├── BriefEngine.swift      # Orchestrates polling → LLM → storage
│   │   ├── BriefRepository.swift  # GRDB queries for briefs + messages
│   │   └── MemoryCompressor.swift # Compress old briefs into episodic summaries
│   ├── LLM/
│   │   ├── LLMClient.swift        # Protocol + Ollama/Anthropic/OpenAI impls
│   │   ├── LLMProvider.swift      # Provider enum + factory
│   │   └── PromptBuilder.swift    # Structured brief prompt templates
│   ├── Polling/
│   │   ├── PollEngine.swift       # Hourly scheduler, adapter registry
│   │   ├── SignalCLIAdapter.swift # Reads signal-mcp SQLite, sends via HTTP
│   │   └── SubprocessAdapter.swift# Generic subprocess-based adapter
│   └── Store/
│       ├── AppDatabase.swift      # GRDB setup + migrations
│       └── Models/                # Brief, Message, ServiceConfig, ServiceHealth
├── MenuBar/
│   └── MenuBarController.swift   # NSStatusItem, menu, brief list
├── Notifications/
│   └── NotificationManager.swift # UNUserNotificationCenter integration
├── Settings/
│   ├── AutoLaunchManager.swift   # SMAppService login item
│   └── SettingsRepository.swift  # UserDefaults-backed config store
└── UI/
    ├── Theme.swift                # Anthropic-style dark palette + service colors
    ├── BriefListView.swift        # Sidebar with grouped brief history
    ├── BriefHeaderView.swift      # Collapsible header, AI summary bar
    ├── BriefProseView.swift       # Flowing prose view, source filter chips
    ├── ChatPanelView.swift        # Main panel: prose + AI thread + composer
    ├── ChatInputView.swift        # Always-visible composer (Claude-style)
    ├── ChatViewModel.swift        # Q&A + reply draft state
    └── Settings/                  # Settings window (LLM, services, launch)
```

---

## Privacy

- Messages are stored locally in SQLite (`~/Library/Application Support/LLMessenger/llmessenger.db`)
- With `on_demand` privacy mode, message text is **never sent to the LLM** unless you explicitly request a summary
- With `eager` mode, messages are sent to whichever LLM backend you configured
- No data leaves your machine unless you use a cloud LLM (Anthropic / OpenAI)
- Signal credentials are stored in `UserDefaults` (not Keychain) to avoid macOS permission dialogs on rebuilt binaries

---

## Roadmap

- [ ] iMessage support via `imessaged` or `BlueBubbles`  
- [ ] Telegram OAuth setup in the UI  
- [ ] WhatsApp adapter  
- [ ] Reply sending for Telegram  
- [ ] Weekly digest briefs  
- [ ] Full-text search across all messages  
- [ ] App-store-ready packaging  

---

## License

MIT
