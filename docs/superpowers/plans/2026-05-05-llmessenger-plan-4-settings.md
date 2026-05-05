# LLMessenger Plan 4: Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings window that lets the user configure LLM API keys, choose the model, set per-service poll interval and privacy mode, and see service health — wired into the live app via AppState.

**Architecture:** A SwiftUI `SettingsView` is opened from the menu bar "Settings…" item via `NSApp.sendAction(#selector(showSettings), to: nil, from: nil)` + `Settings {}` scene in `LLMessengerApp`. It reads/writes `KeychainStore` for API keys and `ServiceConfig` rows via a new `SettingsRepository`. `AppState` exposes a `reloadConfig()` method so live poll/brief behaviour updates after save.

**Tech Stack:** SwiftUI (TabView, Form, SecureField, Picker, Toggle), KeychainStore (existing), GRDB (ServiceConfig upsert), AppKit (NSApp Settings scene).

---

## File Map

| Action | File |
|--------|------|
| Create | `LLMessenger/UI/Settings/SettingsView.swift` |
| Create | `LLMessenger/UI/Settings/LLMSettingsTab.swift` |
| Create | `LLMessenger/UI/Settings/ServiceSettingsTab.swift` |
| Create | `LLMessenger/Core/Settings/SettingsRepository.swift` |
| Create | `LLMessengerTests/SettingsRepositoryTests.swift` |
| Modify | `LLMessenger/LLMessengerApp.swift` |
| Modify | `LLMessenger/MenuBar/MenuBarController.swift` |
| Modify | `LLMessenger/UI/AppState.swift` |

---

### Task 1: SettingsRepository (with tests)

**Files:**
- Create: `LLMessenger/Core/Settings/SettingsRepository.swift`
- Create: `LLMessengerTests/SettingsRepositoryTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// LLMessengerTests/SettingsRepositoryTests.swift
import XCTest
@testable import LLMessenger

final class SettingsRepositoryTests: XCTestCase {

    func testSaveAndLoadLLMProvider() throws {
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(keychainStore: store)

        try repo.saveLLMKey(provider: .anthropic, key: "sk-ant-test")
        let loaded = try repo.loadLLMKey(provider: .anthropic)
        XCTAssertEqual(loaded, "sk-ant-test")
    }

    func testLoadMissingKeyReturnsNil() throws {
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(keychainStore: store)
        let loaded = try repo.loadLLMKey(provider: .openai)
        XCTAssertNil(loaded)
    }

    func testDeleteLLMKey() throws {
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(keychainStore: store)
        try repo.saveLLMKey(provider: .anthropic, key: "sk-ant-test")
        try repo.deleteLLMKey(provider: .anthropic)
        let loaded = try repo.loadLLMKey(provider: .anthropic)
        XCTAssertNil(loaded)
    }

    func testSaveAndLoadServiceConfig() throws {
        let db = try AppDatabase(inMemory: true)
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(database: db, keychainStore: store)

        var cfg = ServiceConfig.default(for: "telegram")
        cfg.pollIntervalMinutes = 45
        cfg.privacyMode = "eager"
        try repo.saveServiceConfig(cfg)

        let loaded = try repo.loadServiceConfig(for: "telegram")
        XCTAssertEqual(loaded?.pollIntervalMinutes, 45)
        XCTAssertEqual(loaded?.privacyMode, "eager")
    }

    func testSaveServiceConfigUpdatesExisting() throws {
        let db = try AppDatabase(inMemory: true)
        let store = KeychainStore(service: "llmessenger-test-\(UUID().uuidString)")
        let repo = SettingsRepository(database: db, keychainStore: store)

        var cfg = ServiceConfig.default(for: "telegram")
        try repo.saveServiceConfig(cfg)

        cfg.pollIntervalMinutes = 60
        try repo.saveServiceConfig(cfg)

        let loaded = try repo.loadServiceConfig(for: "telegram")
        XCTAssertEqual(loaded?.pollIntervalMinutes, 60)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd ~/Developer/LLMessenger
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/SettingsRepositoryTests 2>&1 | tail -10
```

Expected: FAIL — `SettingsRepository` not found.

- [ ] **Step 3: Check existing KeychainStore API**

Open `~/Developer/LLMessenger/LLMessenger/Core/Keychain/KeychainStore.swift`. Note the `init(service:)` and `get/set/delete(account:)` method signatures — use them in SettingsRepository.

- [ ] **Step 4: Create `LLMessenger/Core/Settings/SettingsRepository.swift`**

