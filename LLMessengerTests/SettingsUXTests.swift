// LLMessengerTests/SettingsUXTests.swift
//
// Logic behind the Settings usability pass: persistence that must not lie, drafts that
// must not be lost, and the plain-language text that follows real state. Purely visual
// wording (layout, spacing) has no test; see SettingsSnapshotTests for the rendered check.

import XCTest
import GRDB
@testable import LLMessenger

// MARK: - Shared fixtures

@MainActor
private final class SettingsFixture {
    let suiteName = "SettingsUXTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let keychain: KeychainStore
    let prefix = "_ux_\(UUID().uuidString.prefix(8))_"
    let center = NotificationCenter()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        keychain = KeychainStore(service: "LLMessengerSettingsUXTests-\(UUID().uuidString)", account: "credentials")
    }

    func repo(database: AppDatabase? = nil) -> SettingsRepository {
        SettingsRepository(keychainStore: keychain, keyPrefix: prefix, database: database, userDefaults: defaults)
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        keychain.deleteStore()
    }
}

// MARK: - Update check switch

@MainActor
final class UpdateCheckSettingTests: XCTestCase {
    private var fx: SettingsFixture!
    override func setUp() async throws { fx = SettingsFixture() }
    override func tearDown() async throws { fx.tearDown() }

    private final class FailingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }

    private func makeChecker() -> UpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingProtocol.self]
        return UpdateChecker(session: URLSession(configuration: config), currentVersion: "1.0.0", defaults: fx.defaults)
    }

    func testChecksAreOnByDefault() {
        XCTAssertTrue(fx.repo().loadUpdateChecksEnabled())
    }

    func testToggleUsesTheSameKeyTheCheckerReads() {
        fx.repo().saveUpdateChecksEnabled(false)
        XCTAssertTrue(fx.defaults.bool(forKey: UpdateChecker.optOutKey))
        XCTAssertFalse(fx.repo().loadUpdateChecksEnabled())
        fx.repo().saveUpdateChecksEnabled(true)
        XCTAssertNil(fx.defaults.object(forKey: UpdateChecker.optOutKey), "turning it back on removes the key")
        XCTAssertTrue(fx.repo().loadUpdateChecksEnabled())
    }

    func testCheckerHonoursTheSwitchImmediatelyAndMakesNoRequest() {
        let checker = makeChecker()
        fx.repo().saveUpdateChecksEnabled(false)
        XCTAssertFalse(checker.checkIfDue(), "switched off: no check starts")
        XCTAssertNil(fx.defaults.object(forKey: "lastUpdateCheckDate"), "and no request was made")
    }

    func testCheckerRunsOncePerDayWhenOn() async throws {
        let checker = makeChecker()
        XCTAssertTrue(checker.checkIfDue())
        for _ in 0..<100 where fx.defaults.object(forKey: "lastUpdateCheckDate") == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(fx.defaults.object(forKey: "lastUpdateCheckDate"))
        XCTAssertFalse(checker.checkIfDue(), "a second call within a day does nothing")
    }

    func testDataFlowClaimsNameTheUpdateCheckAndMCP() {
        XCTAssertTrue(PrivacyCopy.noTelemetry.contains("GitHub"))
        XCTAssertFalse(PrivacyCopy.noTelemetry.lowercased().contains("does not call home"))
        XCTAssertTrue(PrivacyCopy.cloudEgress.contains("MCP"))
    }
}

// MARK: - Services pane

@MainActor
final class ServiceSettingsModelTests: XCTestCase {
    private var fx: SettingsFixture!
    override func setUp() async throws { fx = SettingsFixture() }
    override func tearDown() async throws { fx.tearDown() }

    private func makeModel(withDatabase: Bool = true) throws -> (ServiceSettingsModel, SettingsRepository) {
        let db = withDatabase ? try AppDatabase(inMemory: true) : nil
        let repo = fx.repo(database: db)
        return (ServiceSettingsModel(repo: repo, center: fx.center), repo)
    }

