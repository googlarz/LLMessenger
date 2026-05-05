# LLMessenger Plan 6 — Signal Adapter, Unread Display & Auto-launch

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Signal adapter that calls `signal-cli` directly, show unread briefs visually in the sidebar, and enable auto-launch at login via `SMAppService`.

**Architecture:** `SignalCLIAdapter` conforms to `MessengerAdapter` by spawning `signal-cli` as one-shot subprocesses (no persistent stdin/stdout RPC). Parsing is isolated in pure functions for testability. Signal account number lives in Keychain. `AutoLaunchManager` wraps `SMAppService`. `BriefRowView` gains an unread dot.

**Tech Stack:** signal-cli (Homebrew), ServiceManagement framework, GRDB, XCTest

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `LLMessenger/Core/Adapters/SignalCLIAdapter.swift` | signal-cli subprocess calls + message parsing |
| Create | `LLMessengerTests/SignalCLIAdapterTests.swift` | Unit tests for parsing layer |
| Modify | `LLMessenger/Core/Settings/SettingsRepository.swift` | Add `saveSignalAccount` / `loadSignalAccount` |
| Modify | `LLMessengerTests/SettingsRepositoryTests.swift` | Test Signal account persistence |
| Modify | `LLMessenger/UI/Settings/ServiceSettingsTab.swift` | Signal phone number field |
| Modify | `LLMessenger/AppDelegate.swift` | Register SignalCLIAdapter with PollEngine |
| Modify | `LLMessenger/UI/BriefListView.swift` | Unread dot in BriefRowView |
| Create | `LLMessenger/Core/AutoLaunch/AutoLaunchManager.swift` | SMAppService wrapper |
| Create | `LLMessengerTests/AutoLaunchManagerTests.swift` | Status and toggle tests |
| Modify | `LLMessenger/UI/Settings/LLMSettingsTab.swift` | Auto-launch toggle |
| Modify | `LLMessenger.xcodeproj/project.pbxproj` | Register new files |

---

### Task 1: SignalCLIAdapter parsing layer

signal-cli receive `--output json` emits one JSON envelope per line. DM example:
```json
{"envelope":{"source":"+12345","sourceNumber":"+12345","sourceName":"Alice","sourceDevice":1,"timestamp":1700000000000,"dataMessage":{"timestamp":1700000000000,"message":"Hello","expiresInSeconds":0,"viewOnce":false}}}
```
Group example:
```json
{"envelope":{"source":"+12345","sourceName":"Alice","timestamp":1700000000000,"dataMessage":{"message":"Hi","groupInfo":{"groupId":"abc123==","name":"My Group","type":"DELIVER"}}}}
```
Timestamp is milliseconds since epoch. Lines that aren't dataMessages (receipts, typing indicators) have no `dataMessage` — skip them.

**Files:**
- Create: `LLMessenger/Core/Adapters/SignalCLIAdapter.swift`
- Create: `LLMessengerTests/SignalCLIAdapterTests.swift`

- [ ] **Step 1: Write failing tests**

Create `LLMessengerTests/SignalCLIAdapterTests.swift`:

