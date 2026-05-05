# LLMessenger Plan 5 — Notifications & Unread Tracking

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Post a macOS `UNUserNotificationCenter` alert when a new Brief arrives, track which briefs are unread (status == "ready"), mark them read on selection, and open the correct brief when the user taps a notification.

**Architecture:** A thin `NotificationManager` wraps `UNUserNotificationCenter`; `BriefRepository` gains `fetchUnreadCount()` and `markAsOpen(briefID:)`; `AppState` exposes `unreadCount` and `markAsOpen`; `AppDelegate` wires everything together; `BriefListView` marks briefs as open on selection; `ChatWindowController` gains a `show(selectingBriefID:)` deep-link entry point.

**Tech Stack:** UNUserNotificationCenter (UserNotifications framework), GRDB, SwiftUI, AppKit, XCTest

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `LLMessenger/Core/Notifications/NotificationManager.swift` | Permission request, post notification, delegate tap handler |
| Modify | `LLMessenger/Core/Brief/BriefRepository.swift` | Add `fetchUnreadCount()` and `markAsOpen(briefID:)` |
| Modify | `LLMessenger/UI/AppState.swift` | Add `unreadCount`, `markAsOpen(briefID:)`, `onUnreadChanged` callback |
| Modify | `LLMessenger/AppDelegate.swift` | Wire NotificationManager, fix unread count, handle notification tap |
| Modify | `LLMessenger/UI/BriefListView.swift` | Call `appState.markAsOpen` on selection |
| Modify | `LLMessenger/UI/ChatWindowController.swift` | Add `show(selectingBriefID:)` |
| Create | `LLMessengerTests/NotificationManagerTests.swift` | Unit tests for post/clear/tap-handler logic |
| Modify | `LLMessengerTests/BriefRepositoryTests.swift` | Tests for fetchUnreadCount and markAsOpen |

---

### Task 1: BriefRepository unread tracking

**Files:**
- Modify: `LLMessenger/Core/Brief/BriefRepository.swift`
- Modify: `LLMessengerTests/BriefRepositoryTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `LLMessengerTests/BriefRepositoryTests.swift`:

```swift
func testFetchUnreadCountReturnsOnlyReadyBriefs() throws {
    let db = try AppDatabase(inMemory: true)
    let repo = BriefRepository(database: db)
    let ready = makeBrief(status: "ready")
    let open  = makeBrief(status: "open")
    _ = try repo.insertBrief(ready)
    _ = try repo.insertBrief(open)
    XCTAssertEqual(try repo.fetchUnreadCount(), 1)
}

func testMarkAsOpenChangesStatus() throws {
    let db = try AppDatabase(inMemory: true)
    let repo = BriefRepository(database: db)
    let id = try repo.insertBrief(makeBrief(status: "ready"))
    try repo.markAsOpen(briefID: id)
    let fetched = try repo.fetchBrief(id: id)
    XCTAssertEqual(fetched?.status, "open")
}

