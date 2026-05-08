# Backend E2E Workflow Tests — Implementation Plan

**Goal:** Prove every backend workflow — from adapter fetch through DB storage through brief generation through AppState refresh — is correct end-to-end with no seam unverified.

**Architecture context:** The production flow is:
```
Timer fires
  → PollEngine.pollNow(serviceID)
    → adapter.fetch() → store() to messages table
    → onPollSucceeded() callback fires (if new messages)
      → BriefEngine.processNewMessages()
        → MemoryCompressor.compress() (previous brief, non-fatal)
        → LLM call per service
        → insertBrief() + attach(messages) + upsertConversationState()
          → AppState.refreshBriefs()
            → SwiftUI sees new brief
```

The `onPollSucceeded → processNewMessages` seam in AppDelegate is the **most critical untested path** in the codebase. None of the existing tests wire PollEngine to BriefEngine and fire the whole chain.

---

## File

**Create:** `LLMessengerTests/BackendWorkflowE2ETests.swift`  
**Register in:** `LLMessenger.xcodeproj/project.pbxproj` (4 sections: PBXBuildFile, PBXFileReference, PBXGroup, PBXSourcesBuildPhase)

---

## Shared Test Infrastructure

```swift
// Helpers used by all test groups
private func makeDB() throws -> AppDatabase
private func makeAppState(db:) -> AppState
private func makeEngine(db:) -> PollEngine
private func makeBriefEngine(db: mock:) -> BriefEngine

// Wires PollEngine.onPollSucceeded → BriefEngine.processNewMessages
// Returns the PollEngine so tests can call pollAll()
private func makeWiredPipeline(db: mock:) -> (PollEngine, BriefEngine, AppState)

// FakeMessengerAdapter (already in codebase)
// DynamicMockLLMClient (already in codebase)
// MockLLMClient (already in codebase)
```

---

## Group 1: The Primary Pipeline Seam
**The `onPollSucceeded → processNewMessages` chain is the most critical gap.**

### Test 1.1 — `testPollTriggersFullBriefPipelineViaCallback`
```
FakeAdapter returns 1 message
PollEngine.onPollSucceeded = { await briefEngine.processNewMessages() }
→ await engine.pollAll()
→ DB: messages table has 1 row with briefId set
→ DB: briefs table has 1 row, status = "ready"
→ AppState.refreshBriefs() → appState.briefs.count == 1
```
**Why:** The entire `onPollSucceeded → processNewMessages` wiring in AppDelegate is untested. This is the primary production trigger for brief generation.

### Test 1.2 — `testNoBriefGeneratedWhenPolledButNoNewMessages`
```
FakeAdapter returns empty conversations
PollEngine.onPollSucceeded = { await briefEngine.processNewMessages() }  // should NOT fire
→ await engine.pollAll()
→ DB: messages table empty
→ DB: briefs table empty
→ appState.refreshBriefs() → appState.briefs.isEmpty
```
**Why:** `onPollSucceeded` only fires when `insertedCount > 0`. If it fired for empty results, we'd generate empty briefs.

### Test 1.3 — `testSecondPollWithNoNewMessagesDoeNotCreateSecondBrief`
```
Cycle 1: FakeAdapter returns message m1 → brief B1 created
Cycle 2: FakeAdapter returns same m1 (dedup by messageId) → no new insertions
→ DB: briefs.count == 1 (no second brief)
→ messages: m1.briefId == B1.id (unchanged)
```
**Why:** Dedup at the poll layer must prevent spurious brief generation. The `onConflict: .ignore` + `changesCount > 0` check must work correctly across cycles.

### Test 1.4 — `testMessagesFromFailedBriefCycleRetryInNextCycle`
```
Cycle 1: FakeAdapter returns m1 → poll stores it → LLM fails → brief NOT created → m1.briefId = nil
Cycle 2: FakeAdapter returns m2 (new) → poll stores m2 → LLM succeeds → brief covers BOTH m1 and m2
→ DB: 1 brief, 2 messages attached (m1 + m2), briefs.failedServices = nil
```
**Why:** `fetchUnattachedMessages` fetches WHERE briefId IS NULL. Messages from a failed brief cycle must survive as unattached and be included in the next successful cycle.