    func testEnableToggleSavesAtOnceAndTellsTheApp() throws {
        let (model, repo) = try makeModel()
        var notified = 0
        let token = fx.center.addObserver(forName: .serviceConfigDidChange, object: nil, queue: nil) { _ in notified += 1 }
        defer { fx.center.removeObserver(token) }

        model.reload()
        XCTAssertFalse(model.config(for: "whatsapp").enabled, "WhatsApp is opt-in")
        model.setEnabled(true, for: "whatsapp")

        XCTAssertTrue(model.config(for: "whatsapp").enabled)
        XCTAssertEqual(try repo.loadServiceConfig(for: "whatsapp")?.enabled, true, "written without pressing Save")
        XCTAssertEqual(notified, 1, "the polling engine is told to re-arm")
        XCTAssertEqual(model.status, .saved)
    }

    func testPollIntervalAlsoSavesAtOnce() throws {
        let (model, repo) = try makeModel()
        model.reload()
        var config = model.config(for: "signal")
        config.pollIntervalSeconds = 1800
        model.update(config)
        XCTAssertEqual(try repo.loadServiceConfig(for: "signal")?.pollIntervalSeconds, 1800)
    }

    func testUnchangedConfigIsNotSavedOrAnnounced() throws {
        let (model, _) = try makeModel()
        var notified = 0
        let token = fx.center.addObserver(forName: .serviceConfigDidChange, object: nil, queue: nil) { _ in notified += 1 }
        defer { fx.center.removeObserver(token) }
        model.reload()
        model.update(model.config(for: "slack"))
        XCTAssertEqual(notified, 0)
        XCTAssertEqual(model.status, .idle)
    }

    func testFailedSaveRevertsTheToggleInsteadOfLying() throws {
        let (model, _) = try makeModel(withDatabase: false)   // saving a config throws
        XCTAssertTrue(model.config(for: "imessage").enabled)
        model.setEnabled(false, for: "imessage")
        XCTAssertTrue(model.config(for: "imessage").enabled, "the switch goes back to what is stored")
        guard case .error(let message) = model.status else { return XCTFail("expected an error status") }
        XCTAssertTrue(message.contains("iMessage"))
    }

    func testCredentialEditsAreUnsavedUntilSaved() throws {
        let (model, repo) = try makeModel()
        model.reload()
        XCTAssertFalse(model.hasUnsavedCredentials)
        model.credentials.signalAccount = "+4915112345678"
        XCTAssertTrue(model.hasUnsavedCredentials)
        XCTAssertNil(try repo.loadSignalAccount(), "nothing stored yet")

        model.saveCredentials()
        XCTAssertFalse(model.hasUnsavedCredentials)
        XCTAssertEqual(try repo.loadSignalAccount(), "+4915112345678")
    }

    func testBackgroundReloadNeverWipesUnsavedCredentials() throws {
        let (model, _) = try makeModel()
        model.reload()
        model.credentials.telegramApiId = "12345"
        model.reload()   // e.g. a health update arrived while the user was typing
        XCTAssertEqual(model.credentials.telegramApiId, "12345")
        XCTAssertTrue(model.hasUnsavedCredentials)
    }

    func testDiscardRestoresStoredCredentials() throws {
        let (model, repo) = try makeModel()
        try repo.saveSignalAccount("+111")
        model.reload()
        model.credentials.signalAccount = "+999"
        model.discardCredentials()
        XCTAssertEqual(model.credentials.signalAccount, "+111")
        XCTAssertFalse(model.hasUnsavedCredentials)
    }

    func testReloadPicksUpStoredCredentialsWhenThereAreNoEdits() throws {
        let (model, repo) = try makeModel()
        model.reload()
        try repo.saveSignalAccount("+222")
        model.reload()
        XCTAssertEqual(model.credentials.signalAccount, "+222")
    }
}

// MARK: - AI tab

@MainActor
final class AISettingsModelTests: XCTestCase {
    private var fx: SettingsFixture!
    override func setUp() async throws { fx = SettingsFixture() }
    override func tearDown() async throws { fx.tearDown() }

    func testTypedKeyIsKeptWhenTheTabIsRebuilt() {
        let model = AISettingsModel(repo: fx.repo(), center: fx.center)
        model.load()
        model.values.anthropicKey = "sk-ant-typed"
        XCTAssertTrue(model.isDirty)
        model.load()   // the tab calls this from onAppear after a sub-tab switch
        XCTAssertEqual(model.values.anthropicKey, "sk-ant-typed", "an appearing tab must not discard the edit")
    }

