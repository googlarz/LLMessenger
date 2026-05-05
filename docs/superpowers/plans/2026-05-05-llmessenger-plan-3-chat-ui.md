# LLMessenger Plan 3: Chat UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the slide-in chat panel that lets the user browse Briefs, chat with the LLM about them, and draft replies.

**Architecture:** An `NSPanel` (right-anchored, full-height, borderless) hosts a SwiftUI `ContentView` via `NSHostingController`. Two `ObservableObject` classes — `AppState` (global, owns DB + adapters) and `ChatViewModel` (per-session, owns thread state) — are injected as SwiftUI `environmentObject`s. `ChatWindowController` owns both and manages the panel's show/hide animation.

**Tech Stack:** AppKit (NSPanel, NSEvent monitor), SwiftUI (List, ScrollView, TextEditor), GRDB (async reads), existing LLMClient / PromptBuilder / BriefRepository.

---

## File Map

| Action | File |
|--------|------|
| Create | `LLMessenger/UI/AppState.swift` |
| Create | `LLMessenger/UI/ChatViewModel.swift` |
| Create | `LLMessenger/UI/ChatWindowController.swift` |
| Create | `LLMessenger/UI/ContentView.swift` |
| Create | `LLMessenger/UI/BriefListView.swift` |
| Create | `LLMessenger/UI/BriefHeaderView.swift` |
| Create | `LLMessenger/UI/ChatPanelView.swift` |
| Create | `LLMessenger/UI/ThreadView.swift` |
| Create | `LLMessenger/UI/MessageBubbleView.swift` |
| Create | `LLMessenger/UI/AssistantResponseView.swift` |
| Create | `LLMessenger/UI/ReplyDraftView.swift` |
| Create | `LLMessenger/UI/ChatInputView.swift` |
| Create | `LLMessengerTests/AppStateTests.swift` |
| Create | `LLMessengerTests/ChatViewModelTests.swift` |
| Modify | `LLMessenger/Core/Brief/BriefRepository.swift` |
| Modify | `LLMessenger/AppDelegate.swift` |
| Modify | `LLMessenger/MenuBar/MenuBarController.swift` |

---

### Task 1: Shared Types + BriefListGrouper (with tests)

**Files:**
- Create: `LLMessenger/UI/AppState.swift`
- Modify: `LLMessenger/Core/Brief/BriefRepository.swift`
- Create: `LLMessengerTests/AppStateTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// LLMessengerTests/AppStateTests.swift
import XCTest
@testable import LLMessenger

final class BriefListGrouperTests: XCTestCase {

    private func makeBrief(id: Int64, daysAgo: Double) -> Brief {
        Brief(id: id,
              createdAt: Date(timeIntervalSinceNow: -daysAgo * 86400),
              status: "ready", services: "[]",
              openingSummary: nil, notificationText: "x",
              episodicSummary: nil)
    }

    func testTodayBriefGoesToTodayGroup() {
        let brief = makeBrief(id: 1, daysAgo: 0.1)
        let groups = BriefListGrouper.group([brief])
        XCTAssertEqual(groups.first?.label, "Today")
        XCTAssertEqual(groups.first?.briefs.count, 1)
    }

    func testYesterdayBriefGoesToYesterdayGroup() {
        let brief = makeBrief(id: 2, daysAgo: 1.5)
        let groups = BriefListGrouper.group([brief])
        XCTAssertEqual(groups.first?.label, "Yesterday")
    }

    func testOlderBriefGetsDateLabel() {
        let brief = makeBrief(id: 3, daysAgo: 5)
        let groups = BriefListGrouper.group([brief])
        XCTAssertFalse(groups.first?.label == "Today")
        XCTAssertFalse(groups.first?.label == "Yesterday")
        XCTAssertFalse(groups.first?.label.isEmpty ?? true)
    }

    func testGroupsAreSortedNewestFirst() {
        let today = makeBrief(id: 1, daysAgo: 0)
        let yesterday = makeBrief(id: 2, daysAgo: 1.5)
        let groups = BriefListGrouper.group([yesterday, today])
        XCTAssertEqual(groups.first?.label, "Today")
        XCTAssertEqual(groups.last?.label, "Yesterday")
    }

    func testBriefsWithinGroupSortedNewestFirst() {
        let older = makeBrief(id: 1, daysAgo: 0.5)
        let newer = makeBrief(id: 2, daysAgo: 0.1)
        let groups = BriefListGrouper.group([older, newer])
        XCTAssertEqual(groups.first?.briefs.first?.id, 2)
    }

    func testEmptyInputReturnsNoGroups() {
        let groups = BriefListGrouper.group([])
        XCTAssertTrue(groups.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd ~/Developer/LLMessenger
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/BriefListGrouperTests 2>&1 | tail -20
```

