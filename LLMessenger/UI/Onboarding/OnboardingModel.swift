// LLMessenger/UI/Onboarding/OnboardingModel.swift
//
// All first-run logic lives here, behind injected probes, so the wizard's
// decisions (AI default, Full Disk Access recovery, the honest last step) can
// be unit-tested without touching permissions, Ollama, or the real Keychain.
import AppKit
import Combine
import Foundation
import Security
import UserNotifications

// MARK: - Outcome + flags

enum OnboardingOutcome: Equatable {
    /// User chose "See it with sample messages".
    case demo
    /// User reached the end of setup and opened the app.
    case finished
    /// User explicitly skipped setup.
    case skipped
    /// Window closed mid-way. Not complete; setup is reopenable.
    case dismissed

    var completesOnboarding: Bool { self != .dismissed }
}

enum OnboardingFlag {
    static let completedKey = "hasCompletedOnboarding"
    /// Set when the user picked "Decide later" in the AI step.
    static let aiDecideLaterKey = "onboarding_ai_decide_later"
    static let menuBarHintKey = "hasSeenMenuBarHint"

    /// The single place that marks onboarding complete.
    static func apply(_ outcome: OnboardingOutcome, to defaults: UserDefaults = .standard) {
        if outcome.completesOnboarding { defaults.set(true, forKey: completedKey) }
    }
}

// MARK: - Keychain explanation

enum KeychainExplanation {
    static let seenKey = "hasSeenKeychainExplanation"
    static let services = ["LLMessenger", "com.llmessenger.app", "LLMessenger Credentials"]

    /// Only worth interrupting for when macOS may actually ask for a password.
    static func shouldShow(hasSeen: Bool, hasStoredCredentials: Bool) -> Bool {
        !hasSeen && hasStoredCredentials
    }

    /// Attribute-only lookup: never reads the secret, so it never prompts.
    static func hasStoredCredentials() -> Bool {
        services.contains { service in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        }
    }
}

// MARK: - Steps

enum OnboardingStep: Int, Equatable {
    case welcome, services, access, ai, finish
}

// MARK: - Services catalogue

struct OnboardingService: Identifiable, Equatable {
    let id: String
    let name: String
    /// What it takes, in plain words, with a rough time.
    let effort: String
    let detail: String
    /// True when the wizard can set it up; false means "later, in Settings".
    let inWizard: Bool

    static let catalog: [OnboardingService] = [
        .init(id: "imessage", name: "iMessage",
              effort: "One permission, about 2 minutes",
              detail: "Reads your Messages history on this Mac.",
              inWizard: true),
        .init(id: "whatsapp", name: "WhatsApp",
              effort: "One permission, about 2 minutes",
              detail: "Read-only. Needs WhatsApp Desktop on this Mac. You reply in WhatsApp.",
              inWizard: true),
        .init(id: "slack", name: "Slack",
              effort: "Technical, about 15 minutes",
              detail: "Needs a Slack app token that you create yourself.",
              inWizard: false),
        .init(id: "telegram", name: "Telegram",
              effort: "Technical, about 10 minutes",
              detail: "Needs a free developer key from Telegram and a sign-in code.",
              inWizard: false),
        .init(id: "signal", name: "Signal",
              effort: "Technical, about 15 minutes",
              detail: "Needs a free helper app (signal-mcp) installed and running on this Mac.",
              inWizard: false)
    ]

    static var inWizardServices: [OnboardingService] { catalog.filter(\.inWizard) }
    static var laterServices: [OnboardingService] { catalog.filter { !$0.inWizard } }
    /// Services that read protected files and therefore need Full Disk Access.
    static let needingFullDiskAccess: Set<String> = ["imessage", "whatsapp"]
}

// MARK: - Full Disk Access state machine

struct FullDiskAccessTracker: Equatable {
    enum Status: Equatable { case waiting, granted, needsHelp }

    /// How long after the user opens System Settings before we offer recovery.
    static let helpDelay: TimeInterval = 30
    /// If they never pressed the button, wait longer before assuming trouble.
    static let idleHelpDelay: TimeInterval = 90

    private(set) var status: Status = .waiting
    private(set) var startedAt: Date?
    private(set) var settingsOpenedAt: Date?