    func testNothingTakesEffectUntilSave() throws {
        let repo = fx.repo()
        let model = AISettingsModel(repo: repo, center: fx.center)
        model.values.selectedProviderRaw = LLMProvider.anthropic.rawValue
        model.values.anthropicKey = "sk-ant-typed"
        XCTAssertNil(repo.loadSelectedLLMProvider(), "choosing a cloud provider is not saved on the way out")
        XCTAssertNil(try repo.loadLLMKey(provider: .anthropic))

        var providerNotified = false
        let token = fx.center.addObserver(forName: .llmProviderDidChange, object: nil, queue: nil) { _ in providerNotified = true }
        defer { fx.center.removeObserver(token) }
        model.save()

        XCTAssertEqual(repo.loadSelectedLLMProvider(), .anthropic)
        XCTAssertEqual(try repo.loadLLMKey(provider: .anthropic), "sk-ant-typed")
        XCTAssertTrue(providerNotified)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.status, .saved)
    }

    func testDiscardGoesBackToWhatIsStored() throws {
        let repo = fx.repo()
        try repo.saveLLMKey(provider: .openai, key: "sk-stored")
        let model = AISettingsModel(repo: repo, center: fx.center)
        model.load()
        model.values.openAIKey = "sk-changed"
        model.discard()
        XCTAssertEqual(model.values.openAIKey, "sk-stored")
        XCTAssertFalse(model.isDirty)
    }

    func testCloudConsentCannotStayOnForALocalProvider() {
        let repo = fx.repo()
        let model = AISettingsModel(repo: repo, center: fx.center)
        model.values.selectedProviderRaw = LLMProvider.ollama.rawValue
        model.values.cloudAutoBriefsConsent = true
        model.save()
        XCTAssertFalse(repo.loadCloudAutoBriefsConsent())
        XCTAssertFalse(model.values.cloudAutoBriefsConsent, "the switch shows what was stored")
        XCTAssertFalse(model.isDirty)
    }

    func testCloudNoticeNamesTheProviderAndOnlyForCloud() {
        XCTAssertEqual(AIProviderDisclosure.cloudNotice(for: .anthropic),
                       "Message content will be sent to Anthropic to build digests and drafts.")
        XCTAssertEqual(AIProviderDisclosure.cloudNotice(for: .openai),
                       "Message content will be sent to OpenAI to build digests and drafts.")
        XCTAssertNil(AIProviderDisclosure.cloudNotice(for: .ollama))
        XCTAssertNil(AIProviderDisclosure.cloudNotice(for: nil))
    }

    func testTrimmedRunsLabelSaysWhatItMeans() {
        XCTAssertEqual(LLMUsageLabel.trimmedRuns(1), "1 run trimmed to fit")
        XCTAssertEqual(LLMUsageLabel.trimmedRuns(4), "4 runs trimmed to fit")
    }
}

// MARK: - Writing & Appearance tab

@MainActor
final class InstructionsSettingsModelTests: XCTestCase {
    private var fx: SettingsFixture!
    override func setUp() async throws { fx = SettingsFixture() }
    override func tearDown() async throws { fx.tearDown() }

    func testThemeSavesAndAppliesAtOnce() {
        var applied: [String] = []
        let model = InstructionsSettingsModel(repo: fx.repo(), applyAppearance: { applied.append($0) })
        model.setTheme("dark")
        XCTAssertEqual(fx.repo().loadTheme(), "dark")
        XCTAssertEqual(applied, ["dark"])
        XCTAssertFalse(model.isDirty, "theme has no draft state")
    }

    func testPromptAndLanguageWaitForSaveAndSurviveReload() {
        let repo = fx.repo()
        let model = InstructionsSettingsModel(repo: repo, applyAppearance: { _ in })
        model.values.briefLanguage = "Polish"
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(repo.loadBriefLanguage(), "English", "not stored yet")
        model.load()
        XCTAssertEqual(model.values.briefLanguage, "Polish", "reload keeps the edit")
        model.save()
        XCTAssertEqual(repo.loadBriefLanguage(), "Polish")
        XCTAssertFalse(model.isDirty)
    }