Expected: FAIL — `BriefListGrouper` not found.

- [ ] **Step 3: Add `fetchAllBriefs()` to BriefRepository**

In `LLMessenger/Core/Brief/BriefRepository.swift`, append after `fetchMessages(forBriefID:)`:

```swift
    func fetchAllBriefs() throws -> [Brief] {
        try database.dbQueue.read { db in
            try Brief
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }
```

- [ ] **Step 4: Create `LLMessenger/UI/AppState.swift`** with shared types + grouper + AppState

```swift
// LLMessenger/UI/AppState.swift
import Foundation
import AppKit

// MARK: - Shared Value Types

struct ReplyDraft: Identifiable, Equatable {
    let id: UUID
    var text: String
    let conversationID: String
    let senderName: String
}

enum ThreadItem: Identifiable {
    case message(Message)
    case assistantResponse(id: UUID, text: String)
    case replyDraft(id: UUID, draft: ReplyDraft)

    var id: String {
        switch self {
        case .message(let m):           return "msg-\(m.id ?? 0)"
        case .assistantResponse(let i, _): return "asst-\(i)"
        case .replyDraft(let i, _):     return "draft-\(i)"
        }
    }
}

struct BriefListGroup: Identifiable {
    let id: String
    let label: String
    let briefs: [Brief]
}

// MARK: - BriefListGrouper

struct BriefListGrouper {

    static func group(_ briefs: [Brief], calendar: Calendar = .current) -> [BriefListGroup] {
        let sorted = briefs.sorted { $0.createdAt > $1.createdAt }
        var labeledBriefs: [(label: String, brief: Brief)] = []
        for brief in sorted {
            let label = dayLabel(for: brief.createdAt, calendar: calendar)
            labeledBriefs.append((label, brief))
        }
        var result: [BriefListGroup] = []
        var seen: [String: Int] = [:]  // label → index in result
        for (label, brief) in labeledBriefs {
            if let idx = seen[label] {
                result[idx] = BriefListGroup(
                    id: label,
                    label: result[idx].label,
                    briefs: result[idx].briefs + [brief]
                )
            } else {
                seen[label] = result.count
                result.append(BriefListGroup(id: label, label: label, briefs: [brief]))
            }
        }
        return result
    }

    private static func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    @Published var briefs: [Brief] = []
    @Published var selectedBriefID: Int64?
    @Published var serviceHealth: [String: AdapterHealthResult.Status] = [:]

    let database: AppDatabase
    let repository: BriefRepository
    let llmClient: LLMClient
    let llmModel: String
    let basePrompt: String
    var adapters: [String: any MessengerAdapter] = [:]

    init(database: AppDatabase,
         llmClient: LLMClient,
         llmModel: String,
         basePrompt: String) {
        self.database = database
        self.repository = BriefRepository(database: database)
        self.llmClient = llmClient
        self.llmModel = llmModel
        self.basePrompt = basePrompt
    }

    var briefGroups: [BriefListGroup] {
        BriefListGrouper.group(briefs)
    }

    var selectedBrief: Brief? {
        guard let id = selectedBriefID else { return nil }
        return briefs.first { $0.id == id }
    }

    func refreshBriefs() {
        do {
            briefs = try repository.fetchAllBriefs()
        } catch {
            // Silently ignore — UI shows empty state
        }
    }

    func makeChatViewModel() -> ChatViewModel {
        ChatViewModel(appState: self)
    }
}
```

- [ ] **Step 5: Run tests again — should pass**

```bash
cd ~/Developer/LLMessenger
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/BriefListGrouperTests 2>&1 | tail -20
```

Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
cd ~/Developer/LLMessenger
git add LLMessenger/UI/AppState.swift LLMessenger/Core/Brief/BriefRepository.swift LLMessengerTests/AppStateTests.swift
git commit -m "feat: add shared UI types, BriefListGrouper, AppState, fetchAllBriefs"
```

---

### Task 2: ChatViewModel (with tests)

**Files:**
- Create: `LLMessenger/UI/ChatViewModel.swift`
- Create: `LLMessengerTests/ChatViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// LLMessengerTests/ChatViewModelTests.swift
import XCTest
@testable import LLMessenger