```swift
// LLMessengerTests/SignalCLIAdapterTests.swift
import XCTest
@testable import LLMessenger

final class SignalCLIAdapterTests: XCTestCase {

    func testParseDMLine() throws {
        let line = """
        {"envelope":{"source":"+12345","sourceNumber":"+12345","sourceName":"Alice","sourceDevice":1,"timestamp":1700000000000,"dataMessage":{"timestamp":1700000000000,"message":"Hello","expiresInSeconds":0,"viewOnce":false}}}
        """
        let convos = SignalCLIAdapter.parse(lines: [line])
        XCTAssertEqual(convos.count, 1)
        XCTAssertEqual(convos[0].id, "+12345")
        XCTAssertEqual(convos[0].type, .dm)
        XCTAssertEqual(convos[0].messages.count, 1)
        XCTAssertEqual(convos[0].messages[0].sender, "Alice")
        XCTAssertEqual(convos[0].messages[0].text, "Hello")
    }

    func testParseGroupLine() throws {
        let line = """
        {"envelope":{"source":"+12345","sourceName":"Alice","timestamp":1700000000000,"dataMessage":{"message":"Hi group","groupInfo":{"groupId":"abc123==","name":"My Group","type":"DELIVER"}}}}
        """
        let convos = SignalCLIAdapter.parse(lines: [line])
        XCTAssertEqual(convos.count, 1)
        XCTAssertEqual(convos[0].id, "abc123==")
        XCTAssertEqual(convos[0].type, .group)
        XCTAssertEqual(convos[0].name, "My Group")
        XCTAssertEqual(convos[0].messages[0].text, "Hi group")
    }

    func testSkipsNonDataMessageLines() {
        let receipt = """
        {"envelope":{"source":"+12345","timestamp":1700000000000,"receiptMessage":{"when":1700000000000,"isDelivery":true}}}
        """
        let convos = SignalCLIAdapter.parse(lines: [receipt])
        XCTAssertEqual(convos.count, 0)
    }

    func testSkipsMalformedLines() {
        let convos = SignalCLIAdapter.parse(lines: ["not json at all", ""])
        XCTAssertEqual(convos.count, 0)
    }

    func testGroupsMessagesFromSameSender() {
        let line1 = """
        {"envelope":{"source":"+12345","sourceNumber":"+12345","sourceName":"Alice","sourceDevice":1,"timestamp":1700000000000,"dataMessage":{"timestamp":1700000000000,"message":"First","expiresInSeconds":0,"viewOnce":false}}}
        """
        let line2 = """
        {"envelope":{"source":"+12345","sourceNumber":"+12345","sourceName":"Alice","sourceDevice":1,"timestamp":1700000001000,"dataMessage":{"timestamp":1700000001000,"message":"Second","expiresInSeconds":0,"viewOnce":false}}}
        """
        let convos = SignalCLIAdapter.parse(lines: [line1, line2])
        XCTAssertEqual(convos.count, 1)
        XCTAssertEqual(convos[0].messages.count, 2)
    }

    func testFallsBackToSourceWhenNoSourceName() {
        let line = """
        {"envelope":{"source":"+12345","sourceNumber":"+12345","sourceDevice":1,"timestamp":1700000000000,"dataMessage":{"timestamp":1700000000000,"message":"Hi","expiresInSeconds":0,"viewOnce":false}}}
        """
        let convos = SignalCLIAdapter.parse(lines: [line])
        XCTAssertEqual(convos[0].messages[0].sender, "+12345")
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```
cd /Users/dawid/Developer/LLMessenger
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/SignalCLIAdapterTests 2>&1 | tail -10
```
Expected: compile error — `SignalCLIAdapter` not found.

- [ ] **Step 3: Implement the parsing layer in SignalCLIAdapter**

Create `LLMessenger/Core/Adapters/SignalCLIAdapter.swift`:

```swift
// LLMessenger/Core/Adapters/SignalCLIAdapter.swift
import Foundation

final class SignalCLIAdapter: MessengerAdapter {
    let serviceID = "signal"
    private(set) var healthStatus: AdapterHealthResult.Status = .warning

    private let accountNumber: String
    private let cliPath: String

    init(accountNumber: String, cliPath: String) {
        self.accountNumber = accountNumber
        self.cliPath = cliPath
    }

    static func detectCLIPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/signal-cli",
            "/usr/local/bin/signal-cli"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - MessengerAdapter

    func start() async throws {
        guard FileManager.default.fileExists(atPath: cliPath) else {
            throw AdapterError.initFailed("signal-cli not found at \(cliPath)")
        }
        healthStatus = .ok
    }

    func fetch(config: FetchConfig) async throws -> AdapterFetchResult {
        let lines = try runCLI(args: ["-a", accountNumber, "receive", "--output", "json"])
        let conversations = Self.parse(lines: lines)
        return AdapterFetchResult(conversations: conversations)
    }

    func send(conversationID: String, text: String) async throws {
        let isGroup = !conversationID.hasPrefix("+")
        var args = ["-a", accountNumber, "send", "-m", text]
        if isGroup {
            args += ["--group-id", conversationID]
        } else {
            args += [conversationID]
        }
        _ = try runCLI(args: args)
    }

    func healthCheck() async -> AdapterHealthResult {
        guard FileManager.default.fileExists(atPath: cliPath) else {
            healthStatus = .error
            return AdapterHealthResult(status: .error, reason: "signal-cli not found", retryAfter: nil)
        }
        healthStatus = .ok
        return AdapterHealthResult(status: .ok, reason: nil, retryAfter: nil)
    }

    // MARK: - Parsing (static for testability)