    func testDiscardRestoresSavedValues() {
        let model = InstructionsSettingsModel(repo: fx.repo(), applyAppearance: { _ in })
        let original = model.values.prompt
        model.values.prompt = "something else"
        model.discard()
        XCTAssertEqual(model.values.prompt, original)
    }

    func testEachControlStatesWhenItTakesEffect() {
        XCTAssertTrue(InstructionsCopy.promptTiming.contains("next time LLMessenger starts"))
        XCTAssertFalse(InstructionsCopy.themeTiming.contains("launch"))
        XCTAssertTrue(InstructionsCopy.languageTiming.contains("next one"))
    }
}

// MARK: - Launch at login

@MainActor
final class LaunchAtLoginModelTests: XCTestCase {
    private struct Boom: LocalizedError { var errorDescription: String? { "macOS said no" } }

    func testFailureShowsTheErrorAndTheRealState() {
        var real = LaunchAtLoginStatus.disabled
        let model = LaunchAtLoginModel(readStatus: { real }, write: { _ in throw Boom() })
        model.set(true)
        XCTAssertFalse(model.isOn, "the switch reflects what macOS reports, not what was asked")
        XCTAssertEqual(model.errorMessage, "Couldn't turn on Launch at login: macOS said no")
        real = .enabled
        model.refresh()
        XCTAssertTrue(model.isOn)
    }

    func testSuccessClearsTheError() {
        var real = LaunchAtLoginStatus.disabled
        var shouldFail = true
        let model = LaunchAtLoginModel(readStatus: { real }, write: { on in
            if shouldFail { throw Boom() }
            real = on ? .enabled : .disabled
        })
        model.set(true)
        XCTAssertNotNil(model.errorMessage)
        shouldFail = false
        model.set(true)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isOn)
        model.set(false)
        XCTAssertFalse(model.isOn)
    }

    func testWaitingForApprovalIsShownAsPending() {
        let model = LaunchAtLoginModel(readStatus: { .requiresApproval }, write: { _ in })
        model.set(true)
        XCTAssertTrue(model.needsApproval)
        XCTAssertTrue(model.isOn)
        XCTAssertNil(model.errorMessage)
    }
}

// MARK: - MCP switch and setup

@MainActor
final class MCPAccessModelTests: XCTestCase {
    private var fx: SettingsFixture!
    override func setUp() async throws { fx = SettingsFixture() }
    override func tearDown() async throws { fx.tearDown() }

    func testTurningOnNeedsConfirmationAndStoresNothingBeforeIt() {
        let repo = fx.repo()
        let model = MCPAccessModel(repo: repo)
        XCTAssertEqual(model.phase, .off)
        model.setSwitch(true)
        XCTAssertEqual(model.phase, .confirming)
        XCTAssertTrue(model.switchIsOn, "the switch doesn't jump back while the confirmation is showing")
        XCTAssertFalse(repo.loadMCPServerEnabled(), "not enabled yet")
        XCTAssertNil(repo.loadMCPServerEnabledSince())

        model.confirmEnable()
        XCTAssertEqual(model.phase, .on)
        XCTAssertTrue(repo.loadMCPServerEnabled())
        XCTAssertNotNil(repo.loadMCPServerEnabledSince())
    }

    func testCancelLeavesItOff() {
        let repo = fx.repo()
        let model = MCPAccessModel(repo: repo)
        model.setSwitch(true)
        model.cancelEnable()
        XCTAssertEqual(model.phase, .off)
        XCTAssertFalse(repo.loadMCPServerEnabled())
    }

    func testSwitchingOffAfterConfirmingAlsoCancels() {
        let model = MCPAccessModel(repo: fx.repo())
        model.setSwitch(true)
        model.setSwitch(false)
        XCTAssertEqual(model.phase, .off)
    }

    func testTurningOffNeedsNoConfirmationAndClearsTheTimestamp() {
        let repo = fx.repo()
        repo.saveMCPServerEnabled(true)
        let model = MCPAccessModel(repo: repo)
        XCTAssertEqual(model.phase, .on)
        model.setSwitch(false)
        XCTAssertFalse(repo.loadMCPServerEnabled())
        XCTAssertNil(repo.loadMCPServerEnabledSince())
    }

