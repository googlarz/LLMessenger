// LLMessengerTests/OnboardingModelTests.swift
//
// First-run logic, tested through injected probes. Nothing here touches real
// permissions, Ollama, the Keychain, or the user's defaults.
import XCTest
import AppKit
@testable import LLMessenger

/// Scriptable stand-in for the machine the wizard runs on.
final class Probes {
    var fda = false
    var apple = false
    var ollama: [String]?
    var whatsApp = false
    var inApplications = true
    var now = Date(timeIntervalSince1970: 1_000_000)
    var calls: [String] = []
    var applied: [Bool] = []

    var environment: OnboardingEnvironment {
        OnboardingEnvironment(
            fullDiskAccessGranted: { self.fda },
            appleIntelligenceAvailable: { self.apple },
            ollamaModels: { self.ollama },
            whatsAppDesktopInstalled: { self.whatsApp },
            appIsInApplicationsFolder: { self.inApplications },
            openPrivacySettings: { self.calls.append("privacy") },
            revealAppInFinder: { self.calls.append("reveal") },
            quitAndReopen: { self.calls.append("relaunch") },
            requestNotifications: { self.calls.append("notifications") },
            openURL: { self.calls.append("open:\($0.absoluteString)") },
            applyChanges: { self.applied.append($0) },
            now: { self.now }
        )
    }
}

