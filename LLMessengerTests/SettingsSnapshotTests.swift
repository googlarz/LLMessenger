// LLMessengerTests/SettingsSnapshotTests.swift
//
// Renders the Settings surfaces changed in the usability pass into
// docs/design/snapshots/<tag>/settings-*.png so they can be looked at (see
// DesignSnapshotTests for the harness this mirrors). Uses an in-memory database, a private
// UserDefaults suite and a private Keychain service: nothing here reads or writes the user's
// real settings, messages or WhatsApp data.

import XCTest
import SwiftUI
import AppKit
@testable import LLMessenger

@MainActor
final class SettingsSnapshotTests: XCTestCase {

    private let suiteName = "SettingsSnapshotTests-\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private var keychain: KeychainStore!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suiteName)!
        keychain = KeychainStore(service: "LLMessengerSnapshotTests-\(UUID().uuidString)", account: "credentials")
        NetworkAuditLog.shared.clear()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        keychain.deleteStore()
    }

    private func repo(database: AppDatabase? = nil) -> SettingsRepository {
        SettingsRepository(keychainStore: keychain, keyPrefix: "_snap_", database: database, userDefaults: defaults)
    }

    // MARK: - Renderer (same approach as DesignSnapshotTests)

    private var outputDir: URL {
        let tag = ProcessInfo.processInfo.environment["SNAPSHOT_TAG"] ?? "current"
        let testsDir = URL(fileURLWithPath: String(#filePath)).deletingLastPathComponent()
        return testsDir.deletingLastPathComponent()
            .appendingPathComponent("docs/design/snapshots/\(tag)", isDirectory: true)
    }

    private func render<V: View>(_ view: V, size: NSSize, name: String,
                                 appearance: NSAppearance.Name = .darkAqua) throws {
        Theme.forceReduceMotion = true
        let framed = view.frame(width: size.width, height: size.height).background(Theme.bg)
        let hosting = NSHostingView(rootView: framed)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        hosting.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = hosting

        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("Could not create bitmap rep for \(name)")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG encode failed for \(name)")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let url = outputDir.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("SNAPSHOT WROTE: \(url.path)")
    }

    /// Light and dark of the same view.
    private func renderBoth<V: View>(_ view: V, size: NSSize, name: String) throws {
        try render(view, size: size, name: "\(name)-dark", appearance: .darkAqua)
        try render(view, size: size, name: "\(name)-light", appearance: .aqua)
    }

    private let fakeExecutable = "/Applications/LLMessenger.app/Contents/MacOS/LLMessenger"

    // MARK: - Privacy pane

    func testSnapshotPrivacyMCPOff() throws {
        let r = repo()
        try renderBoth(PrivacySettingsTab(repo: r, executablePath: fakeExecutable, lastAgentRequest: { nil }),
                       size: NSSize(width: 720, height: 980), name: "settings-privacy-mcp-off")
    }

    func testSnapshotPrivacyMCPConfirmation() throws {
        let r = repo()
        let model = MCPAccessModel(repo: r)
        model.setSwitch(true)   // switch flipped, confirmation showing, nothing stored
        XCTAssertFalse(r.loadMCPServerEnabled())
        try renderBoth(PrivacySettingsTab(repo: r, mcp: model, executablePath: fakeExecutable, lastAgentRequest: { nil }),
                       size: NSSize(width: 720, height: 1100), name: "settings-privacy-mcp-confirm")
    }

    func testSnapshotPrivacyMCPOn() throws {
        let r = repo()
        r.saveMCPServerEnabled(true)
        try renderBoth(PrivacySettingsTab(repo: r, executablePath: fakeExecutable, lastAgentRequest: { nil }),
                       size: NSSize(width: 720, height: 1500), name: "settings-privacy-mcp-on")
    }

    // MARK: - Services pane

    private func health(_ status: String, _ error: String?) -> ServiceHealth {
        ServiceHealth(service: "whatsapp", status: status, lastCheck: Date(), lastError: error, retryAfter: nil)
    }

    private func whatsAppCard(_ title: String, health: ServiceHealth?, storeExists: Bool, appInstalled: Bool) -> some View {
        var config = ServiceConfig.default(for: "whatsapp")
        config.enabled = true
        return VStack(alignment: .leading, spacing: 4) {
            WireLabel(title)
            ServiceCard(
                config: .constant(config),
                signalAccount: .constant(""), telegramApiId: .constant(""), telegramApiHash: .constant(""),
                health: health,
                hostFacts: ServiceHostFacts(whatsAppStoreExists: { storeExists }, whatsAppInstalled: { appInstalled }, slackWorkspaceCount: { 0 }),
                onRetry: { _ in }
            )
        }
    }

    func testSnapshotServicesWhatsAppStates() throws {
        let stack = VStack(alignment: .leading, spacing: 0) {
            whatsAppCard("Not installed", health: nil, storeExists: false, appInstalled: false)
            Rule()
            whatsAppCard("Needs Full Disk Access", health: health("error", WhatsAppAdapter.unreadableReason),
                         storeExists: false, appInstalled: true)
            Rule()
            whatsAppCard("Waiting for first check", health: nil, storeExists: true, appInstalled: true)
            Rule()
            whatsAppCard("Busy", health: health("warning", WhatsAppAdapter.busyReason),
                         storeExists: true, appInstalled: true)
            Rule()
            whatsAppCard("Format changed", health: health("error", WhatsAppAdapter.formatChangedReason),
                         storeExists: true, appInstalled: true)
            Rule()
            whatsAppCard("Working", health: health("ok", nil), storeExists: true, appInstalled: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        try renderBoth(stack, size: NSSize(width: 720, height: 860), name: "settings-services-whatsapp")
    }

    func testSnapshotServicesPaneWithUnsavedSignInDetails() throws {
        let db = try AppDatabase(inMemory: true)
        let r = repo(database: db)
        var whatsapp = ServiceConfig.default(for: "whatsapp")
        whatsapp.enabled = true
        try r.saveServiceConfig(whatsapp)
        try db.dbQueue.write { try self.health("warning", WhatsAppAdapter.busyReason).save($0) }
        let model = ServiceSettingsModel(repo: r, center: NotificationCenter())
        model.reload()
        model.credentials.signalAccount = "+49 151 2345 6789"   // typed, not saved
        let facts = ServiceHostFacts(whatsAppStoreExists: { true }, whatsAppInstalled: { true }, slackWorkspaceCount: { 0 })
        try renderBoth(ServiceSettingsTab(model: model, hostFacts: facts),
                       size: NSSize(width: 720, height: 1050), name: "settings-services-unsaved")
    }

    // MARK: - Priority rules

    private func seededRules() async throws -> AppDatabase {
        let db = try AppDatabase(inMemory: true)
        let store = PriorityRuleStore(database: db)
        func rule(contact: String?, keyword: String? = nil, priority: String? = nil,
                  suppress: Bool = false, notify: Bool = false, quiet: (String, String)? = nil) -> PriorityRule {
            PriorityRule(id: nil, contactPattern: contact, keywordPattern: keyword, service: nil,
                         setPriority: priority, suppress: suppress, alwaysNotify: notify, sortOrder: 0,
                         createdAt: Date(), quietStart: quiet?.0, quietEnd: quiet?.1)
        }
        try await store.add(rule(contact: "Anna", notify: true, quiet: ("22:00", "06:30")))
        try await store.add(rule(contact: nil, keyword: "invoice", priority: "high"))
        try await store.add(rule(contact: "Sailing Club", suppress: true))
        return db
    }

    func testSnapshotPriorityRulesList() async throws {
        let db = try await seededRules()
        let rules = try await PriorityRuleStore(database: db).loadAll()
        try renderBoth(RulesSettingsTab(database: db, initialRules: rules), size: NSSize(width: 720, height: 460),
                       name: "settings-rules-list")
    }

    func testSnapshotPriorityRuleEditorEditingAlwaysNotify() throws {
        let rule = PriorityRule(id: 1, contactPattern: "Anna", keywordPattern: nil, service: "signal",
                                setPriority: nil, suppress: false, alwaysNotify: true, sortOrder: 0,
                                createdAt: Date(), quietStart: "22:00", quietEnd: "06:30")
        try renderBoth(RuleEditorView(rule: rule, onSave: { _ in }),
                       size: NSSize(width: 460, height: 640), name: "settings-rules-editor-edit")
    }

    func testSnapshotPriorityRuleEditorNewShowsQuietHoursDisabled() throws {
        try renderBoth(RuleEditorView(rule: nil, onSave: { _ in }),
                       size: NSSize(width: 460, height: 640), name: "settings-rules-editor-new")
    }

    // MARK: - Conversation context

    private func contextEditor(privacy: String) throws -> ContextEditor {
        let db = try AppDatabase(inMemory: true)
        let ctx = ConversationContext(service: "signal", conversationId: "c1", label: "", priorityHint: "auto",
                                      updatedAt: Date(), relationship: "Sailing club crew",
                                      contextNote: nil, responseExpectation: nil,
                                      privacyOverride: privacy == "none" ? nil : privacy, tone: nil)
        try BriefRepository(database: db).upsertConversationContext(ctx)
        return ContextEditor(service: "signal", conversationId: "c1", conversationName: "Sailing Club", database: db)
    }

    func testSnapshotContextEditorLocalOnly() throws {
        try renderBoth(contextEditor(privacy: "local_only"), size: NSSize(width: 420, height: 980),
                       name: "settings-context-local-only")
    }

    func testSnapshotContextEditorNeverDraft() throws {
        try render(contextEditor(privacy: "never_draft"), size: NSSize(width: 420, height: 980),
                   name: "settings-context-never-draft-dark")
    }

    // MARK: - Other panes touched

    func testSnapshotAITabCloudProviderUnsaved() throws {
        let model = AISettingsModel(repo: repo(), center: NotificationCenter())
        model.values.selectedProviderRaw = LLMProvider.anthropic.rawValue
        model.values.anthropicKey = "sk-ant-api03-example"
        try renderBoth(AISettingsTab(database: nil, model: model, repo: repo()), size: NSSize(width: 720, height: 760),
                       name: "settings-ai-unsaved")
    }

    func testSnapshotWritingAndAppearanceUnsaved() throws {
        let model = InstructionsSettingsModel(repo: repo(), applyAppearance: { _ in })
        model.values.briefLanguage = "Polish"
        try renderBoth(InstructionsSettingsTab(model: model), size: NSSize(width: 720, height: 560),
                       name: "settings-writing")
    }

    func testSnapshotSchedulePane() throws {
        try renderBoth(DigestSettingsTab(), size: NSSize(width: 720, height: 760), name: "settings-schedule")
    }

    func testSnapshotAbout() throws {
        try renderBoth(AboutSettingsTab(database: nil, onRunSetup: {}), size: NSSize(width: 720, height: 700),
                       name: "settings-about")
    }
}