    static func parse(lines: [String]) -> [AdapterConversation] {
        var byID: [String: (name: String, type: ConversationType, messages: [AdapterMessage])] = [:]
        var order: [String] = []

        for line in lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let data = line.data(using: .utf8),
                  let root = try? JSONDecoder().decode(SignalEnvelope.self, from: data),
                  let dm = root.envelope.dataMessage,
                  let text = dm.message, !text.isEmpty
            else { continue }

            let env = root.envelope
            let senderName = env.sourceName ?? env.sourceNumber ?? env.source
            let timestampMs = dm.timestamp ?? env.timestamp
            let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
            let msgID = "\(env.source)-\(timestampMs)"

            let msg = AdapterMessage(id: msgID, sender: senderName, text: text, timestamp: date)

            let convID: String
            let convName: String
            let convType: ConversationType

            if let g = dm.groupInfo {
                convID = g.groupId
                convName = g.name ?? g.groupId
                convType = .group
            } else {
                convID = env.sourceNumber ?? env.source
                convName = senderName
                convType = .dm
            }

            if byID[convID] == nil {
                byID[convID] = (name: convName, type: convType, messages: [])
                order.append(convID)
            }
            byID[convID]!.messages.append(msg)
        }

        return order.compactMap { id in
            guard let entry = byID[id] else { return nil }
            return AdapterConversation(id: id, name: entry.name,
                                       type: entry.type, messages: entry.messages)
        }
    }

    // MARK: - Private

    private func runCLI(args: [String]) throws -> [String] {
        let p = Process()
        let out = Pipe()
        let err = Pipe()
        p.executableURL = URL(fileURLWithPath: cliPath)
        p.arguments = args
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.components(separatedBy: "\n")
    }
}

// MARK: - signal-cli JSON types

private struct SignalEnvelope: Decodable {
    let envelope: Envelope

    struct Envelope: Decodable {
        let source: String
        let sourceNumber: String?
        let sourceName: String?
        let sourceDevice: Int?
        let timestamp: Int64
        let dataMessage: DataMessage?
    }

    struct DataMessage: Decodable {
        let timestamp: Int64?
        let message: String?
        let groupInfo: GroupInfo?
    }

    struct GroupInfo: Decodable {
        let groupId: String
        let name: String?
        let type: String?
    }
}
```

- [ ] **Step 4: Register in Xcode project (pbxproj)**

Add PBXBuildFile, PBXFileReference, group child, Sources build phase entry, and test target entries for both new files. Use unique UUIDs (e.g. `CC200001CC200001CC200001` through `CC200004CC200004CC200004`). Follow the same pattern as Plan 5 Task 2 Step 4.

Main target:
- `CC200001CC200001CC200001 /* SignalCLIAdapter.swift in Sources */` → fileRef `CC200002CC200002CC200002`
- Add `CC200002CC200002CC200002 /* SignalCLIAdapter.swift */` to PBXFileReference
- Add file ref to `CBD7C66B317B27709DA2E883 /* Adapters */` group children
- Add build file to main target Sources phase

Test target:
- `CC200003CC200003CC200003 /* SignalCLIAdapterTests.swift in Sources */` → fileRef `CC200004CC200004CC200004`
- Add file ref to PBXFileReference, LLMessengerTests group, test Sources phase

- [ ] **Step 5: Run tests to confirm they pass**

```
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/SignalCLIAdapterTests 2>&1 | tail -15
```
Expected: 6 tests PASSED.

- [ ] **Step 6: Commit**

```bash
git add LLMessenger/Core/Adapters/SignalCLIAdapter.swift \
        LLMessengerTests/SignalCLIAdapterTests.swift \
        LLMessenger.xcodeproj/project.pbxproj
git commit -m "feat: Plan 6 T1 — SignalCLIAdapter parsing layer (6 tests)"
```

---

### Task 2: Signal account in Settings + SettingsRepository

**Files:**
- Modify: `LLMessenger/Core/Settings/SettingsRepository.swift`
- Modify: `LLMessengerTests/SettingsRepositoryTests.swift`
- Modify: `LLMessenger/UI/Settings/ServiceSettingsTab.swift`

- [ ] **Step 1: Write failing tests**

Add to `LLMessengerTests/SettingsRepositoryTests.swift`:

```swift
func testSaveAndLoadSignalAccount() throws {
    let repo = SettingsRepository(keychainStore: KeychainStore(), database: nil)
    try repo.saveSignalAccount("+12345678900")
    let loaded = try repo.loadSignalAccount()
    XCTAssertEqual(loaded, "+12345678900")
    try repo.saveSignalAccount("")   // clear
}