// helper — add near existing makeBrief helpers:
private func makeBrief(status: String) -> Brief {
    Brief(id: nil, createdAt: Date(), status: status, services: "[]",
          openingSummary: nil, notificationText: "test", episodicSummary: nil)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```
cd /Users/dawid/Developer/LLMessenger
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/BriefRepositoryTests 2>&1 | tail -20
```
Expected: compile error — `fetchUnreadCount` and `markAsOpen` not found.

- [ ] **Step 3: Add methods to BriefRepository**

Append to `LLMessenger/Core/Brief/BriefRepository.swift` before the closing `}`:

```swift
func fetchUnreadCount() throws -> Int {
    try database.dbQueue.read { db in
        try Brief.filter(Column("status") == "ready").fetchCount(db)
    }
}

func markAsOpen(briefID: Int64) throws {
    try database.dbQueue.write { db in
        try db.execute(
            sql: "UPDATE briefs SET status = 'open' WHERE id = ?",
            arguments: [briefID]
        )
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/BriefRepositoryTests 2>&1 | tail -20
```
Expected: All BriefRepositoryTests PASSED.

- [ ] **Step 5: Commit**

```bash
git add LLMessenger/Core/Brief/BriefRepository.swift \
        LLMessengerTests/BriefRepositoryTests.swift
git commit -m "feat: Plan 5 T1 — fetchUnreadCount + markAsOpen on BriefRepository"
```

---

### Task 2: NotificationManager

**Files:**
- Create: `LLMessenger/Core/Notifications/NotificationManager.swift`
- Create: `LLMessengerTests/NotificationManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `LLMessengerTests/NotificationManagerTests.swift`:

```swift
// LLMessengerTests/NotificationManagerTests.swift
import XCTest
@testable import LLMessenger

final class NotificationManagerTests: XCTestCase {

    func testBriefIDRoundTripsViaUserInfo() {
        let userInfo: [AnyHashable: Any] = ["briefID": Int64(42)]
        let extracted = NotificationManager.briefID(from: userInfo)
        XCTAssertEqual(extracted, 42)
    }

    func testBriefIDReturnsNilForMissingKey() {
        let extracted = NotificationManager.briefID(from: [:])
        XCTAssertNil(extracted)
    }

    func testBriefIDReturnsNilForWrongType() {
        let extracted = NotificationManager.briefID(from: ["briefID": "notAnInt"])
        XCTAssertNil(extracted)
    }

    func testNotificationCategoryIdentifier() {
        XCTAssertEqual(NotificationManager.categoryID, "LLMessenger.brief")
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/NotificationManagerTests 2>&1 | tail -20
```
Expected: compile error — `NotificationManager` not found.

- [ ] **Step 3: Create NotificationManager**

Create `LLMessenger/Core/Notifications/NotificationManager.swift`:

```swift
// LLMessenger/Core/Notifications/NotificationManager.swift
import Foundation
import UserNotifications

@MainActor
final class NotificationManager: NSObject {
    static let categoryID = "LLMessenger.brief"

    var onNotificationTap: ((Int64) -> Void)?

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        UNUserNotificationCenter.current().delegate = self
    }

    func post(briefID: Int64, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["briefID": briefID]

        let request = UNNotificationRequest(
            identifier: "brief-\(briefID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func briefID(from userInfo: [AnyHashable: Any]) -> Int64? {
        userInfo["briefID"] as? Int64
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let id = Self.briefID(from: userInfo) {
            Task { @MainActor in self.onNotificationTap?(id) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
```

- [ ] **Step 4: Add file to Xcode project**

Edit `LLMessenger.xcodeproj/project.pbxproj` to register the new file. You need four edits:

**4a. Add PBXBuildFile entry** — find the block of existing `PBXBuildFile` entries and add:
```
		AA000001AA000001AA000001 /* NotificationManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000002AA000002AA000002 /* NotificationManager.swift */; };
```

**4b. Add PBXFileReference entry** — find the block of existing `PBXFileReference` entries and add:
```
		AA000002AA000002AA000002 /* NotificationManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NotificationManager.swift; sourceTree = "<group>"; };
```

**4c. Create group for Core/Notifications** — find the `Core` group children array (look for `"PollEngine.swift"` to orient) and add a new group:
```
		AA000003AA000003AA000003 /* Notifications */ = {
			isa = PBXGroup;
			children = (
				AA000002AA000002AA000002 /* NotificationManager.swift */,
			);
			path = Notifications;
			sourceTree = "<group>";
		};
```
Then add `AA000003AA000003AA000003 /* Notifications */,` to the Core group's children list.

**4d. Add to Sources build phase** — find the main target's PBXSourcesBuildPhase `files` array and add:
```
		AA000001AA000001AA000001 /* NotificationManager.swift in Sources */,
```

Repeat for the test target build file:
```
		AA000004AA000004AA000004 /* NotificationManagerTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000005AA000005AA000005 /* NotificationManagerTests.swift */; };
```
```
		AA000005AA000005AA000005 /* NotificationManagerTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NotificationManagerTests.swift; sourceTree = "<group>"; };
```
Add file ref to Tests group children. Add build file to test target Sources build phase.

- [ ] **Step 5: Run tests to confirm they pass**

```
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' \
  -only-testing:LLMessengerTests/NotificationManagerTests 2>&1 | tail -20
```
Expected: All 4 NotificationManagerTests PASSED.

- [ ] **Step 6: Commit**

```bash
git add LLMessenger/Core/Notifications/NotificationManager.swift \
        LLMessengerTests/NotificationManagerTests.swift \
        LLMessenger.xcodeproj/project.pbxproj
git commit -m "feat: Plan 5 T2 — NotificationManager with UNUserNotificationCenter"
```

---

### Task 3: AppState unread count + AppDelegate wiring

**Files:**
- Modify: `LLMessenger/UI/AppState.swift`
- Modify: `LLMessenger/AppDelegate.swift`

- [ ] **Step 1: Add unreadCount and markAsOpen to AppState**

In `LLMessenger/UI/AppState.swift`, add after `var selectedBrief`:

```swift
var unreadCount: Int {
    briefs.filter { $0.status == "ready" }.count
}

func markAsOpen(briefID: Int64) {
    do {
        try repository.markAsOpen(briefID: briefID)
        refreshBriefs()
    } catch {
        // silently ignore — UI state will be stale at worst
    }
}
```

- [ ] **Step 2: Wire NotificationManager in AppDelegate**

In `LLMessenger/AppDelegate.swift`:

a) Add property:
```swift
var notificationManager: NotificationManager?
```

b) In `applicationDidFinishLaunching`, after `let state = AppState(...)`:
```swift
let notifications = NotificationManager()
notifications.requestPermission()
notifications.onNotificationTap = { [weak windowController, weak state] briefID in
    state?.selectedBriefID = briefID
    state?.markAsOpen(briefID: briefID)
    windowController?.show(selectingBriefID: briefID)
}
notificationManager = notifications
```

c) Replace the `engine.onPollSucceeded` closure body with:
```swift
engine.onPollSucceeded = { [weak self] in
    guard let self else { return }
    if let briefID = try? await self.briefEngine?.processNewMessages(), let id = briefID {
        self.appState?.refreshBriefs()
        let brief = try? self.appState?.repository.fetchBrief(id: id)
        let title = "New messages"
        let body = brief?.notificationText ?? "You have new messages"
        self.notificationManager?.post(briefID: id, title: title, body: body)
        let unread = (try? self.appState?.repository.fetchUnreadCount()) ?? 0
        self.menuBarController?.setUnreadCount(unread)
    } else {
        self.appState?.refreshBriefs()
        let unread = (try? self.appState?.repository.fetchUnreadCount()) ?? 0
        self.menuBarController?.setUnreadCount(unread)
    }
}
```

- [ ] **Step 3: Build to verify no compile errors**

```
xcodebuild build -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`, no errors.

- [ ] **Step 4: Run full test suite**

```
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' 2>&1 | tail -30
```
Expected: All tests pass (60+ tests).

- [ ] **Step 5: Commit**

```bash
git add LLMessenger/UI/AppState.swift LLMessenger/AppDelegate.swift
git commit -m "feat: Plan 5 T3 — AppState unreadCount + AppDelegate notification wiring"
```

---

### Task 4: BriefListView mark-as-open on selection

**Files:**
- Modify: `LLMessenger/UI/BriefListView.swift`

- [ ] **Step 1: Add markAsOpen call on selection**

In `BriefListView.swift`, find the `onChange(of: appState.selectedBriefID) { newID in` block and add the mark-as-open call:

```swift
.onChange(of: appState.selectedBriefID) { newID in
    guard let id = newID else { return }
    appState.markAsOpen(briefID: id)
    Task {
        try? await chatViewModel.loadBrief(appState.selectedBrief!)
    }
}
```

(The `try? await chatViewModel.loadBrief` call should already be there — add `appState.markAsOpen(briefID: id)` just before or after it, depending on current code.)

- [ ] **Step 2: Build to verify no compile errors**

```
xcodebuild build -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add LLMessenger/UI/BriefListView.swift
git commit -m "feat: Plan 5 T4 — mark brief as open on selection in BriefListView"
```

---

### Task 5: ChatWindowController deep-link + final verification

**Files:**
- Modify: `LLMessenger/UI/ChatWindowController.swift`

- [ ] **Step 1: Add show(selectingBriefID:)**

In `ChatWindowController.swift`, add after the existing `show()` method:

```swift
func show(selectingBriefID briefID: Int64) {
    appState.selectedBriefID = briefID
    show()
}
```

- [ ] **Step 2: Build**

```
xcodebuild build -scheme LLMessenger -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Run full test suite**

```
xcodebuild test -scheme LLMessenger -destination 'platform=macOS' 2>&1 | tail -30
```
Expected: All tests PASSED. Note test count (should be 64+).

- [ ] **Step 4: Final commit**

```bash
git add LLMessenger/UI/ChatWindowController.swift
git commit -m "feat: Plan 5 T5 — ChatWindowController show(selectingBriefID:) deep-link"
```

---

## Self-Review

**Spec coverage:**
- ✅ macOS notification posted when Brief is created
- ✅ Notification tap opens panel and selects the brief
- ✅ Unread count in menu bar reflects only status == "ready" briefs (not total count)
- ✅ Selecting a brief marks it status == "open"
- ✅ NotificationManager requests permission at launch
- ✅ Notifications shown as banners even when app is in foreground (willPresent delegate)

**Placeholder scan:** No TBDs or TODOs.

**Type consistency:**
- `fetchUnreadCount() -> Int` used in AppDelegate as `fetchUnreadCount()`  ✅
- `markAsOpen(briefID: Int64)` matches usage in AppState and AppDelegate ✅
- `show(selectingBriefID: Int64)` called from AppDelegate notification tap closure ✅
- `NotificationManager.briefID(from:)` is static, called from delegate method ✅