    func testConfirmationExplainsTheConsequences() {
        let text = MCPCopy.confirmationPoints.joined(separator: " ")
        XCTAssertTrue(text.contains("cloud AI model"))
        XCTAssertTrue(text.contains("Local-only"))
        XCTAssertTrue(text.contains("left out of new digests"))
        XCTAssertTrue(text.contains("approve"))
    }

    func testClientConfigIsValidJSONWithTheExecutablePath() throws {
        let path = "/Applications/LLM Messenger.app/Contents/MacOS/LLMessenger"
        let json = MCPSetup.configJSON(executablePath: path)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers["llmessenger"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, path)
        XCTAssertEqual(entry["args"] as? [String], ["--mcp"])
    }

    func testClaudeCodeCommandSurvivesSpacesAndQuotesInThePath() throws {
        for path in ["/Applications/LLMessenger.app/Contents/MacOS/LLMessenger",
                     "/Users/me/My Apps/LLMessenger",
                     "/Users/o'brien/LLMessenger; touch /tmp/pwned"] {
            let command = MCPSetup.claudeCodeCommand(executablePath: path)
            XCTAssertTrue(command.hasPrefix("claude mcp add --scope user llmessenger -- "))
            XCTAssertTrue(command.hasSuffix(" --mcp"))
            // Ask a real shell what the quoted word expands to: it must be the path, untouched.
            let quoted = MCPSetup.shellQuoted(path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' \(quoted)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            XCTAssertEqual(out, path)
        }
    }
}

// MARK: - Priority rules

@MainActor
final class PriorityRuleSettingsTests: XCTestCase {

    private func rule(_ id: Int64?, contact: String? = nil, sortOrder: Int = 0,
                      created: TimeInterval = 0, alwaysNotify: Bool = false, suppress: Bool = false,
                      quiet: (String, String)? = nil) -> PriorityRule {
        PriorityRule(id: id, contactPattern: contact, keywordPattern: nil, service: nil, setPriority: nil,
                     suppress: suppress, alwaysNotify: alwaysNotify, sortOrder: sortOrder,
                     createdAt: Date(timeIntervalSince1970: created),
                     quietStart: quiet?.0, quietEnd: quiet?.1)
    }

    func testQuietHoursParsingRejectsWhatTheEvaluatorWouldIgnore() {
        XCTAssertEqual(QuietHours.minutes(from: "22:00"), 1320)
        XCTAssertEqual(QuietHours.minutes(from: "06:30"), 390)
        for bad in ["10pm", "24:00", "12:60", "", "7", "07:00:00", "-1:00", "aa:bb"] {
            XCTAssertNil(QuietHours.minutes(from: bad), bad)
        }
        XCTAssertEqual(QuietHours.string(fromMinutes: 390), "06:30")
    }

    func testPickerDatesRoundTripToStoredStrings() {
        let date = QuietHours.date(fromMinutes: 22 * 60 + 15)
        XCTAssertEqual(QuietHours.string(from: date), "22:15")
    }

    func testEqualStartAndEndIsRejectedBecauseTheEvaluatorReadsItAsAllDay() {
        XCTAssertNotNil(QuietHours.problem(start: "08:00", end: "08:00"))
        XCTAssertNil(QuietHours.problem(start: "22:00", end: "06:00"), "overnight windows are fine")
        // Why it is rejected: a same-time window would silence an Always-notify rule at every hour.
        let r = rule(1, alwaysNotify: true, quiet: ("08:00", "08:00"))
        for hour in [3, 12, 20] {
            let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
            XCTAssertNil(RuleEvaluator.evaluate(contactName: "x", service: nil, messageText: "x", rules: [r], at: date))
        }
    }