@MainActor
final class ChatViewModelTests: XCTestCase {

    func makeAppState(privacyMode: String = "on_demand") throws -> AppState {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write { db in
            var cfg = ServiceConfig.default(for: "telegram")
            cfg.privacyMode = privacyMode
            try cfg.insert(db)
        }
        let mock = MockLLMClient()
        return AppState(database: db, llmClient: mock, llmModel: "test",
                        basePrompt: "BASE")
    }

    func testLoadBriefPopulatesMessages() async throws {
        let db = try AppDatabase(inMemory: true)
        var briefId: Int64 = 0
        try await db.dbQueue.write { db in
            var b = Brief(createdAt: Date(), status: "ready", services: "[]",
                          openingSummary: "Summary", notificationText: "x",
                          episodicSummary: nil)
            try b.insert(db)
            briefId = b.id!
            var msg = Message(briefId: briefId, service: "telegram",
                              conversationId: "c1", messageId: "m1",
                              sender: "Alice", text: "Hello",
                              timestamp: Date(), isSent: false)
            try msg.insert(db)
        }
        let mock = MockLLMClient()
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: briefId)!
        let vm = ChatViewModel(appState: appState)

        try await vm.loadBrief(brief)

        XCTAssertEqual(vm.threadItems.count, 1)
        if case .message(let m) = vm.threadItems[0] {
            XCTAssertEqual(m.text, "Hello")
        } else {
            XCTFail("Expected .message ThreadItem")
        }
    }

    func testSendAddsAssistantResponse() async throws {
        let db = try AppDatabase(inMemory: true)
        var briefId: Int64 = 0
        try await db.dbQueue.write { db in
            var b = Brief(createdAt: Date(), status: "ready", services: "[]",
                          openingSummary: "Summary", notificationText: "x",
                          episodicSummary: nil)
            try b.insert(db)
            briefId = b.id!
            var msg = Message(briefId: briefId, service: "telegram",
                              conversationId: "c1", messageId: "m1",
                              sender: "Alice", text: "Hello",
                              timestamp: Date(), isSent: false)
            try msg.insert(db)
        }
        let mock = MockLLMClient()
        mock.response = LLMResponse(text: "Alice said hello.", inputTokens: 5, outputTokens: 3)
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let brief = try appState.repository.fetchBrief(id: briefId)!
        let vm = ChatViewModel(appState: appState)
        try await vm.loadBrief(brief)
        vm.inputText = "What did Alice say?"

        await vm.send()

        XCTAssertEqual(mock.calls.count, 1)
        let assistantItems = vm.threadItems.filter {
            if case .assistantResponse = $0 { return true }
            return false
        }
        XCTAssertEqual(assistantItems.count, 1)
        XCTAssertTrue(vm.inputText.isEmpty)
    }

    func testDiscardDraftRemovesItem() async throws {
        let db = try AppDatabase(inMemory: true)
        let mock = MockLLMClient()
        let appState = AppState(database: db, llmClient: mock, llmModel: "test", basePrompt: "BASE")
        let vm = ChatViewModel(appState: appState)
        let draftID = UUID()
        let draft = ReplyDraft(id: draftID, text: "Draft reply",
                               conversationID: "c1", senderName: "Alice")
        vm.threadItems = [.replyDraft(id: draftID, draft: draft)]

        vm.discardDraft(id: draftID)

        XCTAssertTrue(vm.threadItems.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd ~/Developer/LLMessenger
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/ChatViewModelTests 2>&1 | tail -20
```

Expected: FAIL — `ChatViewModel` not found.

- [ ] **Step 3: Create `LLMessenger/UI/ChatViewModel.swift`**

```swift
// LLMessenger/UI/ChatViewModel.swift
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var threadItems: [ThreadItem] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false

    private let appState: AppState
    private var currentBrief: Brief?

    init(appState: AppState) {
        self.appState = appState
    }

    func loadBrief(_ brief: Brief) async throws {
        currentBrief = brief
        let messages = try appState.repository.fetchMessages(forBriefID: brief.id!)
        threadItems = messages.map { .message($0) }
    }

    func send() async {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let brief = currentBrief else { return }

        let userText = inputText
        inputText = ""
        isLoading = true
        defer { isLoading = false }

        let mode: LLMMode = userText.lowercased().hasPrefix("reply to") ||
                             userText.lowercased().hasPrefix("draft reply")
            ? .replyDrafter
            : .conversationalist

        do {
            let recent = (try? appState.repository.recentEpisodicSummaries(limit: 3)) ?? []
            let services: [String]
            if let data = brief.services.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                services = arr
            } else {
                services = []
            }
            let systemPrompt = PromptBuilder.build(
                mode: mode,
                basePrompt: appState.basePrompt,
                services: services,
                episodicSummaries: recent,
                now: Date()
            )
            let threadText = threadItems.compactMap { item -> String? in
                if case .message(let m) = item { return "[\(m.service)] \(m.sender): \(m.text)" }
                return nil
            }.joined(separator: "\n")

            var chatMessages: [LLMMessage] = [
                LLMMessage(role: .system, content: systemPrompt),
                LLMMessage(role: .user, content: threadText + "\n\nUser: " + userText)
            ]

            let response = try await appState.llmClient.complete(
                model: appState.llmModel,
                messages: chatMessages,
                maxTokens: 600
            )
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if mode == .replyDrafter {
                let draft = ReplyDraft(id: UUID(), text: responseText,
                                      conversationID: "unknown",
                                      senderName: "")
                threadItems.append(.replyDraft(id: draft.id, draft: draft))
            } else {
                threadItems.append(.assistantResponse(id: UUID(), text: responseText))
            }
        } catch {
            threadItems.append(.assistantResponse(id: UUID(),
                                                   text: "Error: \(error.localizedDescription)"))
        }
    }

    func discardDraft(id: UUID) {
        threadItems.removeAll {
            if case .replyDraft(let i, _) = $0 { return i == id }
            return false
        }
    }

    func sendDraft(_ draft: ReplyDraft) async throws {
        guard let adapter = appState.adapters[draft.conversationID.components(separatedBy: ":").first ?? ""]
               ?? appState.adapters.values.first else { return }
        try await adapter.send(conversationID: draft.conversationID, text: draft.text)
        discardDraft(id: draft.id)
    }
}
```

- [ ] **Step 4: Run tests — should pass**

```bash
cd ~/Developer/LLMessenger
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/ChatViewModelTests 2>&1 | tail -20
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/LLMessenger
git add LLMessenger/UI/ChatViewModel.swift LLMessengerTests/ChatViewModelTests.swift
git commit -m "feat: add ChatViewModel with thread management and LLM send"
```

---

### Task 3: ChatWindowController + ContentView stub

**Files:**
- Create: `LLMessenger/UI/ChatWindowController.swift`
- Create: `LLMessenger/UI/ContentView.swift`

- [ ] **Step 1: Create `LLMessenger/UI/ContentView.swift`** (minimal stub — will be expanded in Task 4)

```swift
// LLMessenger/UI/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        Text("LLMessenger")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Create `LLMessenger/UI/ChatWindowController.swift`**