### Test 1.5 — `testMultiServicePipelineProducesSingleBriefWithBothServices`
```
SignalAdapter returns s1; TelegramAdapter returns t1
PollEngine registers both; both polled in pollAll()
→ onPollSucceeded fires once (or twice — both trigger)
→ BriefEngine.processNewMessages() runs once
→ DB: 1 brief with services = ["signal", "telegram"]
→ DB: s1.briefId == t1.briefId (same brief)
```
**Why:** The brief pipeline groups all unattached messages regardless of service. Two separate services must produce ONE brief, not two.

### Test 1.6 — `testPartialAdapterFailureProducesBriefForSuccessfulServiceOnly`
```
SignalAdapter.fetch() throws; TelegramAdapter returns t1
→ pollAll()
→ signal ServiceHealth: status = "error"
→ telegram messages stored
→ processNewMessages() → brief with services = ["telegram"], failedServices = nil
   (signal had no messages to brief because poll failed)
→ AppState.refreshBriefs() → brief visible
```
**Why:** Adapter failure stops message storage for that service. The remaining service's messages must still produce a brief.

---

## Group 2: Memory Compression in the Pipeline

### Test 2.1 — `testSecondBriefCycleCompressesPreviousBriefFirst`
```
Cycle 1: processNewMessages() → brief B1 (episodicSummary = nil)
Cycle 2 (new messages available): processNewMessages() 
→ MemoryCompressor.compress(B1) runs first
→ B1.episodicSummary set to LLM response
→ new brief B2 created
→ DB: B1.episodicSummary != nil; B2 exists
```
**Why:** `fetchOldestUncompressedBrief()` is called at the start of every processNewMessages call. Compression must fire before new brief creation, in order.

### Test 2.2 — `testCompressionDoesNotRepeatForAlreadyCompressedBrief`
```
Cycle 1: processNewMessages() → B1 created
Cycle 2: processNewMessages() → B1 compressed (episodicSummary written)
Cycle 3 (new messages): processNewMessages() → B2 created
→ LLM called exactly once for compression across cycles 2+3
→ B1.episodicSummary unchanged after cycle 3
```
**Why:** `MemoryCompressor` skips briefs where `episodicSummary != nil`. Must be idempotent across multiple pipeline runs.

### Test 2.3 — `testEpisodicSummaryAppearsInNextBriefPrompt`
```
Cycle 1: processNewMessages() → B1 with episodicSummary compressed to "Alice owes you money"
Cycle 2: processNewMessages() uses CapturingMockLLMClient
→ inspect captured LLM prompt: must contain "Alice owes you money" in episodicSummaries section
```
**Why:** `PromptBuilder.build(mode: .summarizer, episodicSummaries: recent)` injects prior summaries. If the chain is broken, the LLM loses long-term memory.

---

## Group 3: ConversationState Carry-Forward

### Test 3.1 — `testFullPipelineCycleWritesConversationState`
```
processNewMessages() → brief B1 covering conversation "alice-conv"
→ DB: conversationState row for (service="signal", conversationId="alice-conv") exists
→ state.lastSeenMessageId == last message ID in brief
→ state.rollingSummary != nil
```
**Why:** ConversationState is the memory mechanism between brief cycles. If it's not written, the LLM loses context on every cycle.

### Test 3.2 — `testConversationStateAdvancesAcrossTwoCycles`
```
Cycle 1: message m1 → brief B1 → state: lastSeenMessageId = "m1"
Cycle 2: message m2 → brief B2 → state: lastSeenMessageId = "m2"
→ DB: exactly ONE ConversationState row (UPSERTed, not duplicated)
→ state.lastSeenMessageId == "m2"
```
**Why:** ConversationState must be UPSERTed, not inserted. Two rows for the same (service, conversationId) would corrupt the carry-forward.

### Test 3.3 — `testConversationStateSummaryInjectedIntoSecondCyclePrompt`
```
Uses CapturingMockLLMClient for cycle 2
Cycle 1 writes state.rollingSummary = "<summary>"
Cycle 2: captured LLM call's userContent must contain "<summary>" or "Previous summary:"
```
**Why:** This is the end-to-end proof that BriefEngine actually reads ConversationState and injects it into the prompt. The full memory pipeline.

---

## Group 4: ServiceHealth and Catch-Up