    func testQuietHoursOnlyApplyToAlwaysNotifyRules() {
        let start = QuietHours.date(fromMinutes: 22 * 60)
        let end = QuietHours.date(fromMinutes: 6 * 60)
        XCTAssertNil(RuleDraftValidation.quietWindow(alwaysNotify: false, enabled: true, start: start, end: end),
                     "hours that can do nothing are not stored")
        XCTAssertFalse(RuleDraftValidation.quietHoursApplicable(alwaysNotify: false))
        XCTAssertNil(RuleDraftValidation.quietWindow(alwaysNotify: true, enabled: false, start: start, end: end))
        let window = RuleDraftValidation.quietWindow(alwaysNotify: true, enabled: true, start: start, end: end)
        XCTAssertEqual(window?.start, "22:00")
        XCTAssertEqual(window?.end, "06:00")
        XCTAssertNil(RuleDraftValidation.quietHoursProblem(alwaysNotify: true, enabled: true, start: start, end: end))
        XCTAssertNotNil(RuleDraftValidation.quietHoursProblem(alwaysNotify: true, enabled: true, start: start, end: start))
        XCTAssertNil(RuleDraftValidation.quietHoursProblem(alwaysNotify: false, enabled: true, start: start, end: start),
                     "an inapplicable window can't block saving")
    }

    func testSummaryShowsQuietHoursOnlyWhenTheyChangeTheRule() {
        let withNotify = PriorityRuleCopy.summary(for: rule(1, alwaysNotify: true, quiet: ("22:00", "06:00")))
        XCTAssertTrue(withNotify.contains("skipped 22:00–06:00"))
        let without = PriorityRuleCopy.summary(for: rule(2, suppress: true, quiet: ("22:00", "06:00")))
        XCTAssertFalse(without.contains("22:00"))
    }

    func testNewRulesGoToTheBottomAndLegacyTiesKeepCreationOrder() {
        let legacy = [rule(1, contact: "a", created: 30), rule(2, contact: "b", created: 10), rule(3, contact: "c", created: 20)]
        XCTAssertEqual(PriorityRuleOrdering.normalised(legacy).map(\.id), [2, 3, 1])
        XCTAssertEqual(PriorityRuleOrdering.normalised(legacy).map(\.sortOrder), [0, 1, 2])
        XCTAssertEqual(PriorityRuleOrdering.nextSortOrder(after: legacy), 1)
        XCTAssertEqual(PriorityRuleOrdering.nextSortOrder(after: []), 0)
    }

    func testMovingClampsAtTheEnds() {
        let list = [rule(1, sortOrder: 0), rule(2, sortOrder: 1), rule(3, sortOrder: 2)]
        XCTAssertEqual(PriorityRuleOrdering.moving(list, id: 3, by: -1).map(\.id), [1, 3, 2])
        XCTAssertEqual(PriorityRuleOrdering.moving(list, id: 1, by: -1).map(\.id), [1, 2, 3])
        XCTAssertEqual(PriorityRuleOrdering.moving(list, id: 3, by: 1).map(\.id), [1, 2, 3])
        XCTAssertEqual(PriorityRuleOrdering.moving(list, id: 1, by: 5).map(\.id), [2, 3, 1])
    }

    func testStorePersistsOrderAndEditsAcrossReloads() async throws {
        let store = PriorityRuleStore(database: try AppDatabase(inMemory: true))
        try await store.add(rule(nil, contact: "boss", created: 1))
        try await store.add(rule(nil, contact: "mum", created: 2))
        try await store.add(rule(nil, contact: "bank", created: 3))
        var rules = try await store.loadAll()
        XCTAssertEqual(rules.map(\.contactPattern), ["boss", "mum", "bank"])
        XCTAssertEqual(rules.map(\.sortOrder), [0, 1, 2], "each rule is saved with its own place, not 0")

        let bankID = try XCTUnwrap(rules[2].id)
        try await store.move(id: bankID, by: -2)
        rules = try await store.loadAll()
        XCTAssertEqual(rules.map(\.contactPattern), ["bank", "boss", "mum"])

        var edited = rules[1]
        edited.contactPattern = "boss (work)"
        try await store.update(edited)
        rules = try await store.loadAll()
        XCTAssertEqual(rules.map(\.contactPattern), ["bank", "boss (work)", "mum"], "edit keeps the rule's place")

        try await store.delete(id: bankID)
        rules = try await store.loadAll()
        XCTAssertEqual(rules.map(\.contactPattern), ["boss (work)", "mum"])
    }