    mutating func begin(at now: Date) {
        if startedAt == nil { startedAt = now }
    }

    mutating func settingsOpened(at now: Date) {
        if startedAt == nil { startedAt = now }
        if status == .waiting { settingsOpenedAt = now }
    }

    mutating func update(granted: Bool, now: Date) {
        if granted { status = .granted; return }
        guard status == .waiting else { return }   // granted and needsHelp are sticky
        if let opened = settingsOpenedAt {
            if now.timeIntervalSince(opened) >= Self.helpDelay { status = .needsHelp }
        } else if let started = startedAt, now.timeIntervalSince(started) >= Self.idleHelpDelay {
            status = .needsHelp
        }
    }
}

// MARK: - AI choice

struct AIDetection: Equatable {
    var appleIntelligence = false
    /// nil means Ollama is not running; empty means running with no models.
    var ollamaModels: [String]?
    /// True once at least one probe has completed.
    var checked = false
}

enum AIChoice: Equatable {
    case appleIntelligence
    case ollama(model: String)
    case cloud(LLMProvider)
    case later

    var isCloud: Bool { if case .cloud = self { return true } else { return false } }

    var summary: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence, on this Mac"
        case .ollama(let model): return "Ollama (\(model)), on this Mac"
        case .cloud(let p):      return "\(p.displayName), in the cloud"
        case .later:             return "Not chosen yet"
        }
    }

    /// Best available option with no user input. Never a cloud provider.
    static func automatic(for detection: AIDetection) -> AIChoice? {
        if detection.appleIntelligence { return .appleIntelligence }
        if let first = detection.ollamaModels?.first { return .ollama(model: first) }
        return nil
    }
}

enum AIViewMode: Equatable { case apple, ollama, options, current }

// MARK: - First digest status

struct FirstDigestInputs: Equatable {
    var servicesEnabled: [String]
    var aiDeferred: Bool
    var aiConfigured: Bool
    /// Digests created since the user pressed "Build".
    var digestsSinceStart: Int
    var generationState: BriefGenerationState
    var sawActivity: Bool
    var lastError: String?
    var accessMissing: Bool
    var elapsed: TimeInterval
}

enum FirstDigestFix: Equatable { case chooseAI, fixAccess, retry }

enum FirstDigestStatus: Equatable {
    case notStarted
    case building(detail: String, slow: Bool)
    case ready
    case failed(message: String, fix: FirstDigestFix)
    case noMessages
    /// The user chose "Decide later": saved, but nothing to build yet.
    case paused
    case nothingConnected

    static let slowAfter: TimeInterval = 180

    static func resolve(_ i: FirstDigestInputs) -> FirstDigestStatus {
        if i.digestsSinceStart > 0 { return .ready }
        if i.servicesEnabled.isEmpty { return .nothingConnected }
        if i.aiDeferred { return .paused }
        if !i.aiConfigured {
            return .failed(message: "No AI model is set up, so there is nothing to write your digest with.",
                           fix: .chooseAI)
        }
        let running = i.generationState == .fetching || i.generationState == .summarizing
        let finishedEmpty = i.sawActivity && !running
        if i.accessMissing && (finishedEmpty || i.generationState == .failed) {
            return .failed(message: "LLMessenger can't read your messages yet. macOS hasn't given it Full Disk Access.",
                           fix: .fixAccess)
        }
        if i.generationState == .failed || (finishedEmpty && !(i.lastError ?? "").isEmpty) {
            let text = (i.lastError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message: text.isEmpty ? "Something went wrong while writing your digest." : text,
                           fix: .retry)
        }
        if finishedEmpty && i.generationState == .noNewMessages { return .noMessages }
        let detail = i.generationState == .summarizing ? "Writing your digest" : "Reading your messages"
        return .building(detail: detail, slow: i.elapsed >= slowAfter)
    }
}

// MARK: - Environment (injected probes)