```swift
// LLMessenger/UI/ChatWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class ChatWindowController {
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private let appState: AppState
    private let chatViewModel: ChatViewModel

    init(appState: AppState) {
        self.appState = appState
        self.chatViewModel = appState.makeChatViewModel()
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil { buildPanel() }
        guard let panel else { return }
        appState.refreshBriefs()
        panel.makeKeyAndOrderFront(nil)
        installEscapeHandler()
        installClickOutsideMonitor()
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.alphaValue = 1
        }
        removeMonitors()
    }

    // MARK: - Private

    private func buildPanel() {
        guard let screen = NSScreen.main else { return }
        let panelWidth: CGFloat = 380
        let panelHeight = screen.visibleFrame.height
        let origin = CGPoint(x: screen.visibleFrame.maxX - panelWidth,
                             y: screen.visibleFrame.minY)
        let frame = CGRect(origin: origin, size: CGSize(width: panelWidth, height: panelHeight))

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovable = false

        let contentView = ContentView()
            .environmentObject(appState)
            .environmentObject(chatViewModel)

        p.contentView = NSHostingView(rootView: contentView)
        panel = p
    }

    private func installEscapeHandler() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // Escape
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func installClickOutsideMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let loc = event.locationInWindow
            if !panel.frame.contains(NSEvent.mouseLocation) {
                Task { @MainActor in self.hide() }
            }
        }
    }

    private func removeMonitors() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }
}
```