    func testReorderingChangesWhichRuleWins() async throws {
        let store = PriorityRuleStore(database: try AppDatabase(inMemory: true))
        var quiet = rule(nil, contact: "anna", suppress: true)
        quiet.keywordPattern = nil
        try await store.add(quiet)
        var urgent = rule(nil, contact: "anna")
        urgent.setPriority = "high"
        try await store.add(urgent)

        var rules = try await store.loadAll()
        var match = RuleEvaluator.evaluate(contactName: "Anna", service: nil, messageText: "hi", rules: rules)
        guard case .suppress = match?.action else { return XCTFail("first rule wins: suppress") }

        try await store.move(id: try XCTUnwrap(rules[1].id), by: -1)
        rules = try await store.loadAll()
        match = RuleEvaluator.evaluate(contactName: "Anna", service: nil, messageText: "hi", rules: rules)
        guard case .setPriority("high") = match?.action else { return XCTFail("after reordering the priority rule wins") }
    }

    func testPrecedenceNoteMatchesTheEvaluator() {
        XCTAssertTrue(PriorityRuleCopy.precedenceNote.contains("top to bottom"))
        XCTAssertTrue(PriorityRuleCopy.precedenceNote.contains("first rule that matches"))
        XCTAssertTrue(PriorityRuleCopy.actionPrecedenceNote.contains("Suppress wins over Always notify"))
    }
}

// MARK: - WhatsApp health

@MainActor
final class WhatsAppHealthPresentationTests: XCTestCase {

    private func health(_ status: String, _ error: String?) -> ServiceHealth {
        ServiceHealth(service: "whatsapp", status: status, lastCheck: Date(), lastError: error, retryAfter: nil)
    }

    func testEachAdapterMessageMapsBackToItsCause() {
        XCTAssertEqual(WhatsAppHealthIssue.classify(WhatsAppAdapter.notFoundReason), .notInstalled)
        XCTAssertEqual(WhatsAppHealthIssue.classify(WhatsAppAdapter.unreadableReason), .needsFullDiskAccess)
        XCTAssertEqual(WhatsAppHealthIssue.classify(WhatsAppAdapter.busyReason), .busy)
        XCTAssertEqual(WhatsAppHealthIssue.classify(WhatsAppAdapter.formatChangedReason), .formatChanged)
        XCTAssertEqual(WhatsAppHealthIssue.classify("odd"), .other("odd"))
        XCTAssertFalse(WhatsAppAdapter.notFoundReason.contains("Full Disk Access"),
                       "the not-installed message no longer sends people to the wrong fix")
        XCTAssertTrue(WhatsAppAdapter.unreadableReason.contains("Full Disk Access"))
    }

    func testNotInstalled() {
        let p = WhatsAppCardPresentation.make(health: nil, storeExists: false, appInstalled: false)
        XCTAssertEqual(p.kind, .notInstalled)
        XCTAssertTrue(p.guidance.contains("Install WhatsApp Desktop and sign in"))
        XCTAssertEqual(p.action, .none)
        XCTAssertFalse(p.isCalm)
    }

    func testInstalledButStoreHiddenMeansFullDiskAccess() {
        let p = WhatsAppCardPresentation.make(health: nil, storeExists: false, appInstalled: true)
        XCTAssertEqual(p.kind, .needsFullDiskAccess)
        XCTAssertEqual(p.action, .grantFullDiskAccess)
    }

    func testRecordedFullDiskAccessErrorOffersTheButton() {
        let p = WhatsAppCardPresentation.make(health: health("error", WhatsAppAdapter.unreadableReason),
                                              storeExists: true, appInstalled: true)
        XCTAssertEqual(p.kind, .needsFullDiskAccess)
        XCTAssertEqual(p.action, .grantFullDiskAccess)
    }

    func testWaitingAndBusyAreCalmWithNoButton() {
        let waiting = WhatsAppCardPresentation.make(health: nil, storeExists: true, appInstalled: true)
        XCTAssertEqual(waiting.kind, .waiting)
        XCTAssertTrue(waiting.isCalm)
        XCTAssertEqual(waiting.action, .none)

        let busy = WhatsAppCardPresentation.make(health: health("warning", WhatsAppAdapter.busyReason),
                                                 storeExists: true, appInstalled: true)
        XCTAssertEqual(busy.kind, .busy)
        XCTAssertTrue(busy.isCalm)
        XCTAssertEqual(busy.action, .none)
    }