struct OnboardingEnvironment {
    var fullDiskAccessGranted: () -> Bool
    var appleIntelligenceAvailable: () -> Bool
    /// nil when Ollama isn't running.
    var ollamaModels: () async -> [String]?
    var whatsAppDesktopInstalled: () -> Bool
    var appIsInApplicationsFolder: () -> Bool
    var openPrivacySettings: () -> Void
    var revealAppInFinder: () -> Void
    var quitAndReopen: () -> Void
    var requestNotifications: () -> Void
    var openURL: (URL) -> Void
    /// Reloads service config and the AI client; optionally builds the first digest.
    var applyChanges: (_ buildDigest: Bool) -> Void
    var now: () -> Date

    static func live(applyChanges: @escaping (_ buildDigest: Bool) -> Void) -> OnboardingEnvironment {
        OnboardingEnvironment(
            fullDiskAccessGranted: {
                let home = NSHomeDirectory()
                if FileManager.default.isReadableFile(atPath: home + "/Library/Messages/chat.db") { return true }
                // Messages may have no history yet; Safari's folder is protected the same way.
                return (try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/Safari")) != nil
            },
            appleIntelligenceAvailable: { AppleFM.isAvailable },
            ollamaModels: { try? await OllamaClient.fetchModels().map(\.name) },
            whatsAppDesktopInstalled: {
                FileManager.default.fileExists(atPath: "/Applications/WhatsApp.app")
                    || FileManager.default.fileExists(atPath: WhatsAppAdapter.defaultStorePath)
            },
            appIsInApplicationsFolder: {
                Bundle.main.bundlePath.hasPrefix("/Applications/")
                    || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
            },
            openPrivacySettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            },
            revealAppInFinder: { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) },
            quitAndReopen: {
                // Relaunch after this process exits; the path is an argument, never part of the script.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$1\"", "sh", Bundle.main.bundlePath]
                try? process.run()
                NSApp.terminate(nil)
            },
            requestNotifications: {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            },
            openURL: { NSWorkspace.shared.open($0) },
            applyChanges: applyChanges,
            now: Date.init
        )
    }
}

