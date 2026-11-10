// LLMessengerTests/OnboardingSnapshotTests.swift
//
// Renders every first-run screen offscreen to docs/design/snapshots/<tag>/onboarding-*.png
// from scripted probes: no permissions, no Ollama, no real data.
import XCTest
import SwiftUI
import AppKit
@testable import LLMessenger

@MainActor
final class OnboardingSnapshotTests: XCTestCase {
    private let size = NSSize(width: 540, height: 660)
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.llmessenger.onboarding-snapshots.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        UserDefaults.standard.removeObject(forKey: DemoSeeder.demoFlagKey)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeObject(forKey: DemoSeeder.demoFlagKey)
        super.tearDown()
    }

    // MARK: Renderer

    private var outputDir: URL {
        let tag = ProcessInfo.processInfo.environment["SNAPSHOT_TAG"] ?? "current"
        let testsDir = URL(fileURLWithPath: String(#filePath)).deletingLastPathComponent()
        return testsDir.deletingLastPathComponent()
            .appendingPathComponent("docs/design/snapshots/\(tag)", isDirectory: true)
    }

    private func render<V: View>(_ view: V, size: NSSize, name: String, light: Bool = false) throws {
        Theme.forceReduceMotion = true
        let appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Theme.bg))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        hosting.appearance = appearance
        window.colorSpace = .sRGB
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("No bitmap rep for \(name)")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG encode failed for \(name)")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let file = outputDir.appendingPathComponent("\(name)\(light ? "-light" : "").png")
        try png.write(to: file)
        print("SNAPSHOT WROTE: \(file.path)")
    }

    private func screen(_ model: OnboardingModel, name: String, lightToo: Bool = false) throws {
        try render(OnboardingRootView(model: model), size: size, name: name)
        if lightToo { try render(OnboardingRootView(model: model), size: size, name: name, light: true) }
    }

    private func makeModel(_ probes: Probes, startAt: OnboardingStep) throws -> (OnboardingModel, AppDatabase) {
        let db = try AppDatabase(inMemory: true)
        let settings = SettingsRepository(keychainStore: KeychainStore(service: "test.\(suiteName)"),
                                          database: db, userDefaults: defaults)
        let model = OnboardingModel(database: db, environment: probes.environment, startAt: startAt,
                                    defaults: defaults, settings: settings)
        return (model, db)
    }

    // MARK: Screens

    func testWelcome() throws {
        let (model, _) = try makeModel(Probes(), startAt: .welcome)
        try screen(model, name: "onboarding-welcome", lightToo: true)
    }

    func testServices() throws {
        let probes = Probes(); probes.whatsApp = true
        let (model, _) = try makeModel(probes, startAt: .services)
        try screen(model, name: "onboarding-services", lightToo: true)

        let (noWhatsApp, _) = try makeModel(Probes(), startAt: .services)
        try screen(noWhatsApp, name: "onboarding-services-no-whatsapp")
    }

    func testAccessStates() throws {
        let probes = Probes()
        let (waiting, _) = try makeModel(probes, startAt: .services)
        waiting.continueFromServices()
        try screen(waiting, name: "onboarding-access-waiting")

        let (needsHelp, _) = try makeModel(probes, startAt: .services)
        needsHelp.continueFromServices()
        needsHelp.openPrivacySettings()
        probes.now = probes.now.addingTimeInterval(45)
        needsHelp.tick()
        XCTAssertEqual(needsHelp.access.status, .needsHelp)
        try screen(needsHelp, name: "onboarding-access-needs-help", lightToo: true)

        let granted = Probes(); granted.fda = true
        let (grantedModel, _) = try makeModel(granted, startAt: .services)
        grantedModel.continueFromServices()
        XCTAssertEqual(grantedModel.access.status, .granted)
        try screen(grantedModel, name: "onboarding-access-granted")
    }

    func testAIStepInEachEnvironment() async throws {
        let apple = Probes(); apple.apple = true
        let (appleModel, _) = try makeModel(apple, startAt: .ai)
        await appleModel.refreshAIDetection()
        try screen(appleModel, name: "onboarding-ai-apple")

        let ollama = Probes(); ollama.ollama = ["llama3.1:8b", "qwen2.5:7b", "mistral:7b"]
        let (ollamaModel, _) = try makeModel(ollama, startAt: .ai)
        await ollamaModel.refreshAIDetection()
        try screen(ollamaModel, name: "onboarding-ai-ollama")

        let (none, _) = try makeModel(Probes(), startAt: .ai)
        await none.refreshAIDetection()
        try screen(none, name: "onboarding-ai-none", lightToo: true)
    }

    func testFinishStates() async throws {
        let apple = Probes(); apple.apple = true; apple.fda = true
        let db = try AppDatabase(inMemory: true)
        func state(_ configure: (AppState) -> Void = { _ in }) async -> AppState {
            let s = AppState(database: db, llmClient: UnconfiguredLLMClient(), llmModel: "x",
                             isLLMConfigured: true, basePrompt: "")
            configure(s)
            return s
        }
        func finishModel(_ probes: Probes, appState: AppState?) async throws -> OnboardingModel {
            let (model, _) = try makeModel(probes, startAt: .ai)
            model.appState = appState
            await model.refreshAIDetection()
            model.useAutomaticAI()
            return model
        }

        let ready = try await finishModel(apple, appState: nil)
        try screen(ready, name: "onboarding-finish-ready")

        let buildingState = await state { $0.briefGenerationState = .summarizing }
        let building = try await finishModel(apple, appState: buildingState)
        building.startBuilding()
        building.tick()
        XCTAssertEqual(building.digestStatus, .building(detail: "Writing your digest", slow: false))
        try screen(building, name: "onboarding-finish-building")

        let failedState = await state {
            $0.briefGenerationState = .failed
            $0.lastError = "Couldn\u{2019}t reach Ollama. Start the Ollama app and try again."
        }
        let failed = try await finishModel(apple, appState: failedState)
        failed.startBuilding()
        failed.tick()
        try screen(failed, name: "onboarding-finish-failed", lightToo: true)

        let noAccess = Probes(); noAccess.apple = true
        let noAccessState = await state { $0.briefGenerationState = .noNewMessages }
        let access = try await finishModel(noAccess, appState: noAccessState)
        access.startBuilding()
        noAccessState.briefGenerationState = .summarizing; access.tick()
        noAccessState.briefGenerationState = .noNewMessages; access.tick()
        try screen(access, name: "onboarding-finish-failed-access")

        // Ready: the digest exists and was created after the build started.
        let seedDB = try AppDatabase(inMemory: true)
        try DemoSeeder.seed(into: seedDB, activateDemoMode: false, now: SnapshotClock.anchor)
        let readyState = AppState(database: seedDB, llmClient: UnconfiguredLLMClient(), llmModel: "x",
                                  isLLMConfigured: true, basePrompt: "")
        await readyState.refreshBriefs().value
        let past = Probes(); past.apple = true; past.fda = true
        past.now = SnapshotClock.anchor.addingTimeInterval(-7200)
        let done = try await finishModel(past, appState: readyState)
        done.startBuilding()
        past.now = SnapshotClock.anchor
        done.tick()
        XCTAssertEqual(done.digestStatus, .ready)
        try screen(done, name: "onboarding-finish-done")

        let paused = try makeModel(Probes(), startAt: .ai).0
        paused.decideAILater()
        paused.startBuilding()
        XCTAssertEqual(paused.digestStatus, .paused)
        try screen(paused, name: "onboarding-finish-paused")
    }

    func testMainWindowWithSampleDataRibbon() async throws {
        let db = try AppDatabase(inMemory: true)
        try DemoSeeder.seed(into: db, now: SnapshotClock.anchor)
        let state = AppState(database: db, llmClient: UnconfiguredLLMClient(), llmModel: "demo",
                             isLLMConfigured: false, basePrompt: "")
        await state.refreshBriefs().value
        state.selectedBriefID = try BriefRepository(database: db).latestBriefID()
        // refreshBriefs() returns before the owed-reply / action / task reloads it
        // starts have finished; the real app has them by the time anyone looks.
        state.refreshTasks()
        for _ in 0..<60 where state.attentionProjection.actItems.count < 5 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let chat = state.makeChatViewModel()
        let view = ContentView().environmentObject(state).environmentObject(chat)
        let window = NSSize(width: 1180, height: 780)
        try render(view, size: window, name: "onboarding-demo-ribbon")
        try render(view, size: window, name: "onboarding-demo-ribbon", light: true)
    }

    func testMenuBarHintAndGlyph() throws {
        try render(MenuBarLocationNote().padding(24), size: NSSize(width: 540, height: 90), name: "onboarding-menubar-note")
    }
}