### Test 4.1 — `testPollUpdatesServiceHealthToOkOnSuccess`
```
FakeAdapter returns message m1
→ pollAll()
→ DB: serviceHealth row for "signal": status = "ok", lastCheck ≈ now, lastError = nil
```
**Why:** `ServiceHealth.lastCheck` is used as the `since` timestamp for the next fetch. If health isn't written, the fetch window resets to nil (fetches everything every time).

### Test 4.2 — `testPollUpdatesServiceHealthToErrorOnFailure`
```
FakeAdapter.fetch() throws URLError
→ pollAll()
→ DB: serviceHealth.status = "error", serviceHealth.lastError != nil
→ DB: messages table empty
```
**Why:** Error state must persist so UI can show "last poll failed" and the next poll doesn't use a stale `since` window.

### Test 4.3 — `testSecondPollUsesLastCheckAsTheFetchWindowStart`
```
Cycle 1: FakeAdapter returns m1, written to DB, lastCheck = T1
Cycle 2: FakeAdapter captures the FetchConfig.since it receives
→ FetchConfig.since == T1 (the stored lastCheck from cycle 1)
```
**Why:** Without this, the adapter fetches ALL messages on every poll (no time-windowed fetching). The `since` parameter from `ServiceHealth.lastCheck` must flow correctly from DB → FetchConfig → adapter.

### Test 4.4 — `testCheckCatchUpTriggersImmediatePollForUninitializedService`
```
PollEngine registered with "signal" config; no ServiceHealth row in DB
→ engine.start() → checkCatchUp("signal") runs
→ FakeAdapter.fetch() called immediately (without waiting for timer)
→ DB: serviceHealth row created for "signal"
```
**Why:** On first launch (or after data reset), there's no `lastCheck`. `checkCatchUp` detects this and polls immediately instead of waiting for the first timer fire. This is the "fresh install" path.

### Test 4.5 — `testCheckCatchUpSkipsServicePolledRecently`
```
ServiceHealth row exists for "signal" with lastCheck = now - 5 minutes, interval = 30 min
→ engine.start() → checkCatchUp("signal") 
→ FakeAdapter.fetch() NOT called
```
**Why:** Catch-up must not poll unnecessarily. Only fires when `now - lastCheck > interval`.

---

## Group 5: Pipeline Invariants (Mathematical Properties)

### Test 5.1 — `testAfterSuccessfulCycleAllMessagesHaveBriefId`
```
N messages across M conversations from K services
→ processNewMessages() succeeds
→ every message row: briefId IS NOT NULL
→ fetchUnattachedMessages() returns []
```
**Why:** After a successful brief cycle, no message should remain unattached. Unattached messages are retried; stale ones bloat future briefs.

### Test 5.2 — `testAfterFailedCycleAllMessagesRemainUnattached`
```
Messages inserted; LLM returns error for all services
→ processNewMessages() returns nil
→ every message row: briefId IS NULL
→ fetchUnattachedMessages() returns same messages as before
```
**Why:** Atomicity of the attach step. A failed brief must not partially attach messages (leaving some attached to a non-existent brief).

### Test 5.3 — `testBriefCountNeverExceedsNumberOfSuccessfulCycles`
```
Run N poll+brief cycles, each with distinct new messages
→ DB: briefs.count == N
→ No duplicate briefs for the same poll cycle
```
**Why:** `briefingInFlight` guard ensures one brief per cycle. Two concurrent calls to `processNewMessages` must produce exactly one brief.

### Test 5.4 — `testConcurrentBriefGenerationProducesExactlyOneBrief`
```
Two simultaneous calls to briefEngine.processNewMessages() via Task.detached
→ DB: briefs.count == 1 (in-flight guard fires)
→ DB: all messages have briefId set (the one brief covers them all)
```
**Why:** `briefingInFlight` is a Bool guard. If it fails under concurrent Task execution, two briefs are created from the same messages.

### Test 5.5 — `testServiceHealthLastCheckAdvancesMonotonicallyAcrossCycles`
```
Cycle 1: pollAll() → lastCheck = T1
Cycle 2 (after 1s): pollAll() → lastCheck = T2
→ T2 > T1 (strictly)
```
**Why:** `lastCheck` is used as the `since` window. If it regresses or stays the same, messages are re-fetched from the past on every poll.

---

## Group 6: DB-Level Error Boundaries