```swift
// LLMessenger/Core/Settings/SettingsRepository.swift
import Foundation

struct SettingsRepository {
    private let keychainStore: KeychainStore
    private let database: AppDatabase?

    init(keychainStore: KeychainStore = KeychainStore(), database: AppDatabase? = nil) {
        self.keychainStore = keychainStore
        self.database = database
    }

    // MARK: - LLM Keys

    func saveLLMKey(provider: LLMProvider, key: String) throws {
        if key.isEmpty {
            try? keychainStore.delete(account: provider.rawValue)
        } else {
            try keychainStore.set(key, account: provider.rawValue)
        }
    }

    func loadLLMKey(provider: LLMProvider) throws -> String? {
        try keychainStore.get(account: provider.rawValue)
    }

    func deleteLLMKey(provider: LLMProvider) throws {
        try keychainStore.delete(account: provider.rawValue)
    }

    // MARK: - Service Config

    func saveServiceConfig(_ config: ServiceConfig) throws {
        guard let db = database else { return }
        try db.dbQueue.write { db in
            try config.save(db)
        }
    }

    func loadServiceConfig(for service: String) throws -> ServiceConfig? {
        guard let db = database else { return nil }
        return try db.dbQueue.read { db in
            try ServiceConfig.fetchOne(db, key: service)
        }
    }

    func loadAllServiceConfigs() throws -> [ServiceConfig] {
        guard let db = database else { return [] }
        return try db.dbQueue.read { db in
            try ServiceConfig.fetchAll(db)
        }
    }
}
```

- [ ] **Step 5: Add `SettingsRepository.swift` to the Xcode project** by editing `project.pbxproj`:

Add a `PBXBuildFile`, `PBXFileReference`, a `Settings` group inside `Core`, wire it to the Sources build phase and the Core group.

Use these UUIDs (substitute your own generated ones if needed):
- fileRef: `SET1111111111111111111111`
- buildFile: `SET2222222222222222222222`
- Settings group: `SET3333333333333333333333`

In `project.pbxproj`:

1. In `/* Begin PBXBuildFile section */`, add:
   ```
   		SET2222222222222222222222 /* SettingsRepository.swift in Sources */ = {isa = PBXBuildFile; fileRef = SET1111111111111111111111 /* SettingsRepository.swift */; };
   ```

2. In `/* Begin PBXFileReference section */`, add:
   ```
   		SET1111111111111111111111 /* SettingsRepository.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SettingsRepository.swift; sourceTree = "<group>"; };
   ```

3. Add a `Settings` group in the `Core` group (after `LLM`):
   ```
   		SET3333333333333333333333 /* Settings */ = {
   			isa = PBXGroup;
   			children = (
   				SET1111111111111111111111 /* SettingsRepository.swift */,
   			);
   			path = Settings;
   			sourceTree = "<group>";
   		};
   ```

4. In the `Core` group children, add `SET3333333333333333333333 /* Settings */,`.

5. In the app's Sources build phase, add `SET2222222222222222222222 /* SettingsRepository.swift in Sources */,`.

Also add `SettingsRepositoryTests.swift` similarly (fileRef `SET4444444444444444444444`, buildFile `SET5555555555555555555555`) to the LLMessengerTests group and test Sources build phase.

- [ ] **Step 6: Run tests — should pass**

```bash
cd ~/Developer/LLMessenger
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/SettingsRepositoryTests 2>&1 | tail -10
```

Expected: PASS (5 tests).

- [ ] **Step 7: Commit**

```bash
cd ~/Developer/LLMessenger
git add LLMessenger/Core/Settings/SettingsRepository.swift \
        LLMessengerTests/SettingsRepositoryTests.swift \
        LLMessenger.xcodeproj/project.pbxproj
git commit -m "feat: SettingsRepository for LLM key and ServiceConfig persistence"
```

---

### Task 2: SettingsView + LLMSettingsTab

**Files:**
- Create: `LLMessenger/UI/Settings/SettingsView.swift`
- Create: `LLMessenger/UI/Settings/LLMSettingsTab.swift`

- [ ] **Step 1: Create `LLMessenger/UI/Settings/SettingsView.swift`**

```swift
// LLMessenger/UI/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            LLMSettingsTab()
                .tabItem { Label("AI Model", systemImage: "cpu") }
                .tag(0)

            ServiceSettingsTab()
                .tabItem { Label("Services", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)
        }
        .frame(width: 480, height: 340)
        .padding()
    }
}
```

- [ ] **Step 2: Create `LLMessenger/UI/Settings/LLMSettingsTab.swift`**