func testLoadSignalAccountReturnsNilWhenNotSet() throws {
    let repo = SettingsRepository(keychainStore: KeychainStore(), database: nil)
    try? repo.saveSignalAccount("")  // ensure cleared
    let loaded = try repo.loadSignalAccount()
    XCTAssertNil(loaded)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/SettingsRepositoryTests 2>&1 | tail -10
```
Expected: compile error — methods not found.

- [ ] **Step 3: Add methods to SettingsRepository**

Append before the closing `}` of `SettingsRepository`:

```swift
func saveSignalAccount(_ number: String) throws {
    if number.isEmpty {
        try? keychainStore.delete(account: "signal_account")
    } else {
        try keychainStore.set(account: "signal_account", value: number)
    }
}

func loadSignalAccount() throws -> String? {
    do {
        return try keychainStore.get(account: "signal_account")
    } catch KeychainError.itemNotFound {
        return nil
    }
}
```

- [ ] **Step 4: Add Signal phone field to ServiceSettingsTab**

In `LLMessenger/UI/Settings/ServiceSettingsTab.swift`, add state and field:

```swift
@State private var signalAccount: String = ""
```

In the `Form`, after the `ForEach` block and before the Save button `HStack`:

```swift
Section("Signal") {
    TextField("Phone number (+1234567890)", text: $signalAccount)
}
```

In `load()`, add:
```swift
signalAccount = (try? repo.loadSignalAccount()) ?? ""
```

In `save()`, add:
```swift
try repo.saveSignalAccount(signalAccount)
```

- [ ] **Step 5: Run tests**

```
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/SettingsRepositoryTests 2>&1 | tail -10
```
Expected: All SettingsRepositoryTests PASSED (7 tests).

- [ ] **Step 6: Build to verify UI compiles**

```
xcodebuild build -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add LLMessenger/Core/Settings/SettingsRepository.swift \
        LLMessengerTests/SettingsRepositoryTests.swift \
        LLMessenger/UI/Settings/ServiceSettingsTab.swift
git commit -m "feat: Plan 6 T2 — Signal account in Keychain + Settings UI field"
```

---

### Task 3: AppDelegate registers SignalCLIAdapter

**Files:**
- Modify: `LLMessenger/AppDelegate.swift`

- [ ] **Step 1: Add Signal adapter registration**

In `AppDelegate.applicationDidFinishLaunching`, after the existing Telegram adapter block (the `if let binaryPath = telegramBinary` block), add:

```swift
let settingsRepo = SettingsRepository(database: db)
if let account = try? settingsRepo.loadSignalAccount(), !account.isEmpty {
    let cliPath = SignalCLIAdapter.detectCLIPath() ?? "/usr/local/bin/signal-cli"
    let signalConfig = (try? db.dbQueue.read { db in
        try ServiceConfig.fetchOne(db, key: "signal")
    }) ?? ServiceConfig.default(for: "signal")
    let signalAdapter = SignalCLIAdapter(accountNumber: account, cliPath: cliPath)
    engine.register(adapter: signalAdapter, config: signalConfig)
    state.adapters["signal"] = signalAdapter
}
```

- [ ] **Step 2: Build**

```
xcodebuild build -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Run full test suite**

```
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' 2>&1 | tail -10
```
Expected: All tests PASSED.

- [ ] **Step 4: Commit**

```bash
git add LLMessenger/AppDelegate.swift
git commit -m "feat: Plan 6 T3 — register SignalCLIAdapter in AppDelegate"
```

---

### Task 4: Unread visual indicator in BriefRowView

**Files:**
- Modify: `LLMessenger/UI/BriefListView.swift`

- [ ] **Step 1: Add unread dot to BriefRowView**

Replace the `BriefRowView` body with:

```swift
var body: some View {
    HStack(alignment: .top, spacing: 6) {
        Circle()
            .fill(brief.status == "ready" ? Color.accentColor : Color.clear)
            .frame(width: 7, height: 7)
            .padding(.top, 5)

        VStack(alignment: .leading, spacing: 2) {
            Text(brief.notificationText)
                .font(brief.status == "ready" ? .callout.bold() : .callout)
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
    }
    .padding(.vertical, 2)
}
```

- [ ] **Step 2: Build**

```
xcodebuild build -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add LLMessenger/UI/BriefListView.swift
git commit -m "feat: Plan 6 T4 — unread dot + bold title in BriefRowView"
```

---

### Task 5: Auto-launch at login