    func testChangedFormatPointsToUpdateOrGitHub() {
        let p = WhatsAppCardPresentation.make(health: health("error", WhatsAppAdapter.formatChangedReason),
                                              storeExists: true, appInstalled: true)
        XCTAssertEqual(p.kind, .formatChanged)
        XCTAssertEqual(p.action, .reportOnGitHub)
        XCTAssertTrue(p.guidance.contains("Update LLMessenger, or report this on GitHub"))
    }

    func testStaleNotInstalledRecordYieldsToWhatIsOnDiskNow() {
        let p = WhatsAppCardPresentation.make(health: health("warning", WhatsAppAdapter.notFoundReason),
                                              storeExists: true, appInstalled: true)
        XCTAssertEqual(p.kind, .waiting, "the user just installed it; the next poll will confirm")
    }

    func testUnknownReasonIsShownAsIs() {
        let p = WhatsAppCardPresentation.make(health: health("error", "Something new"), storeExists: true, appInstalled: true)
        XCTAssertEqual(p.kind, .other)
        XCTAssertEqual(p.headline, "Something new")
    }

    func testFullDiskAccessTextNamesTheServiceThatNeedsIt() {
        XCTAssertTrue(FullDiskAccessCopy.informativeText(for: "whatsapp").contains("WhatsApp history"))
        XCTAssertFalse(FullDiskAccessCopy.informativeText(for: "whatsapp").contains("iMessage"))
        XCTAssertTrue(FullDiskAccessCopy.informativeText(for: "imessage").contains("iMessage history"))
    }

    // Adapter side: the same missing store gives a different message depending on the app.

    func testMissingStoreWithoutTheAppSaysNotInstalled() async {
        let adapter = WhatsAppAdapter(storePath: "/nonexistent/ChatStorage.sqlite", isAppInstalled: { false })
        let result = await adapter.healthCheck()
        XCTAssertEqual(result.reason, WhatsAppAdapter.notFoundReason)
    }

    func testMissingStoreWithTheAppSaysFullDiskAccess() async {
        let adapter = WhatsAppAdapter(storePath: "/nonexistent/ChatStorage.sqlite", isAppInstalled: { true })
        let result = await adapter.healthCheck()
        XCTAssertEqual(result.reason, WhatsAppAdapter.unreadableReason)
        do {
            try await adapter.start()
            XCTFail("start must throw")
        } catch {
            XCTAssertEqual(error.localizedDescription.contains("Full Disk Access"), true)
        }
    }
}

// MARK: - Per-conversation privacy text

final class PrivacyOverrideCopyTests: XCTestCase {

    func testStoredValuesAreUnchangedAndLabelsAreClear() {
        XCTAssertEqual(PrivacyOverrideCopy.options.map(\.0), ["none", "local_only", "never_draft"])
        XCTAssertEqual(PrivacyOverrideCopy.options.map(\.1), ["Normal", "Local-only", "Never draft"])
    }

    func testLocalOnlyCaptionStatesCloudMcpAndDigestEffects() {
        let text = PrivacyOverrideCopy.caption(for: "local_only")
        XCTAssertTrue(text.contains("Never sent to a cloud AI model"))
        XCTAssertTrue(text.contains("Hidden from AI apps connected over MCP"))
        XCTAssertTrue(text.contains("left out of digests while MCP is on"))
    }

    func testNeverDraftCaptionStatesWhatItDoesAndDoesNotDo() {
        let text = PrivacyOverrideCopy.caption(for: "never_draft")
        XCTAssertTrue(text.contains("No reply drafts"))
        XCTAssertTrue(text.contains("left out of digests"))
        XCTAssertTrue(text.contains("can still read it"), "MCP can still read a Never-draft conversation")
    }

    func testCaptionChangesWithSelection() {
        let all = Set(["none", "local_only", "never_draft"].map(PrivacyOverrideCopy.caption(for:)))
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(PrivacyOverrideCopy.caption(for: "anything else"), PrivacyOverrideCopy.caption(for: "none"))
    }
}