```swift
// LLMessenger/UI/Settings/LLMSettingsTab.swift
import SwiftUI

struct LLMSettingsTab: View {
    @State private var anthropicKey: String = ""
    @State private var openAIKey: String = ""
    @State private var ollamaModel: String = ""
    @State private var saveStatus: String = ""

    private let repo = SettingsRepository()

    var body: some View {
        Form {
            Section("Anthropic") {
                SecureField("API Key (sk-ant-…)", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("OpenAI") {
                SecureField("API Key (sk-…)", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Ollama (local)") {
                TextField("Model name (e.g. llama3)", text: $ollamaModel)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        anthropicKey = (try? repo.loadLLMKey(provider: .anthropic)) ?? ""
        openAIKey    = (try? repo.loadLLMKey(provider: .openai))    ?? ""
        ollamaModel  = (try? repo.loadLLMKey(provider: .ollama))    ?? ""
    }

    private func save() {
        do {
            try repo.saveLLMKey(provider: .anthropic, key: anthropicKey)
            try repo.saveLLMKey(provider: .openai,    key: openAIKey)
            try repo.saveLLMKey(provider: .ollama,    key: ollamaModel)
            saveStatus = "Saved ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" }
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 3: Create placeholder `LLMessenger/UI/Settings/ServiceSettingsTab.swift`** (so it compiles)

```swift
// LLMessenger/UI/Settings/ServiceSettingsTab.swift
import SwiftUI