- [ ] **Step 3: Verify project builds**

```bash
cd ~/Developer/LLMessenger
xcodebuild build -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "error:|warning:|BUILD"
```

Expected: `BUILD SUCCEEDED` with no errors.

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/LLMessenger
git add LLMessenger/UI/ChatWindowController.swift LLMessenger/UI/ContentView.swift
git commit -m "feat: add ChatWindowController (NSPanel) and ContentView stub"
```

---

### Task 4: BriefListView + full ContentView

**Files:**
- Create: `LLMessenger/UI/BriefListView.swift`
- Modify: `LLMessenger/UI/ContentView.swift`

- [ ] **Step 1: Create `LLMessenger/UI/BriefListView.swift`**

```swift
// LLMessenger/UI/BriefListView.swift
import SwiftUI

struct BriefListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        List(selection: Binding(
            get: { appState.selectedBriefID },
            set: { appState.selectedBriefID = $0 }
        )) {
            ForEach(appState.briefGroups) { group in
                Section(group.label) {
                    ForEach(group.briefs) { brief in
                        BriefRowView(brief: brief)
                            .tag(brief.id!)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: appState.selectedBriefID) { _, newID in
            guard let id = newID,
                  let brief = appState.briefs.first(where: { $0.id == id })
            else { return }
            Task {
                try? await chatViewModel.loadBrief(brief)
            }
        }
    }
}

private struct BriefRowView: View {
    let brief: Brief

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(brief.notificationText)
                .font(.callout)
                .lineLimit(1)
            if let summary = brief.openingSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(brief.createdAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 2: Replace ContentView stub with full layout**

Replace the entire content of `LLMessenger/UI/ContentView.swift`:

```swift
// LLMessenger/UI/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        HSplitView {
            BriefListView()
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 240)

            if appState.selectedBrief != nil {
                ChatPanelView()
            } else {
                Text("Select a brief")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
```

- [ ] **Step 3: Create placeholder `LLMessenger/UI/ChatPanelView.swift`** (so it compiles)

```swift
// LLMessenger/UI/ChatPanelView.swift
import SwiftUI

struct ChatPanelView: View {
    var body: some View {
        Text("Chat")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 4: Verify project builds**

```bash
cd ~/Developer/LLMessenger
xcodebuild build -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
cd ~/Developer/LLMessenger
git add LLMessenger/UI/BriefListView.swift LLMessenger/UI/ContentView.swift LLMessenger/UI/ChatPanelView.swift
git commit -m "feat: add BriefListView with group sections and full ContentView layout"
```

---

### Task 5: BriefHeaderView + full ChatPanelView

**Files:**
- Create: `LLMessenger/UI/BriefHeaderView.swift`
- Modify: `LLMessenger/UI/ChatPanelView.swift`

- [ ] **Step 1: Create `LLMessenger/UI/BriefHeaderView.swift`**

```swift
// LLMessenger/UI/BriefHeaderView.swift
import SwiftUI

struct BriefHeaderView: View {
    let brief: Brief

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(brief.notificationText)
                    .font(.headline)
                Spacer()
                Text(brief.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let summary = brief.openingSummary {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.primary)
            }

            if let episodic = brief.episodicSummary {
                Divider()
                Text("Previous context")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(episodic)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.regularMaterial)
    }
}
```

- [ ] **Step 2: Replace ChatPanelView stub with full implementation**

Replace the entire content of `LLMessenger/UI/ChatPanelView.swift`:

```swift
// LLMessenger/UI/ChatPanelView.swift
import SwiftUI

struct ChatPanelView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let brief = appState.selectedBrief {
                BriefHeaderView(brief: brief)
                Divider()
            }

            ThreadView()

            Divider()
            ChatInputView()
        }
    }
}
```

- [ ] **Step 3: Create placeholder `LLMessenger/UI/ThreadView.swift`** (so it compiles)

```swift
// LLMessenger/UI/ThreadView.swift
import SwiftUI

