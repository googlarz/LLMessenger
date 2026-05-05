# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
# Build
xcodebuild -scheme LLMessenger -configuration Debug build

# Run all tests
xcodebuild -scheme LLMessenger -configuration Debug test

# Run a single test class
xcodebuild -scheme LLMessenger -configuration Debug test -only-testing:LLMessengerTests/BriefEngineTests

# Regenerate Xcode project from project.yml (requires xcodegen)
xcodegen generate
```

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is the source of truth for project structure. When adding new Swift files, add them to `project.yml` and run `xcodegen generate` rather than editing `project.pbxproj` directly (though both work).

**Database**: In `DEBUG` builds, `eraseDatabaseOnSchemaChange = true` is set — any schema migration change wipes the local DB automatically.

## Architecture

The app is a macOS menu bar app with no storyboards. `AppDelegate` wires all dependencies manually at launch.

### Data flow

```
PollEngine (hourly Timer per service)
    └── MessengerAdapter.fetch()   ← each adapter returns AdapterConversation[]
            │
            ▼
    AppDatabase (GRDB/SQLite)      ← messages stored with briefId = NULL
            │
            ▼
    BriefEngine.processNewMessages()
        1. Compress previous brief via MemoryCompressor → episodicSummary
        2. Build PromptBuilder.build(mode: .summarizer) system prompt
        3. LLMClient.complete() → JSON string (one card per conversation)
        4. Store JSON in Brief.openingSummary
        5. Attach messages to brief (sets briefId)
            │
            ▼
    AppState.refreshBriefs() → notifies SwiftUI via @Published
```

### Key types

- **`MessengerAdapter`** — protocol for each service. `SignalCLIAdapter` reads signal-mcp's SQLite DB and calls its HTTP JSON-RPC API. `SubprocessAdapter` is generic stdin/stdout JSON-RPC for external binaries (used for Telegram).
- **`PollEngine`** — owns the per-service `Timer`s, tracks in-flight polls, writes `ServiceHealth` rows, calls `onPollSucceeded` after each successful poll.
- **`BriefEngine`** — fetches unattached messages (`briefId IS NULL`), calls the LLM in `eager` privacy mode, creates a `Brief` row, attaches messages.
- **`BriefRepository`** — all GRDB queries for briefs and messages. Both `BriefEngine` and `AppState` use it.
- **`AppState`** — `@MainActor ObservableObject` holding the brief list, selected brief, and the per-brief `Message[]` cache. Injected as `@EnvironmentObject`.
- **`ChatViewModel`** — `@MainActor ObservableObject` for the AI conversation thread (Q&A + reply drafting). `ThreadItem` is an enum: `.message`, `.assistantResponse`, `.replyDraft`.

### LLM output format

`PromptBuilder.suffix(for: .summarizer)` asks the LLM to return **JSON only** — no markdown fences. The schema is a `BriefJSON` with a `cards` array of `BriefCard`. `BriefProseView` decodes `brief.openingSummary` as `BriefJSON`; if decoding fails it falls back to rendering the raw text as markdown.

### LLM provider selection (AppDelegate.makeLLMClient)

1. Anthropic key in Keychain → `AnthropicClient`
2. OpenAI key in Keychain → `OpenAIClient`  
3. Neither → `OllamaClient` (model from `UserDefaults["ollama_model"]`)

API keys are stored in the system Keychain via `KeychainStore`. Signal account number is stored in `UserDefaults` (intentionally — avoids macOS permission prompts on rebuilt binaries).

### UI structure

`ChatWindowController` (NSPanel) hosts a SwiftUI `ContentView` split into:
- `BriefListView` — sidebar, grouped by date
- `ChatPanelView` — single `ScrollView` containing `BriefHeaderView` + `BriefProseView` + AI thread items + `ChatInputView` pinned at bottom

`Theme.swift` defines the Anthropic-style dark palette. All colours live there — do not hardcode colours elsewhere.

### Adding a new service adapter

1. Create a class conforming to `MessengerAdapter` in `Core/Adapters/`
2. Register it in `AppDelegate.applicationDidFinishLaunching` with `engine.register(adapter:config:)`
3. Add a `ServiceConfig.default(for:)` case in `ServiceConfig.swift`
4. Add colour + display name in `Theme.serviceColor` / `Theme.serviceName`

### Privacy modes

Each `ServiceConfig` has `privacyMode`: `"on_demand"` (LLM only runs when user explicitly requests) or `"eager"` (LLM runs on every poll). `BriefEngine` only calls the LLM when all fetched services are `eager`.