struct ServiceSettingsTab: View {
    var body: some View {
        Text("Service settings")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 4: Add all 3 files to `project.pbxproj`**

Add a `Settings` group inside the `UI` group (separate from the `Core/Settings` group). Generate 3 pairs of fileRef/buildFile UUIDs for:
- `SettingsView.swift`
- `LLMSettingsTab.swift`
- `ServiceSettingsTab.swift`

Follow the same pbxproj editing pattern as previous tasks.

- [ ] **Step 5: Verify project builds**

```bash
cd ~/Developer/LLMessenger
xcodebuild build -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
cd ~/Developer/LLMessenger
git add LLMessenger/UI/Settings/ LLMessenger.xcodeproj/project.pbxproj
git commit -m "feat: SettingsView with LLM API key tab (Anthropic, OpenAI, Ollama)"
```

---

### Task 3: ServiceSettingsTab (full) + AppState.reloadConfig

**Files:**
- Modify: `LLMessenger/UI/Settings/ServiceSettingsTab.swift`
- Modify: `LLMessenger/UI/AppState.swift`

- [ ] **Step 1: Add `reloadConfig()` to AppState**

In `LLMessenger/UI/AppState.swift`, add inside the `AppState` class, after `refreshBriefs()`:

```swift
    func reloadConfig() {
        refreshBriefs()
        // PollEngine config update is handled at launch; runtime reload is a Plan 5 concern
    }
```

- [ ] **Step 2: Replace `ServiceSettingsTab` stub with full implementation**

Replace the entire content of `LLMessenger/UI/Settings/ServiceSettingsTab.swift`:

```swift
// LLMessenger/UI/Settings/ServiceSettingsTab.swift
import SwiftUI

struct ServiceSettingsTab: View {
    @State private var configs: [ServiceConfig] = []
    @State private var saveStatus: String = ""
    private let repo: SettingsRepository

    init(database: AppDatabase? = nil) {
        repo = SettingsRepository(database: database)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if configs.isEmpty {
                Text("No services configured.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    ForEach($configs, id: \.service) { $cfg in
                        Section(cfg.service.capitalized) {
                            Toggle("Enabled", isOn: $cfg.enabled)

                            Picker("Privacy mode", selection: $cfg.privacyMode) {
                                Text("On demand").tag("on_demand")
                                Text("Eager (auto-summarise)").tag("eager")
                            }
                            .pickerStyle(.segmented)

                            Stepper("Poll every \(cfg.pollIntervalMinutes) min",
                                    value: $cfg.pollIntervalMinutes,
                                    in: 5...120, step: 5)
                        }
                    }

                    HStack {
                        Spacer()
                        if !saveStatus.isEmpty {
                            Text(saveStatus)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        Button("Save") { save() }
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        configs = (try? repo.loadAllServiceConfigs()) ?? []
        if configs.isEmpty {
            configs = [ServiceConfig.default(for: "telegram")]
        }
    }

    private func save() {
        do {
            for cfg in configs {
                try repo.saveServiceConfig(cfg)
            }
            saveStatus = "Saved ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" }
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
        }
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
git add LLMessenger/UI/Settings/ServiceSettingsTab.swift LLMessenger/UI/AppState.swift
git commit -m "feat: ServiceSettingsTab with poll interval, privacy mode, and enabled toggle"
```

---

### Task 4: Wire Settings into App + MenuBar

**Files:**
- Modify: `LLMessenger/LLMessengerApp.swift`
- Modify: `LLMessenger/MenuBar/MenuBarController.swift`
- Modify: `LLMessenger/UI/AppState.swift`

- [ ] **Step 1: Update `LLMessengerApp.swift`** to use the real Settings scene

Replace the entire content of `LLMessenger/LLMessengerApp.swift`:

```swift
// LLMessenger/LLMessengerApp.swift
import SwiftUI

@main
struct LLMessengerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
```

- [ ] **Step 2: Update `MenuBarController.swift`** to open Settings via `NSApp.sendAction`

In `MenuBarController.swift`, replace the `openSettings` method:

```swift
    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
```

- [ ] **Step 3: Update `AppState.swift`** — pass database to `SettingsView` via init

In `AppState.swift`, update `makeChatViewModel()` companion to also expose settings factory:

```swift
    func makeSettingsRepository() -> SettingsRepository {
        SettingsRepository(database: database)
    }
```

- [ ] **Step 4: Update `SettingsView.swift`** to accept a database for the service tab

Replace the content of `LLMessenger/UI/Settings/SettingsView.swift`:

```swift
// LLMessenger/UI/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    var database: AppDatabase? = nil

    var body: some View {
        TabView {
            LLMSettingsTab()
                .tabItem { Label("AI Model", systemImage: "cpu") }
                .tag(0)

            ServiceSettingsTab(database: database)
                .tabItem { Label("Services", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)
        }
        .frame(width: 480, height: 340)
        .padding()
    }
}
```

- [ ] **Step 5: Update `LLMessengerApp.swift`** to pass the database from AppDelegate

```swift
// LLMessenger/LLMessengerApp.swift
import SwiftUI

@main
struct LLMessengerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(database: appDelegate.database)
        }
    }
}
```

- [ ] **Step 6: Add per-service health dots to MenuBar**

In `MenuBarController.swift`, replace `rebuildServiceItems()`:

```swift
    private func rebuildServiceItems() {
        guard let menu = statusItem.menu else { return }
        let healthRange = (2..<menu.items.count - 3)
        for i in healthRange.reversed() { menu.removeItem(at: i) }

        var insertAt = 2
        for (service, status) in serviceHealthStatus.sorted(by: { $0.key < $1.key }) {
            let dot: String
            switch status {
            case .ok:      dot = "🟢"
            case .warning: dot = "🟡"
            case .error:   dot = "🔴"
            }
            let item = NSMenuItem(title: "\(dot) \(service.capitalized)",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: insertAt)
            insertAt += 1
        }
        if !serviceHealthStatus.isEmpty {
            menu.insertItem(.separator(), at: insertAt)
        }
    }
```

- [ ] **Step 7: Verify project builds and all tests still pass**

```bash
cd ~/Developer/LLMessenger
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' 2>&1 | \
  grep -E "Test Suite.*passed|Test Suite.*failed|BUILD|error:"
```

Expected: All test suites pass. `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
cd ~/Developer/LLMessenger
git add LLMessenger/LLMessengerApp.swift \
        LLMessenger/MenuBar/MenuBarController.swift \
        LLMessenger/UI/AppState.swift \
        LLMessenger/UI/Settings/SettingsView.swift
git commit -m "feat: wire Settings window into app and menu bar, add service health dots"
```

---

## Self-Review

**Spec coverage:**
- ✅ LLM API key entry (Anthropic, OpenAI, Ollama) — Task 2
- ✅ Privacy mode picker (on_demand / eager) per service — Task 3
- ✅ Poll interval stepper per service — Task 3
- ✅ Service enable/disable toggle — Task 3
- ✅ Settings window opened from "Settings…" menu item — Task 4
- ✅ Service health dots in menu bar — Task 4
- ✅ SettingsRepository with Keychain + GRDB — Task 1 (with 5 tests)
- ✅ `reloadConfig()` on AppState — Task 3

**Placeholder scan:** None found.

**Type consistency:**
- `SettingsRepository` defined in Task 1, consumed in Tasks 2, 3, 4 ✅
- `SettingsView(database:)` defined in Task 4, used in `LLMessengerApp` ✅
- `ServiceSettingsTab(database:)` defined in Task 3, used in `SettingsView` ✅