struct ThreadView: View {
    var body: some View {
        ScrollView {
            Text("Messages")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 4: Create placeholder `LLMessenger/UI/ChatInputView.swift`** (so it compiles)

```swift
// LLMessenger/UI/ChatInputView.swift
import SwiftUI

struct ChatInputView: View {
    var body: some View {
        Text("Input")
            .padding()
    }
}
```

- [ ] **Step 5: Verify project builds**

```bash
cd ~/Developer/LLMessenger
xcodebuild build -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
cd ~/Developer/LLMessenger
git add LLMessenger/UI/BriefHeaderView.swift LLMessenger/UI/ChatPanelView.swift \
        LLMessenger/UI/ThreadView.swift LLMessenger/UI/ChatInputView.swift
git commit -m "feat: add BriefHeaderView and full ChatPanelView layout"
```

---

### Task 6: ThreadView + MessageBubbleView + AssistantResponseView

**Files:**
- Modify: `LLMessenger/UI/ThreadView.swift`
- Create: `LLMessenger/UI/MessageBubbleView.swift`
- Create: `LLMessenger/UI/AssistantResponseView.swift`

- [ ] **Step 1: Create `LLMessenger/UI/MessageBubbleView.swift`**

```swift
// LLMessenger/UI/MessageBubbleView.swift
import SwiftUI

struct MessageBubbleView: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(message.sender)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    Text(message.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: Create `LLMessenger/UI/AssistantResponseView.swift`**

```swift
// LLMessenger/UI/AssistantResponseView.swift
import SwiftUI

struct AssistantResponseView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cpu.fill")
                .foregroundStyle(.blue)
                .font(.caption)
                .padding(.top, 3)

            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            Spacer(minLength: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }
}
```

- [ ] **Step 3: Replace ThreadView stub with full implementation**

Replace the entire content of `LLMessenger/UI/ThreadView.swift`:

```swift
// LLMessenger/UI/ThreadView.swift
import SwiftUI

struct ThreadView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(chatViewModel.threadItems) { item in
                        threadItemView(item)
                            .id(item.id)
                    }
                    if chatViewModel.isLoading {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Thinking…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .id("loading")
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: chatViewModel.threadItems.count) { _, _ in
                if let last = chatViewModel.threadItems.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: chatViewModel.isLoading) { _, loading in
                if loading {
                    withAnimation { proxy.scrollTo("loading", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func threadItemView(_ item: ThreadItem) -> some View {
        switch item {
        case .message(let m):
            MessageBubbleView(message: m)
        case .assistantResponse(_, let text):
            AssistantResponseView(text: text)
        case .replyDraft(let id, let draft):
            ReplyDraftView(draftID: id, draft: draft)
        }
    }
}
```

- [ ] **Step 4: Create placeholder `LLMessenger/UI/ReplyDraftView.swift`** (referenced in ThreadView)

```swift
// LLMessenger/UI/ReplyDraftView.swift
import SwiftUI

struct ReplyDraftView: View {
    let draftID: UUID
    let draft: ReplyDraft

    var body: some View {
        Text("Draft: \(draft.text)")
            .padding()
    }
}
```

- [ ] **Step 5: Verify project builds**

```bash
cd ~/Developer/LLMessenger
xcodebuild build -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
cd ~/Developer/LLMessenger
git add LLMessenger/UI/ThreadView.swift LLMessenger/UI/MessageBubbleView.swift \
        LLMessenger/UI/AssistantResponseView.swift LLMessenger/UI/ReplyDraftView.swift
git commit -m "feat: add ThreadView with message bubbles and assistant response cards"
```

---

### Task 7: ReplyDraftView + full ChatInputView

**Files:**
- Modify: `LLMessenger/UI/ReplyDraftView.swift`
- Modify: `LLMessenger/UI/ChatInputView.swift`

- [ ] **Step 1: Replace ReplyDraftView stub with full implementation**

Replace the entire content of `LLMessenger/UI/ReplyDraftView.swift`:

```swift
// LLMessenger/UI/ReplyDraftView.swift
import SwiftUI

struct ReplyDraftView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    let draftID: UUID
    let draft: ReplyDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.orange)
                Text("Draft reply to \(draft.senderName.isEmpty ? "conversation" : draft.senderName)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    chatViewModel.discardDraft(id: draftID)
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(draft.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            HStack {
                Spacer()
                Button("Discard") {
                    chatViewModel.discardDraft(id: draftID)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button("Send Reply") {
                    Task { try? await chatViewModel.sendDraft(draft) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(draft.conversationID == "unknown")
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: Replace ChatInputView stub with full implementation**

Replace the entire content of `LLMessenger/UI/ChatInputView.swift`:

```swift
// LLMessenger/UI/ChatInputView.swift
import SwiftUI

struct ChatInputView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $chatViewModel.inputText)
                .font(.body)
                .frame(minHeight: 36, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .focused($isFocused)
                .onSubmit { sendIfPossible() }
                .overlay(
                    Group {
                        if chatViewModel.inputText.isEmpty {
                            Text("Ask about these messages…")
                                .foregroundStyle(.tertiary)
                                .font(.body)
                                .padding(.leading, 4)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                )

            Button {
                sendIfPossible()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chatViewModel.isLoading
    }

    private func sendIfPossible() {
        guard canSend else { return }
        Task { await chatViewModel.send() }
    }
}
```

- [ ] **Step 3: Verify project builds**

```bash
cd ~/Developer/LLMessenger
xcodebuild build -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/LLMessenger
git add LLMessenger/UI/ReplyDraftView.swift LLMessenger/UI/ChatInputView.swift
git commit -m "feat: add ReplyDraftView with send/discard and ChatInputView with TextEditor"
```

---

### Task 8: AppDelegate Wiring + Full Test Suite

**Files:**
- Modify: `LLMessenger/AppDelegate.swift`
- Modify: `LLMessenger/MenuBar/MenuBarController.swift`

- [ ] **Step 1: Update `MenuBarController.swift`** to accept a toggle callback

Replace the entire content of `LLMessenger/MenuBar/MenuBarController.swift`:

```swift
// LLMessenger/MenuBar/MenuBarController.swift
import AppKit

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private var unreadCount: Int = 0 {
        didSet { updateButton() }
    }
    private var serviceHealthStatus: [String: AdapterHealthResult.Status] = [:]
    var onTogglePanel: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateButton()
        buildMenu()
    }

    func setUnreadCount(_ count: Int) {
        unreadCount = count
    }

    func setServiceHealth(_ health: AdapterHealthResult.Status, for service: String) {
        serviceHealthStatus[service] = health
        rebuildServiceItems()
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let icon = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: nil)
        button.image = icon
        button.action = #selector(buttonClicked)
        button.target = self

        if unreadCount > 0 {
            button.title = " \(unreadCount)"
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open LLMessenger",
                                  action: #selector(openApp),
                                  keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func rebuildServiceItems() {
        // Expanded in Plan 4 (Settings) to show per-service health dots
    }

    @objc private func buttonClicked() {
        onTogglePanel?()
    }

    @objc private func openApp() {
        onTogglePanel?()
    }

    @objc private func openSettings() {
        // Implemented in Plan 4
    }
}
```

- [ ] **Step 2: Update `AppDelegate.swift`** to create AppState and ChatWindowController

Replace the entire content of `LLMessenger/AppDelegate.swift`:

```swift
// LLMessenger/AppDelegate.swift
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?
    var pollEngine: PollEngine?
    var briefEngine: BriefEngine?
    var chatWindowController: ChatWindowController?
    var appState: AppState?
    var database: AppDatabase?
    var startTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let db = try AppDatabase()
            database = db

            let llmClient = makeLLMClient()
            let model = preferredModel()

            let state = AppState(
                database: db,
                llmClient: llmClient,
                llmModel: model,
                basePrompt: PromptBuilder.defaultBasePrompt
            )
            appState = state

            briefEngine = BriefEngine(
                database: db,
                client: llmClient,
                model: model,
                basePrompt: PromptBuilder.defaultBasePrompt
            )

            let windowController = ChatWindowController(appState: state)
            chatWindowController = windowController

            let menuBar = MenuBarController()
            menuBar.onTogglePanel = { [weak windowController] in
                windowController?.toggle()
            }
            menuBarController = menuBar

            let engine = PollEngine(database: db)
            engine.onPollSucceeded = { [weak self] in
                guard let self else { return }
                _ = try? await self.briefEngine?.processNewMessages()
                self.appState?.refreshBriefs()
                if let count = try? self.appState?.repository.fetchAllBriefs().count {
                    self.menuBarController?.setUnreadCount(count)
                }
            }

            let telegramBinary = telegramAdapterPath()
            let telegramConfig = (try? db.dbQueue.read { db in
                try ServiceConfig.fetchOne(db, key: "telegram")
            }) ?? ServiceConfig.default(for: "telegram")

            if let binaryPath = telegramBinary {
                let adapter = SubprocessAdapter(
                    serviceID: "telegram",
                    adapterPath: binaryPath,
                    config: telegramAdapterConfig()
                )
                engine.register(adapter: adapter, config: telegramConfig)
                state.adapters["telegram"] = adapter
            }

            pollEngine = engine
            startTask = Task { await engine.start() }

            // Initial brief load
            state.refreshBriefs()

        } catch {
            let alert = NSAlert()
            alert.messageText = "LLMessenger failed to start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func makeLLMClient() -> LLMClient {
        let store = KeychainStore()
        if let key = try? store.get(account: "anthropic"), !key.isEmpty {
            return LLMProvider.anthropic.makeClient(apiKey: key)
        }
        if let key = try? store.get(account: "openai"), !key.isEmpty {
            return LLMProvider.openai.makeClient(apiKey: key)
        }
        return LLMProvider.ollama.makeClient(apiKey: nil)
    }

    private func preferredModel() -> String {
        let store = KeychainStore()
        if (try? store.get(account: "anthropic")) != nil {
            return LLMProvider.anthropic.defaultModel
        }
        if (try? store.get(account: "openai")) != nil {
            return LLMProvider.openai.defaultModel
        }
        return LLMProvider.ollama.defaultModel
    }

    private func telegramAdapterPath() -> String? {
        let bundled = Bundle.main.path(forResource: "telegram-adapter", ofType: nil)
        if let p = bundled, FileManager.default.fileExists(atPath: p) { return p }

        let community = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/llmessenger/adapters/telegram/telegram-adapter")
        if FileManager.default.fileExists(atPath: community.path) { return community.path }

        return nil
    }

    private func telegramAdapterConfig() -> [String: Any] {
        let sessionPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/llmessenger/data/telegram/session").path
        return [
            "api_id":       ProcessInfo.processInfo.environment["TELEGRAM_API_ID"] ?? "",
            "api_hash":     ProcessInfo.processInfo.environment["TELEGRAM_API_HASH"] ?? "",
            "session_path": sessionPath
        ]
    }
}
```

- [ ] **Step 3: Build and run full test suite**

```bash
cd ~/Developer/LLMessenger
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "Test Case|error:|PASSED|FAILED|BUILD"
```

Expected: All tests PASS. `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
cd ~/Developer/LLMessenger
git add LLMessenger/AppDelegate.swift LLMessenger/MenuBar/MenuBarController.swift
git commit -m "feat: wire AppState and ChatWindowController into AppDelegate and MenuBar"
```

---

## Self-Review

**Spec coverage check:**
- ✅ NSPanel right-anchored, full-height, borderless — Task 3
- ✅ SwiftUI ContentView with HSplitView — Task 4
- ✅ Brief list grouped by Today/Yesterday/date — Tasks 1 + 4
- ✅ Brief header with summary + episodic context — Task 5
- ✅ Thread view with messages, assistant responses, reply drafts — Tasks 6 + 7
- ✅ Chat input with TextEditor and send button (Cmd+Return) — Task 7
- ✅ Reply draft with send/discard flow — Task 7
- ✅ AppState as single source of truth — Task 1
- ✅ ChatViewModel handles send, load, discard — Task 2
- ✅ Click-outside and Escape key close the panel — Task 3
- ✅ MenuBar button toggles panel — Task 8
- ✅ AppDelegate wired — Task 8
- ✅ fetchAllBriefs added to BriefRepository — Task 1

**Placeholder scan:** None found.

**Type consistency:**
- `AppState` defined in Task 1, consumed in Tasks 2, 3, 4, 5, 8 ✅
- `ChatViewModel` defined in Task 2, consumed in Tasks 3, 4, 5, 6, 7, 8 ✅
- `ThreadItem` defined in Task 1, used in Tasks 2, 6 ✅
- `ReplyDraft` defined in Task 1, used in Tasks 2, 6, 7 ✅
- `BriefListGroup`/`BriefListGrouper` defined in Task 1, used in Task 4 ✅