// MARK: - Model

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep
    @Published var selectedServices: Set<String> = ["imessage"]
    @Published private(set) var whatsAppDetected = false
    @Published private(set) var access = FullDiskAccessTracker()
    @Published private(set) var aiDetection = AIDetection()
    @Published var aiChoice: AIChoice?
    @Published var showAIAlternatives = false
    @Published var ollamaModel = ""
    @Published var cloudProvider: LLMProvider = .anthropic
    @Published var cloudKey = ""
    @Published private(set) var buildStartedAt: Date?
    @Published private(set) var sawBuildActivity = false
    @Published private(set) var digestStatus: FirstDigestStatus = .notStarted
    @Published private(set) var notificationsRequested = false
    @Published var demoError: String?
    private var aiUserPicked = false
    /// A cloud provider the user already chose in an earlier setup or in Settings. Re-running
    /// setup starts from it instead of replacing it with an automatically detected local model.
    private(set) var existingCloudProvider: LLMProvider?

    weak var appState: AppState?
    var onFinish: ((OnboardingOutcome) -> Void)?

    private let database: AppDatabase
    private let env: OnboardingEnvironment
    private let defaults: UserDefaults
    private let settings: SettingsRepository

    init(database: AppDatabase,
         environment: OnboardingEnvironment,
         startAt: OnboardingStep = .welcome,
         defaults: UserDefaults = .standard,
         settings: SettingsRepository? = nil) {
        self.database = database
        self.env = environment
        self.defaults = defaults
        self.settings = settings ?? SettingsRepository(database: database, userDefaults: defaults)
        self.step = startAt
        self.whatsAppDetected = environment.whatsAppDesktopInstalled()
        if let current = self.settings.loadSelectedLLMProvider(), current.requiresAPIKey {
            existingCloudProvider = current
            cloudProvider = current
            aiChoice = .cloud(current)
            aiUserPicked = true // detection must never override what the user already chose
        }
    }

    // MARK: Derived

    var needsAccess: Bool {
        !selectedServices.isDisjoint(with: OnboardingService.needingFullDiskAccess)
    }

    /// Steps shown as dots, in order. Access only appears when it is needed.
    var visibleSteps: [OnboardingStep] {
        [.services] + (needsAccess ? [.access] : []) + [.ai, .finish]
    }

    var canContinueFromServices: Bool { !selectedServices.isEmpty }

    var aiViewMode: AIViewMode {
        if showAIAlternatives { return .options }
        if let existing = existingCloudProvider, aiChoice == .cloud(existing) { return .current }
        if aiDetection.appleIntelligence { return .apple }
        if let models = aiDetection.ollamaModels, !models.isEmpty { return .ollama }
        return .options
    }

    var canUseCloud: Bool { !cloudKey.trimmingCharacters(in: .whitespaces).isEmpty }

    var appIsInApplicationsFolder: Bool { env.appIsInApplicationsFolder() }

    /// Services the last step will actually read, in catalogue order.
    var chosenServiceNames: [String] {
        OnboardingService.inWizardServices.filter { selectedServices.contains($0.id) }.map(\.name)
    }

    // MARK: Navigation

    func startSetup() { step = .services }

    func continueFromServices() {
        guard canContinueFromServices else { return }
        goToAccessOrAI()
    }

    private func goToAccessOrAI() {
        if needsAccess {
            access.begin(at: env.now())
            access.update(granted: env.fullDiskAccessGranted(), now: env.now())
            step = .access
        } else {
            step = .ai
        }
    }

    func continueFromAccess() { step = .ai }

    /// "Skip for now": carry on without the services that need the permission.
    func skipAccess() {
        selectedServices.subtract(OnboardingService.needingFullDiskAccess)
        step = .ai
    }

    func continueFromAI() { step = .finish }

    func goBack() {
        switch step {
        case .welcome, .services: break
        case .access: step = .services
        case .ai: step = needsAccess ? .access : .services
        case .finish: if buildStartedAt == nil { step = .ai }
        }
    }

    /// Dots go back only; you can't skip past a step you haven't done.
    func canJump(to target: OnboardingStep) -> Bool {
        guard buildStartedAt == nil, target.rawValue < step.rawValue, visibleSteps.contains(target) else { return false }
        return true
    }

    func jump(to target: OnboardingStep) { if canJump(to: target) { step = target } }

    func toggleService(_ id: String) {
        guard OnboardingService.inWizardServices.contains(where: { $0.id == id }) else { return }
        if id == "whatsapp" && !whatsAppDetected { return }
        if selectedServices.contains(id) { selectedServices.remove(id) } else { selectedServices.insert(id) }
    }

    // MARK: Completion

    func startDemo() {
        do {
            try DemoSeeder.seed(into: database)
            onFinish?(.demo)
        } catch {
            // Seeding an empty local store failing is unexpected; stay on the welcome screen.
            demoError = error.localizedDescription
        }
    }

    func skipSetup() { onFinish?(.skipped) }
    func finish() { onFinish?(.finished) }

    // MARK: Full Disk Access

    func openPrivacySettings() {
        access.settingsOpened(at: env.now())
        env.openPrivacySettings()
    }
    func revealAppInFinder() { env.revealAppInFinder() }
    func quitAndReopen() { env.quitAndReopen() }

    // MARK: AI

    func refreshAIDetection() async {
        let apple = env.appleIntelligenceAvailable()
        let models = await env.ollamaModels()
        applyDetection(AIDetection(appleIntelligence: apple, ollamaModels: models, checked: true))
    }

    func applyDetection(_ detection: AIDetection) {
        aiDetection = detection
        if let models = detection.ollamaModels, let first = models.first, !models.contains(ollamaModel) {
            ollamaModel = first
        }
        // Never override something the user picked themselves.
        guard !aiUserPicked else { return }
        switch AIChoice.automatic(for: detection) {
        case .some(.ollama): aiChoice = .ollama(model: ollamaModel)
        case .some(let auto): aiChoice = auto
        case .none: aiChoice = nil
        }
    }

    func chooseOllamaModel(_ model: String) {
        aiUserPicked = true
        ollamaModel = model
        aiChoice = .ollama(model: model)
    }

    func useDetectedOllama() {
        guard let first = aiDetection.ollamaModels?.first else { return }
        chooseOllamaModel(ollamaModel.isEmpty ? first : ollamaModel)
        continueFromAI()
    }

    func useCloud() {
        guard canUseCloud else { return }
        aiUserPicked = true
        aiChoice = .cloud(cloudProvider)
        continueFromAI()
    }

    func decideAILater() {
        aiUserPicked = true
        aiChoice = .later
        continueFromAI()
    }

    func useAutomaticAI() {
        if aiChoice == nil, let auto = AIChoice.automatic(for: aiDetection) { aiChoice = auto }
        continueFromAI()
    }

    func openOllamaDownload() {
        if let url = URL(string: "https://ollama.com/download") { env.openURL(url) }
    }

    // MARK: Building the first digest

    func requestNotifications() {
        notificationsRequested = true
        env.requestNotifications()
    }

    /// Writes everything chosen, applies it to the running app, and starts the build.
    func startBuilding() {
        guard buildStartedAt == nil else { return }
        // Leaving the sample data behind first: otherwise its digests would
        // look like the user's own first digest.
        if DemoSeeder.isActive {
            appState?.selectedBriefID = nil
            try? DemoSeeder.wipe(from: database)
            appState?.isDemoTransitioning = true
            appState?.refreshBriefs()
        }
        persistServices()
        persistAI()
        buildStartedAt = env.now()
        let willBuild = aiChoice != .later && aiChoice != nil && !selectedServices.isEmpty
        env.applyChanges(willBuild)
        updateDigestStatus()
    }

    func retryBuild() {
        sawBuildActivity = false
        buildStartedAt = env.now()
        env.applyChanges(true)
        updateDigestStatus()
    }

    func fixAI() {
        buildStartedAt = nil
        digestStatus = .notStarted
        showAIAlternatives = true
        step = .ai
    }

    func fixAccess() {
        buildStartedAt = nil
        digestStatus = .notStarted
        access = FullDiskAccessTracker()
        goToAccessOrAI()
    }

    private func persistServices() {
        for service in OnboardingService.inWizardServices {
            var config = (try? settings.loadServiceConfig(for: service.id)) ?? ServiceConfig.default(for: service.id)
            config.enabled = selectedServices.contains(service.id)
            try? settings.saveServiceConfig(config)
        }
    }

    private func persistAI() {
        defaults.set(aiChoice == .later, forKey: OnboardingFlag.aiDecideLaterKey)
        switch aiChoice {
        case .appleIntelligence:
            settings.saveSelectedLLMProvider(.appleIntelligence)
        case .ollama(let model):
            settings.saveSelectedLLMProvider(.ollama)
            settings.saveOllamaModel(model)
        case .cloud(let provider):
            let typedKey = cloudKey.trimmingCharacters(in: .whitespaces)
            // Keeping the provider chosen earlier: its saved key and consent stay as they are.
            if !typedKey.isEmpty {
                try? settings.saveLLMKey(provider: provider, key: typedKey)
                // The disclosure is shown next to the key field; pressing "Use <provider>" is the consent.
                settings.saveCloudAutoBriefsConsent(true)
            }
            settings.saveSelectedLLMProvider(provider)
        case .later, nil:
            settings.saveSelectedLLMProvider(nil)
        }
    }

    // MARK: Periodic

    func tick() {
        let now = env.now()
        switch step {
        case .access:
            access.update(granted: env.fullDiskAccessGranted(), now: now)
        case .finish:
            updateDigestStatus()
        default:
            break
        }
    }

    func updateDigestStatus() {
        guard let started = buildStartedAt else { digestStatus = .notStarted; return }
        let now = env.now()
        let state = appState?.briefGenerationState ?? .cached
        if state == .fetching || state == .summarizing { sawBuildActivity = true }
        let fresh = appState?.briefs.filter { $0.createdAt >= started.addingTimeInterval(-1) }.count ?? 0
        digestStatus = FirstDigestStatus.resolve(FirstDigestInputs(
            servicesEnabled: Array(selectedServices),
            aiDeferred: aiChoice == .later,
            aiConfigured: appState?.isLLMConfigured ?? (aiChoice != nil),
            digestsSinceStart: fresh,
            generationState: state,
            sawActivity: sawBuildActivity,
            lastError: appState?.lastError,
            accessMissing: needsAccess && !env.fullDiskAccessGranted(),
            elapsed: now.timeIntervalSince(started)
        ))
    }
}