@MainActor
final class OnboardingModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "com.llmessenger.onboarding-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        UserDefaults.standard.removeObject(forKey: DemoSeeder.demoFlagKey)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeObject(forKey: DemoSeeder.demoFlagKey)
    }

    private func makeModel(_ probes: Probes, startAt: OnboardingStep = .welcome,
                           db: AppDatabase? = nil) throws -> (OnboardingModel, AppDatabase) {
        let database = try db ?? AppDatabase(inMemory: true)
        let settings = SettingsRepository(keychainStore: KeychainStore(service: "test.\(suiteName)"),
                                          database: database, userDefaults: defaults)
        let model = OnboardingModel(database: database, environment: probes.environment,
                                    startAt: startAt, defaults: defaults, settings: settings)
        return (model, database)
    }

    // MARK: AI default selection

    func testAppleIntelligenceIsChosenWhenAvailable() async throws {
        let probes = Probes(); probes.apple = true
        let (model, _) = try makeModel(probes, startAt: .ai)
        await model.refreshAIDetection()
        XCTAssertEqual(model.aiChoice, .appleIntelligence)
        XCTAssertEqual(model.aiViewMode, .apple)
    }

    func testRunningOllamaWithModelsIsChosenWhenNoAppleIntelligence() async throws {
        let probes = Probes(); probes.ollama = ["llama3.1", "qwen2.5"]
        let (model, _) = try makeModel(probes, startAt: .ai)
        await model.refreshAIDetection()
        XCTAssertEqual(model.aiChoice, .ollama(model: "llama3.1"))
        XCTAssertEqual(model.aiViewMode, .ollama)
        model.chooseOllamaModel("qwen2.5")
        await model.refreshAIDetection()
        XCTAssertEqual(model.aiChoice, .ollama(model: "qwen2.5"), "A later probe must not override the user's pick")
    }

    func testNothingAvailableNeverPreselectsACloudProvider() async throws {
        let probes = Probes()
        let (model, _) = try makeModel(probes, startAt: .ai)
        await model.refreshAIDetection()
        XCTAssertNil(model.aiChoice)
        XCTAssertEqual(model.aiViewMode, .options)
        XCTAssertFalse(model.canUseCloud, "Cloud needs a key the user typed")
        model.useCloud()
        XCTAssertNil(model.aiChoice)
        XCTAssertEqual(model.step, .ai, "Cloud without a key must not advance")
    }

    /// Re-running setup on a Mac that already uses a cloud model must start from that
    /// choice, not replace it with the auto-detected local one.
    func testRerunningSetupKeepsAnExistingCloudChoice() async throws {
        defaults.set(LLMProvider.anthropic.rawValue, forKey: "selected_llm_provider")
        let probes = Probes(); probes.apple = true; probes.ollama = ["llama3.2"]
        let (model, _) = try makeModel(probes, startAt: .ai)
        await model.refreshAIDetection()

        XCTAssertEqual(model.aiChoice, .cloud(.anthropic), "detection must not override the earlier choice")
        XCTAssertEqual(model.aiViewMode, .current)
        XCTAssertEqual(model.cloudProvider, .anthropic)

        model.useAutomaticAI()
        XCTAssertEqual(model.aiChoice, .cloud(.anthropic))
        model.startBuilding()
        XCTAssertEqual(defaults.string(forKey: "selected_llm_provider"), LLMProvider.anthropic.rawValue,
                       "finishing setup without touching the AI step leaves the provider alone")
    }

    func testChoosingADifferentModelAfterAnExistingCloudChoiceStillWorks() async throws {
        defaults.set(LLMProvider.openai.rawValue, forKey: "selected_llm_provider")
        let probes = Probes(); probes.apple = true
        let (model, _) = try makeModel(probes, startAt: .ai)
        await model.refreshAIDetection()
        XCTAssertEqual(model.aiViewMode, .current)

        model.showAIAlternatives = true
        XCTAssertEqual(model.aiViewMode, .options)
        model.aiChoice = .appleIntelligence
        model.useAutomaticAI()
        model.startBuilding()

        XCTAssertEqual(defaults.string(forKey: "selected_llm_provider"), LLMProvider.appleIntelligence.rawValue)
    }

    func testFirstRunStillAutoPicksTheLocalModel() async throws {
        let probes = Probes(); probes.apple = true
        let (model, _) = try makeModel(probes, startAt: .ai)
        await model.refreshAIDetection()
        XCTAssertEqual(model.aiChoice, .appleIntelligence)
        XCTAssertEqual(model.aiViewMode, .apple)
    }

    func testOllamaStartedWhileWatchingIsPickedUp() async throws {
        let probes = Probes()
        let (model, _) = try makeModel(probes, startAt: .ai)
        await model.refreshAIDetection()
        XCTAssertEqual(model.aiViewMode, .options)
        probes.ollama = ["llama3.2"]
        await model.refreshAIDetection()
        XCTAssertEqual(model.aiViewMode, .ollama)
        XCTAssertEqual(model.aiChoice, .ollama(model: "llama3.2"))
    }

    func testRunningOllamaWithNoModelsIsNotAChoice() async throws {
        let probes = Probes(); probes.ollama = []
        let (model, _) = try makeModel(probes, startAt: .ai)
        await model.refreshAIDetection()
        XCTAssertNil(model.aiChoice)
        XCTAssertEqual(model.aiViewMode, .options)
    }

    func testDecideLaterCompletesWithoutAKey() async throws {
        let probes = Probes()
        let (model, _) = try makeModel(probes, startAt: .ai)
        await model.refreshAIDetection()
        model.decideAILater()
        XCTAssertEqual(model.step, .finish)
        model.startBuilding()
        XCTAssertEqual(model.digestStatus, .paused)
        XCTAssertEqual(probes.applied, [false], "Applies the saved choices but does not try to build")
        XCTAssertTrue(defaults.bool(forKey: OnboardingFlag.aiDecideLaterKey))
        XCTAssertNil(SettingsRepository(userDefaults: defaults).loadSelectedLLMProvider())
    }

    // MARK: Completion flag

    func testOnlyFinishSkipAndSampleDataMarkOnboardingComplete() {
        for (outcome, expected) in [(OnboardingOutcome.finished, true), (.skipped, true),
                                    (.demo, true), (.dismissed, false)] {
            let d = UserDefaults(suiteName: suiteName + outcome.hashValue.description)!
            OnboardingFlag.apply(outcome, to: d)
            XCTAssertEqual(d.bool(forKey: OnboardingFlag.completedKey), expected, "\(outcome)")
            d.removePersistentDomain(forName: suiteName + outcome.hashValue.description)
        }
    }

    func testClosingTheWindowMidwayReportsDismissedExactlyOnce() throws {
        let probes = Probes()
        let controller = OnboardingWindowController(database: try AppDatabase(inMemory: true),
                                                    environment: probes.environment, defaults: defaults)
        var outcomes: [OnboardingOutcome] = []
        controller.onFinish = { outcomes.append($0) }
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(outcomes, [.dismissed])
    }

    func testFinishingThroughTheWizardReportsFinishedNotDismissed() throws {
        let probes = Probes()
        let controller = OnboardingWindowController(database: try AppDatabase(inMemory: true),
                                                    environment: probes.environment, defaults: defaults)
        var outcomes: [OnboardingOutcome] = []
        controller.onFinish = { outcomes.append($0) }
        controller.model.finish()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(outcomes, [.finished])
    }

    func testSkipSetupReportsSkipped() throws {
        let (model, _) = try makeModel(Probes(), startAt: .services)
        var outcome: OnboardingOutcome?
        model.onFinish = { outcome = $0 }
        model.skipSetup()
        XCTAssertEqual(outcome, .skipped)
    }

    /// "Skip setup for now" from a wizard opened over the sample data: demo mode stays on
    /// (real adapters stay unregistered), setup counts as dealt with, and the main window
    /// says plainly that it is showing sample data. No silent half-state.
    func testSkippingSetupFromTheDemoLeavesTheAppClearlyInDemo() throws {
        let (demoModel, db) = try makeModel(Probes())
        demoModel.startDemo()
        XCTAssertTrue(DemoSeeder.isActive)

        let (wizard, _) = try makeModel(Probes(), startAt: .services, db: db)
        var outcome: OnboardingOutcome?
        wizard.onFinish = { outcome = $0 }
        wizard.skipSetup()
        let skipped = try XCTUnwrap(outcome)
        OnboardingFlag.apply(skipped, to: defaults)

        XCTAssertEqual(skipped, .skipped)
        XCTAssertTrue(defaults.bool(forKey: OnboardingFlag.completedKey))
        XCTAssertTrue(DemoSeeder.isActive, "skipping does not silently leave or wipe the demo")
        XCTAssertEqual(StatusRibbonKind.resolve(demoActive: DemoSeeder.isActive,
                                                setupUnfinished: !defaults.bool(forKey: OnboardingFlag.completedKey),
                                                needsAIChoice: true),
                       .sampleData, "the sample-data ribbon, with its set-up button, explains why nothing real is read")
        XCTAssertNotNil(try BriefRepository(database: db).latestBriefID(), "the sample digests are still there")
    }

    func testSampleMessagesSeedDemoAndReportDemo() throws {
        let (model, db) = try makeModel(Probes())
        var outcome: OnboardingOutcome?
        model.onFinish = { outcome = $0 }
        model.startDemo()
        XCTAssertEqual(outcome, .demo)
        XCTAssertTrue(DemoSeeder.isActive)
        XCTAssertNotNil(try BriefRepository(database: db).latestBriefID())
    }

    // MARK: Keychain explanation

    func testKeychainExplanationOnlyWhenThereIsSomethingToUnlock() {
        XCTAssertFalse(KeychainExplanation.shouldShow(hasSeen: false, hasStoredCredentials: false),
                       "Fresh install: nothing to unlock, so no alert")
        XCTAssertTrue(KeychainExplanation.shouldShow(hasSeen: false, hasStoredCredentials: true))
        XCTAssertFalse(KeychainExplanation.shouldShow(hasSeen: true, hasStoredCredentials: true))
        XCTAssertFalse(KeychainExplanation.shouldShow(hasSeen: true, hasStoredCredentials: false))
    }

    // MARK: Full Disk Access state machine

    func testAccessWaitingBecomesGranted() {
        var t = FullDiskAccessTracker()
        let start = Date(timeIntervalSince1970: 0)
        t.begin(at: start)
        t.update(granted: false, now: start.addingTimeInterval(2))
        XCTAssertEqual(t.status, .waiting)
        t.update(granted: true, now: start.addingTimeInterval(4))
        XCTAssertEqual(t.status, .granted)
        t.update(granted: false, now: start.addingTimeInterval(5))
        XCTAssertEqual(t.status, .granted, "Granted is sticky")
    }

    func testAccessNotRegisteringOffersRecoveryThirtySecondsAfterOpeningSettings() {
        var t = FullDiskAccessTracker()
        let start = Date(timeIntervalSince1970: 0)
        t.begin(at: start)
        t.settingsOpened(at: start.addingTimeInterval(5))
        t.update(granted: false, now: start.addingTimeInterval(34))
        XCTAssertEqual(t.status, .waiting)
        t.update(granted: false, now: start.addingTimeInterval(36))
        XCTAssertEqual(t.status, .needsHelp)
        t.update(granted: true, now: start.addingTimeInterval(60))
        XCTAssertEqual(t.status, .granted, "Recovery still resolves into granted")
    }

    func testAccessRecoveryAlsoAppearsIfTheUserNeverPressedTheButton() {
        var t = FullDiskAccessTracker()
        let start = Date(timeIntervalSince1970: 0)
        t.begin(at: start)
        t.update(granted: false, now: start.addingTimeInterval(60))
        XCTAssertEqual(t.status, .waiting)
        t.update(granted: false, now: start.addingTimeInterval(91))
        XCTAssertEqual(t.status, .needsHelp)
    }

    func testModelDrivesTheAccessTrackerFromProbes() throws {
        let probes = Probes()
        let (model, _) = try makeModel(probes, startAt: .services)
        model.continueFromServices()
        XCTAssertEqual(model.step, .access)
        XCTAssertEqual(model.access.status, .waiting)
        model.openPrivacySettings()
        XCTAssertEqual(probes.calls, ["privacy"])
        probes.now = probes.now.addingTimeInterval(31)
        model.tick()
        XCTAssertEqual(model.access.status, .needsHelp)
        probes.fda = true
        model.tick()
        XCTAssertEqual(model.access.status, .granted)
    }

    func testSkippingAccessContinuesWithoutIMessage() throws {
        let probes = Probes(); probes.whatsApp = true
        let (model, _) = try makeModel(probes, startAt: .services)
        model.toggleService("whatsapp")
        model.continueFromServices()
        model.skipAccess()
        XCTAssertEqual(model.step, .ai)
        XCTAssertTrue(model.selectedServices.isEmpty)
        XCTAssertFalse(model.needsAccess)
    }

    // MARK: Services list

    func testServiceCatalogueIsHonestAboutEachService() {
        let all = OnboardingService.catalog
        XCTAssertEqual(all.map(\.id), ["imessage", "whatsapp", "slack", "telegram", "signal"])
        XCTAssertEqual(OnboardingService.inWizardServices.map(\.id), ["imessage", "whatsapp"])
        XCTAssertEqual(OnboardingService.laterServices.map(\.id), ["slack", "telegram", "signal"])
        for later in OnboardingService.laterServices {
            XCTAssertTrue(later.effort.hasPrefix("Technical"), later.id)
            XCTAssertTrue(later.effort.contains("minutes"), "Each carries a rough time: \(later.id)")
        }
        XCTAssertTrue(all.first { $0.id == "whatsapp" }!.detail.contains("Read-only"))
        XCTAssertTrue(all.first { $0.id == "whatsapp" }!.detail.contains("WhatsApp Desktop"))
        XCTAssertTrue(all.first { $0.id == "signal" }!.detail.contains("signal-mcp"),
                      "The helper is named only alongside what it is")
        XCTAssertTrue(all.first { $0.id == "signal" }!.detail.contains("helper app"))
    }

    func testWhatsAppCannotBeSelectedUntilItsPrerequisiteIsDetected() throws {
        let probes = Probes()
        let (model, _) = try makeModel(probes, startAt: .services)
        model.toggleService("whatsapp")
        XCTAssertFalse(model.selectedServices.contains("whatsapp"))
        model.toggleService("slack")
        XCTAssertFalse(model.selectedServices.contains("slack"), "Later services have no inline setup")

        probes.whatsApp = true
        let (detected, _) = try makeModel(probes, startAt: .services)
        detected.toggleService("whatsapp")
        XCTAssertTrue(detected.selectedServices.contains("whatsapp"))
        XCTAssertEqual(detected.visibleSteps, [.services, .access, .ai, .finish])
    }

    func testAccessStepOnlyAppearsWhenAServiceNeedsIt() throws {
        let (model, _) = try makeModel(Probes(), startAt: .services)
        model.toggleService("imessage")
        XCTAssertFalse(model.canContinueFromServices)
        XCTAssertEqual(model.visibleSteps, [.services, .ai, .finish])
        model.toggleService("imessage")
        XCTAssertEqual(model.visibleSteps, [.services, .access, .ai, .finish])
    }

    // MARK: Navigation

    func testDotsOnlyGoBackAndNotAfterBuildingStarted() async throws {
        let probes = Probes(); probes.apple = true
        let (model, _) = try makeModel(probes, startAt: .services)
        model.continueFromServices()
        probes.fda = true; model.tick()
        model.continueFromAccess()
        await model.refreshAIDetection()
        model.useAutomaticAI()
        XCTAssertEqual(model.step, .finish)
        XCTAssertTrue(model.canJump(to: .services))
        XCTAssertTrue(model.canJump(to: .ai))
        XCTAssertFalse(model.canJump(to: .finish), "Not the current step")
        model.goBack()
        XCTAssertEqual(model.step, .ai)
        XCTAssertFalse(model.canJump(to: .finish), "Can't skip ahead")
        model.useAutomaticAI()
        model.startBuilding()
        XCTAssertFalse(model.canJump(to: .services), "Choices are saved once building starts")
    }

    // MARK: Building and persistence

    func testStartBuildingSavesServicesAndAIAndAsksTheAppToBuild() async throws {
        let probes = Probes(); probes.apple = true; probes.whatsApp = true
        let (model, db) = try makeModel(probes, startAt: .services)
        model.toggleService("whatsapp")
        model.continueFromServices()
        probes.fda = true; model.tick()
        model.continueFromAccess()
        await model.refreshAIDetection()
        model.useAutomaticAI()
        model.startBuilding()

        XCTAssertEqual(probes.applied, [true])
        let repo = SettingsRepository(keychainStore: KeychainStore(service: "test.\(suiteName)"),
                                      database: db, userDefaults: defaults)
        XCTAssertEqual(try repo.loadServiceConfig(for: "imessage")?.enabled, true)
        XCTAssertEqual(try repo.loadServiceConfig(for: "whatsapp")?.enabled, true)
        XCTAssertEqual(repo.loadSelectedLLMProvider(), .appleIntelligence)
        XCTAssertFalse(defaults.bool(forKey: OnboardingFlag.aiDecideLaterKey))
        XCTAssertEqual(model.digestStatus, .building(detail: "Reading your messages", slow: false))
        XCTAssertFalse(defaults.bool(forKey: OnboardingFlag.completedKey), "Building alone never completes onboarding")
    }

    func testOllamaChoiceSavesTheProviderAndModel() async throws {
        let probes = Probes(); probes.ollama = ["llama3.1", "qwen2.5"]
        let (model, db) = try makeModel(probes, startAt: .ai)
        await model.refreshAIDetection()
        model.chooseOllamaModel("qwen2.5")
        model.continueFromAI()
        model.startBuilding()
        let repo = SettingsRepository(keychainStore: KeychainStore(service: "test.\(suiteName)"),
                                      database: db, userDefaults: defaults)
        XCTAssertEqual(repo.loadSelectedLLMProvider(), .ollama)
        XCTAssertEqual(repo.loadOllamaModel(), "qwen2.5")
    }

    func testBuildingFromSampleDataRemovesTheSamplesFirst() async throws {
        let probes = Probes(); probes.apple = true
        let (model, db) = try makeModel(probes, startAt: .services)
        try DemoSeeder.seed(into: db)
        XCTAssertTrue(DemoSeeder.isActive)
        await model.refreshAIDetection()
        model.useAutomaticAI()
        model.startBuilding()
        XCTAssertFalse(DemoSeeder.isActive)
        XCTAssertNil(try BriefRepository(database: db).latestBriefID(),
                     "Sample digests must never be mistaken for the user's first digest")
        let repo = SettingsRepository(keychainStore: KeychainStore(service: "test.\(suiteName)"),
                                      database: db, userDefaults: defaults)
        XCTAssertEqual(try repo.loadServiceConfig(for: "imessage")?.enabled, true,
                       "The wizard's choices are saved after the wipe, not erased by it")
    }

    func testNotificationsAreOnlyRequestedWhenTheUserAsks() throws {
        let probes = Probes()
        let (model, _) = try makeModel(probes, startAt: .finish)
        XCTAssertTrue(probes.calls.isEmpty)
        model.requestNotifications()
        XCTAssertEqual(probes.calls, ["notifications"])
        XCTAssertTrue(model.notificationsRequested)
    }

    // MARK: First digest status

    private func inputs(_ mutate: (inout FirstDigestInputs) -> Void = { _ in }) -> FirstDigestInputs {
        var i = FirstDigestInputs(servicesEnabled: ["imessage"], aiDeferred: false, aiConfigured: true,
                                  digestsSinceStart: 0, generationState: .cached, sawActivity: false,
                                  lastError: nil, accessMissing: false, elapsed: 5)
        mutate(&i)
        return i
    }

    func testFirstDigestStatusTellsTheTruth() {
        XCTAssertEqual(FirstDigestStatus.resolve(inputs { $0.digestsSinceStart = 1 }), .ready)
        XCTAssertEqual(FirstDigestStatus.resolve(inputs { $0.servicesEnabled = [] }), .nothingConnected)
        XCTAssertEqual(FirstDigestStatus.resolve(inputs { $0.aiDeferred = true }), .paused)
        XCTAssertEqual(FirstDigestStatus.resolve(inputs { $0.generationState = .fetching; $0.sawActivity = true }),
                       .building(detail: "Reading your messages", slow: false))
        XCTAssertEqual(FirstDigestStatus.resolve(inputs { $0.generationState = .summarizing; $0.sawActivity = true; $0.elapsed = 200 }),
                       .building(detail: "Writing your digest", slow: true))
        if case .failed(_, let fix) = FirstDigestStatus.resolve(inputs { $0.aiConfigured = false }) {
            XCTAssertEqual(fix, .chooseAI)
        } else { XCTFail("Missing AI must be a failure with a fix") }
        if case .failed(let message, let fix) = FirstDigestStatus.resolve(inputs {
            $0.generationState = .failed; $0.lastError = "Ollama isn't running" }) {
            XCTAssertEqual(fix, .retry); XCTAssertEqual(message, "Ollama isn't running")
        } else { XCTFail("A failed build must surface the error") }
        if case .failed(_, let fix) = FirstDigestStatus.resolve(inputs {
            $0.generationState = .noNewMessages; $0.sawActivity = true; $0.accessMissing = true }) {
            XCTAssertEqual(fix, .fixAccess)
        } else { XCTFail("Finishing empty without access must point at access") }
        XCTAssertEqual(FirstDigestStatus.resolve(inputs { $0.generationState = .noNewMessages; $0.sawActivity = true }),
                       .noMessages)
    }

    func testStaleNoNewMessagesBeforeAnyBuildActivityIsNotReportedAsEmpty() {
        XCTAssertEqual(FirstDigestStatus.resolve(inputs { $0.generationState = .noNewMessages; $0.sawActivity = false }),
                       .building(detail: "Reading your messages", slow: false))
    }

    // MARK: Ribbon

    func testRibbonFollowsDemoState() throws {
        XCTAssertNil(StatusRibbonKind.resolve(demoActive: DemoSeeder.isActive, setupUnfinished: false, needsAIChoice: false))
        let db = try AppDatabase(inMemory: true)
        try DemoSeeder.seed(into: db)
        XCTAssertEqual(StatusRibbonKind.resolve(demoActive: DemoSeeder.isActive, setupUnfinished: false, needsAIChoice: false),
                       .sampleData)
        try DemoSeeder.wipe(from: db)
        XCTAssertNil(StatusRibbonKind.resolve(demoActive: DemoSeeder.isActive, setupUnfinished: false, needsAIChoice: false))
    }

    func testRibbonPriorityAndCopy() {
        XCTAssertEqual(StatusRibbonKind.resolve(demoActive: true, setupUnfinished: true, needsAIChoice: true), .sampleData)
        XCTAssertEqual(StatusRibbonKind.resolve(demoActive: false, setupUnfinished: true, needsAIChoice: true), .setupUnfinished)
        XCTAssertEqual(StatusRibbonKind.resolve(demoActive: false, setupUnfinished: false, needsAIChoice: true), .needsAI)
        XCTAssertEqual(StatusRibbonKind.sampleData.message, "Sample data \u{2014} these aren\u{2019}t your messages.")
        XCTAssertEqual(StatusRibbonKind.sampleData.buttonTitle, "Set up with my messages")
    }
}