### Test 6.1 — `testBriefEngineIsAtomicOnPartialInsertFailure`
Inject a DB that throws on `insertBrief()` after messages have been fetched.
```
→ processNewMessages() returns nil / throws
→ DB: briefs.count == 0
→ DB: all messages: briefId IS NULL (no partial attachment)
```
**Why:** SQLite writes within a `dbQueue.write` block are transactional. If `insertBrief` throws, `attach(messages)` must not have fired. Verifies GRDB transaction semantics.

### Test 6.2 — `testPollEngineStoreFailureDoesNotUpdateHealth`
**Note:** Currently a known gap — health is NOT updated when `store()` fails. This test should FAIL initially, documenting the known bug, then can be fixed.
```
FakeAdapter succeeds; FakeDB.write() throws on message insert
→ pollAll() propagates error
→ DB: serviceHealth NOT updated (no "ok" written)
→ DB: no messages stored
```

---

## Group 7: AppState Observation Contract

### Test 7.1 — `testAppStateBriefsPopulatesAfterFullPipelineCycle`
```
Full pipeline runs: poll → brief generated
→ appState.refreshBriefs()
→ appState.briefs.count == 1
→ appState.unreadCount == 1
→ appState.selectedBriefID = briefs[0].id! → appState.selectedBrief != nil
```
**Why:** Verifies the AppState read path after a real pipeline run (not a test-only DB insert).

### Test 7.2 — `testUnreadCountDecrementsAfterMarkAsOpen`
```
Full pipeline → brief B1 (status = "ready") → appState.refreshBriefs() → unreadCount == 1
→ appState.markAsOpen(briefID: B1.id!)
→ unreadCount == 0
→ appState.briefs[0].briefStatus == .open
```
**Why:** The unread badge in the menu bar depends on this. Verify the full cycle from brief generation through status change through count update.

---

## Test Count Summary

| Group | Tests | Focus |
|-------|-------|-------|
| 1. Primary pipeline seam | 6 | onPollSucceeded → processNewMessages wiring |
| 2. Memory compression | 3 | MemoryCompressor in the pipeline |
| 3. ConversationState | 3 | State carry-forward across cycles |
| 4. ServiceHealth + catch-up | 5 | Health writes, since window, catch-up |
| 5. Pipeline invariants | 5 | Mathematical properties of the pipeline |
| 6. DB error boundaries | 2 | Atomicity, partial failure |
| 7. AppState observation | 2 | UI contract after real pipeline run |
| **Total** | **26** | |

---

## Implementation Notes

**Test helpers needed:**

```swift
// Wire PollEngine.onPollSucceeded → BriefEngine, return both
func makeWiredPipeline(db: AppDatabase, mock: LLMClient) 
    -> (engine: PollEngine, brief: BriefEngine, appState: AppState)

// FakeMessengerAdapter with capture of received FetchConfig
// Extend existing FakeMessengerAdapter to expose receivedFetchConfigs: [FetchConfig]
// (to test Group 4 — verifying since date flows correctly)

// CapturingMockLLMClient already exists in PromptRegressionTests.swift
// DynamicMockLLMClient already exists in PipelineScenarioTests.swift
// MockLLMClient already exists in MemoryCompressorTests.swift
```

**Multi-cycle test pattern:**
```swift
// Cycle 1: distinct message timestamps so cycle 2 doesn't re-fetch them
try await insertMessage(..., timeOffset: -120)  // old enough to be in first cycle window
// Run cycle 1
try await insertMessage(..., timeOffset: 0)    // new, will be in second cycle
// Run cycle 2
```

**Capturing LLM prompts:**  
Use `CapturingMockLLMClient` from `PromptRegressionTests.swift` to assert on prompt content (Group 2.3, Group 3.3). Filter out MemoryCompressor calls using `.first(where: { !$0.systemPrompt.contains("2-3 sentences") })`.

---

## Execution Order

Write tests in this order — each group builds on the previous:
1. Group 1 first (primary pipeline seam) — foundational
2. Group 4 (ServiceHealth) — needed before Group 5
3. Group 2 (Memory compression) — needs multi-cycle pattern from Group 1
4. Group 3 (ConversationState) — needs multi-cycle pattern
5. Group 5 (invariants) — needs all prior groups working
6. Group 6 (error boundaries) — last, most complex
7. Group 7 (AppState observation) — wrap-up, verifies the whole stack