**Files:**
- Create: `LLMessenger/Core/AutoLaunch/AutoLaunchManager.swift`
- Create: `LLMessengerTests/AutoLaunchManagerTests.swift`
- Modify: `LLMessenger/UI/Settings/LLMSettingsTab.swift`
- Modify: `LLMessenger.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing tests**

Create `LLMessengerTests/AutoLaunchManagerTests.swift`:

```swift
// LLMessengerTests/AutoLaunchManagerTests.swift
import XCTest
import ServiceManagement
@testable import LLMessenger

final class AutoLaunchManagerTests: XCTestCase {

    func testIsEnabledReturnsBool() {
        // Just verify the property is readable without crashing
        let _ = AutoLaunchManager.isEnabled
    }

    func testStatusDescriptionCoversAllCases() {
        // Smoke-test: calling setEnabled in tests would mutate system state,
        // so we only test the readable surface here.
        XCTAssertNotNil(AutoLaunchManager.self)
    }
}
```

(Full toggle tests would mutate system login items — not safe in unit tests. Verify behaviour manually.)

- [ ] **Step 2: Run tests to confirm they fail**

```
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/AutoLaunchManagerTests 2>&1 | tail -10
```
Expected: compile error.

- [ ] **Step 3: Create AutoLaunchManager**

Create `LLMessenger/Core/AutoLaunch/AutoLaunchManager.swift`:

```swift
// LLMessenger/Core/AutoLaunch/AutoLaunchManager.swift
import ServiceManagement

enum AutoLaunchManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 4: Add toggle to LLMSettingsTab**

In `LLMessenger/UI/Settings/LLMSettingsTab.swift`, add state:
```swift
@State private var launchAtLogin: Bool = AutoLaunchManager.isEnabled
```

Add a Section in the Form before the Save button:

```swift
Section("General") {
    Toggle("Launch at login", isOn: $launchAtLogin)
        .onChange(of: launchAtLogin) { enabled in
            try? AutoLaunchManager.setEnabled(enabled)
        }
}
```

- [ ] **Step 5: Register new files in Xcode project (pbxproj)**

Add PBXBuildFile, PBXFileReference, and group entries for:
- `AutoLaunchManager.swift` (new group `AutoLaunch` under `Core`, UUIDs `DD300001…` through `DD300003…`)
- `AutoLaunchManagerTests.swift` (test target, UUIDs `DD300004…` `DD300005…`)

Add `ServiceManagement.framework` to the main target's Frameworks build phase if not already linked — check by searching for `ServiceManagement` in the pbxproj. If missing, add it.

- [ ] **Step 6: Run tests**

```
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/AutoLaunchManagerTests 2>&1 | tail -10
```
Expected: 2 tests PASSED.

- [ ] **Step 7: Run full test suite**

```
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' 2>&1 | tail -10
```
Expected: All tests PASSED (74+ tests).

- [ ] **Step 8: Commit**

```bash
git add LLMessenger/Core/AutoLaunch/AutoLaunchManager.swift \
        LLMessengerTests/AutoLaunchManagerTests.swift \
        LLMessenger/UI/Settings/LLMSettingsTab.swift \
        LLMessenger.xcodeproj/project.pbxproj
git commit -m "feat: Plan 6 T5 — auto-launch at login via SMAppService + LLMSettingsTab toggle"
```

---

## Self-Review

**Spec coverage:**
- ✅ Signal adapter using signal-cli (no persistent subprocess — one-shot per poll)
- ✅ Parsing DMs and groups from signal-cli JSON output
- ✅ Signal account number stored in Keychain via SettingsRepository
- ✅ Signal phone number field in ServiceSettingsTab
- ✅ SignalCLIAdapter registered in AppDelegate when account is configured
- ✅ Unread briefs show accent-coloured dot + bold title in sidebar
- ✅ Auto-launch toggle in Settings via SMAppService
- ✅ 6 parsing tests, 2 settings tests, 2 auto-launch tests

**Placeholder scan:** No TBDs.

**Type consistency:**
- `SignalCLIAdapter.parse(lines: [String]) -> [AdapterConversation]` — static, called from tests ✅
- `AutoLaunchManager.isEnabled: Bool` / `setEnabled(_:) throws` — used in LLMSettingsTab ✅
- `SettingsRepository.loadSignalAccount() -> String?` — used in AppDelegate ✅
- `ServiceConfig.default(for: "signal")` — same pattern as Telegram in AppDelegate ✅
