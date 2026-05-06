# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

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


<claude-mem-context>
# Memory Context

# [LLMessenger] recent context, 2026-05-06 8:36pm GMT+2

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 50 obs (18,200t read) | 680,976t work | 97% savings

### May 5, 2026
926 10:58p 🔵 Silent message loss in BriefEngine when LLM response fails to parse JSON
927 " 🔵 GRDB record.id != nil check unreliable for detecting newly-inserted rows after INSERT OR IGNORE
928 " 🔵 Reply drafts on multi-conversation briefs send to wrong recipient
929 " 🔵 Race condition: summarizeLast() bypasses briefingInFlight guard, duplicate briefs and doubled LLM cost
930 " 🔵 SubprocessAdapter.roundTrip discards JSON-RPC messages arriving after first newline in chunk
931 " 🔵 Signal account silently deleted if Keychain migration write fails
932 " 🔵 Instructions tab poll interval slider dead UI: no runtime effect on polling timers
S127 Fix all identified bugs from code review of LLMessenger Swift application (May 5 at 10:59 PM)
### May 6, 2026
934 6:23a 🔵 BriefEngine orchestrates per-service message summarization with episodic memory compression
935 " 🔵 PollEngine manages periodic polling of messenger adapters with failure tracking and health reporting
936 " 🔵 SubprocessAdapter uses JSON-RPC over pipes for IPC with external messenger adapters
937 " 🔵 ChatViewModel implements conversational reply drafting and assistant responses with context capping
938 " 🔵 SettingsRepository stratifies secrets storage: keychain for credentials, UserDefaults for UI prefs, database for service configs
939 " 🔵 InstructionsSettingsTab lets users customize system prompt, theme, and poll interval with live preview
940 6:24a 🔵 ContentView implements three-panel layout: collapsible sidebar, chat panel, optional media panel
941 " 🔵 BriefListView organizes briefs by time group with live countdown, search, and selection state
942 " 🔵 ReplyDraftView allows editing generated reply drafts before sending with service/conversation context
943 6:27a 🔴 Fix Signal account migration to only remove UserDefaults source after confirmed keychain write
944 " 🔴 Fix BriefEngine to only attach messages from services with successful LLM parsing
945 " ✅ Improve summarizeLast() resilience: prevent concurrent calls and skip failed adapters gracefully
946 " 🔴 Fix PollEngine duplicate detection to use db.changesCount instead of relying on record.id
947 6:28a 🔴 BriefRepository.storeMessages() now returns both new and existing unattached messages
948 " ✅ SubprocessAdapter clears read buffer on process restart and stop to prevent stale data
949 " 🔄 SubprocessAdapter.roundTrip refactored to reuse persistent buffer and handle multiple queued responses
950 " ✅ Simplify window title to show brief creation time instead of one-hour time range
951 " ✅ Simplify brief time display throughout BriefListView to show creation time only
952 " 🔴 ChatPanelView.headerStats now strips code fences from openingSummary before JSON parsing
953 6:29a 🔴 Fix headerStats scoping: move JSON decoding inside openingSummary conditional block
954 " 🔄 Removed unused poll interval UI from InstructionsSettingsTab
955 " 🔴 Prevent unsafe replies to ambiguous conversations in multi-conversation briefs
956 " 🟣 Added visual feedback for reply draft recipients and multi-conversation warnings
957 " 🔵 Build verification: All recent changes compile successfully
S128 Fix all identified bugs and prepare comprehensive changeset for review and merge (May 6 at 6:33 AM)
958 6:34a 🔵 Comprehensive bug fix changeset spans 38 files across entire application stack
S129 Codex adversarial review of 38-file changeset identifies three high-severity issues requiring fixes before merge (May 6 at 6:34 AM)
959 6:37a 🔵 Codex adversarial review identifies three high-severity regressions in changeset
S130 Address Codex adversarial review findings: apply summarizeLast partial-parse fix and verify build (May 6 at 6:37 AM)
960 6:39a 🔵 Confirmed: summarizeLast silently loses messages from failed-parse services
961 " 🔴 Fixed summarizeLast to only attach messages from successfully-parsed services
962 " 🔴 Updated attachment block to use messagesToAttach variable
S131 Assess the keychain risk in LLMessenger and implement mitigations (May 6 at 6:39 AM)
963 6:48a 🔵 Keychain implementation uses standard Security framework wrapper
964 " ✅ Keychain storage hardened with explicit accessibility constraints
965 6:49a ✅ Keychain implementation refactored for backward compatibility and legacy item migration
966 " ✅ Keychain changes verified to compile and build successfully
S216 Plan evaluation: User asked for a 1-100 rating of a phased implementation plan for a feature involving send paths, cloud provider trust, data model, UI, and testing (May 6 at 6:50 AM)
S217 Plan evaluation and upgrade: User asked for a 1-100 rating of LLMessenger implementation plan; Claude provided 90/100 feedback and user subsequently expanded the plan into a fully sprint-ready roadmap with executable tickets. (May 6 at 6:23 PM)
1355 6:24p 🔵 LLMessenger Implementation Roadmap: 8-Phase Plan with Dependency Order and Risk Mitigations
1356 6:26p ✅ LLMessenger PRD Section 23 Expanded to Sprint-Ready Roadmap with Tickets, Gates, and Risk Register
S218 Verify Phase 1 completion: check full test suite results from xcodebuild invocation and confirm zero test failures (May 6 at 6:26 PM)
1357 6:27p 🟣 Added Explicit LLM Provider Selection and Consent Tracking to Settings Repository
S219 Type-safety refactoring for LLMessenger Brief system: converting unsafe JSON (`[[String: Any]]`) to strongly-typed Codable structures with comprehensive source-citation validation, message ID tracking, database persistence, and enhanced UI feedback (May 6 at 6:28 PM)
1358 6:53p 🔄 Extract brief card JSON structures into dedicated BriefJSON.swift
1359 7:05p 🔵 BriefEngineTests test failures discovered during batch test run
1360 7:07p ✅ BriefEngineTests fixture modified to fix test data setup
1361 " 🔵 Test fix attempt unsuccessful; testProcessNewMessagesIncludesRollingSummaryAndRecentContext still failing
1362 " 🔵 Test assertion requirements identified: rolling summary and recent context must appear in LLM prompt
1363 " 🔴 Test corrected to inspect last LLM call instead of first
1364 " 🔵 Test fixture change introduced new failure in testProcessNewMessagesPersistsConversationState
S220 Debug and fix failing BriefEngineTests, specifically testProcessNewMessagesIncludesRollingSummaryAndRecentContext which expected rolling summary and recent context strings in the LLM prompt but found them missing (May 6 at 7:08 PM)
**Investigated**: Test execution and failure output showing XCTAssertTrue failures at lines 211-212; mock LLM client call tracking; message sorting behavior in persistConversationStates(); conversation state fetching and recent context message retrieval logic

**Learned**: The test was examining the wrong LLM call (first instead of last) which prevented it from seeing the correct prompt with rolling summary and context. Non-deterministic message sorting when timestamps are equal causes flaky test behavior because the "latest" message selection becomes ambiguous. The buildConversationBlock() method properly constructs prompts with previous summaries, recent context, and new messages, but the test needed to inspect the correct call in the mock's call history

**Completed**: Applied three patches: (1) Changed mock.calls.first to mock.calls.last in BriefEngineTests line 210 to inspect the correct LLM call; (2) Added messageSortAscending() helper function to BriefEngine.swift for deterministic message sorting by timestamp, messageId, and row ID; (3) Removed unused callIndex variable. Full test suite now passes: BriefEngineTests 10/10 passing, BriefRepositoryTests 13/13 passing, complete run 94/94 tests passing with 0 failures

**Next Steps**: Session work is complete. All tests passing. Minor follow-up available: SubprocessAdapterTests still emits Thread Performance Checker QoS inversion warnings which could be addressed in future work to improve performance alignment with PRD requirements


Access 681k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>