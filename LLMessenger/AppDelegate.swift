// LLMessenger/AppDelegate.swift
import AppKit

extension Notification.Name {
    static let serviceConfigDidChange = Notification.Name("com.llmessenger.serviceConfigDidChange")
    /// Posted by LLMSettingsTab when provider, API key, or cloud consent changes.
    /// AppDelegate observes this to hot-swap the LLM client without requiring a restart.
    static let llmProviderDidChange = Notification.Name("com.llmessenger.llmProviderDidChange")
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?
    var pollEngine: PollEngine?
    var briefEngine: BriefEngine?
    var chatWindowController: ChatWindowController?
    var settingsWindowController: SettingsWindowController?
    var appState: AppState?
    var database: AppDatabase?
    var notificationManager: NotificationManager?
    var startTask: Task<Void, Never>?
    var onboardingWindowController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let db = try AppDatabase()
            database = db

            let llm = resolvedProvider()

            let savedPrompt = SettingsRepository(database: db).loadBasePrompt()
            let basePrompt = savedPrompt.isEmpty ? PromptBuilder.defaultBasePrompt : savedPrompt

            let state = AppState(
                database: db,
                llmClient: llm.client,
                llmModel: llm.model,
                llmProvider: llm.provider,
                isLLMConfigured: llm.isConfigured,
                basePrompt: basePrompt
            )
            appState = state

            briefEngine = BriefEngine(
                database: db,
                client: llm.client,
                model: llm.model,
                basePrompt: basePrompt
            )

            let windowController = ChatWindowController(appState: state)
            chatWindowController = windowController

            let notifications = NotificationManager()
            notifications.requestPermission()
            notifications.onNotificationTap = { [weak windowController, weak state] briefID in
                state?.selectedBriefID = briefID
                state?.markAsOpen(briefID: briefID)
                windowController?.show(selectingBriefID: briefID)
            }
            notificationManager = notifications

            let menuBar = MenuBarController()
            menuBar.onNewBrief = { [weak self] in
                guard let self else { return }
                InstrumentationManager.shared.track(event: .refreshTriggered, metadata: ["source": "menuBar"])
                Task {
                    self.appState?.briefGenerationState = .fetching
                    self.menuBarController?.setLoading(true)
                    let start = Date()
                    await self.pollEngine?.pollAll()
                    // Surface adapter failures after polling (e.g. FDA not granted for iMessage).
                    if let health = self.pollEngine?.currentServiceHealth {
                        let failed = health.filter { $0.value != .ok }.keys.sorted()
                        if !failed.isEmpty {
                            self.appState?.lastError = "Could not reach: \(failed.joined(separator: ", ")). Check permissions in System Settings."
                        }
                    }
                    do {
                        self.appState?.briefGenerationState = .summarizing
                        let newID = try await self.briefEngine?.processNewMessages(adapters: self.appState?.adapters ?? [:])
                        if let id = newID {
                            self.appState?.lastError = nil
                            let brief = try? self.appState?.repository.fetchBrief(id: id)
                            let body = brief?.notificationText ?? "You have new messages"
                            self.notificationManager?.post(briefID: id, title: "New messages", body: body)
                        }
                        self.appState?.briefGenerationState = newID == nil ? .noNewMessages : .complete
                    } catch {
                        self.appState?.lastError = error.localizedDescription
                        self.appState?.briefGenerationState = .failed
                    }
                    // Keep animation visible for at least 1.5s so user sees activity
                    let elapsed = Date().timeIntervalSince(start)
                    if elapsed < 1.5 {
                        try? await Task.sleep(nanoseconds: UInt64((1.5 - elapsed) * 1_000_000_000))
                    }
                    self.appState?.refreshBriefs()
                    self.menuBarController?.setLoading(false)
                    self.menuBarController?.setBriefs(self.appState?.briefs ?? [])
                    self.menuBarController?.setLastError(self.appState?.lastError)
                    let unread = self.appState?.unreadCount ?? 0
                    self.menuBarController?.setUnreadCount(unread)
                }
            }
            menuBar.onLast24h = { [weak self] in
                guard let self else { return }
                Task {
                    self.appState?.briefGenerationState = .fetching
                    self.menuBarController?.setLoading(true)
                    let start = Date()
                    let adapters = self.appState?.adapters ?? [:]
                    do {
                        self.appState?.briefGenerationState = .summarizing
                        if let briefID = try await self.briefEngine?.summarizeLast(hours: 48, adapters: adapters) {
                            let brief = try? self.appState?.repository.fetchBrief(id: briefID)
                            let body = brief?.notificationText ?? "48h summary ready"
                            self.notificationManager?.post(briefID: briefID, title: "48h Summary", body: body)
                            self.appState?.briefGenerationState = .complete
                        } else {
                            self.appState?.briefGenerationState = .noNewMessages
                        }
                        self.appState?.lastError = nil
                    } catch {
                        self.appState?.lastError = error.localizedDescription
                        self.appState?.briefGenerationState = .failed
                    }
                    let elapsed = Date().timeIntervalSince(start)
                    if elapsed < 1.5 {
                        try? await Task.sleep(nanoseconds: UInt64((1.5 - elapsed) * 1_000_000_000))
                    }
                    self.appState?.refreshBriefs()
                    self.menuBarController?.setLoading(false)
                    self.menuBarController?.setBriefs(self.appState?.briefs ?? [])
                    self.menuBarController?.setLastError(self.appState?.lastError)
                    let unread = self.appState?.unreadCount ?? 0
                    self.menuBarController?.setUnreadCount(unread)
                }
            }
            menuBar.onLast7d = { [weak self] in
                guard let self else { return }
                Task {
                    self.appState?.briefGenerationState = .fetching
                    self.menuBarController?.setLoading(true)
                    let start = Date()
                    let adapters = self.appState?.adapters ?? [:]
                    do {
                        self.appState?.briefGenerationState = .summarizing
                        if let briefID = try await self.briefEngine?.summarizeLast(hours: 168, adapters: adapters) {
                            let brief = try? self.appState?.repository.fetchBrief(id: briefID)
                            let body = brief?.notificationText ?? "7-day summary ready"
                            self.notificationManager?.post(briefID: briefID, title: "7-Day Summary", body: body)
                            self.appState?.briefGenerationState = .complete
                        } else {
                            self.appState?.briefGenerationState = .noNewMessages
                        }
                        self.appState?.lastError = nil
                    } catch {
                        self.appState?.lastError = error.localizedDescription
                        self.appState?.briefGenerationState = .failed
                    }
                    let elapsed = Date().timeIntervalSince(start)
                    if elapsed < 1.5 {
                        try? await Task.sleep(nanoseconds: UInt64((1.5 - elapsed) * 1_000_000_000))
                    }
                    self.appState?.refreshBriefs()
                    self.menuBarController?.setLoading(false)
                    self.menuBarController?.setBriefs(self.appState?.briefs ?? [])
                    self.menuBarController?.setLastError(self.appState?.lastError)
                    self.menuBarController?.setUnreadCount(self.appState?.unreadCount ?? 0)
                }
            }
            menuBar.onSelectBrief = { [weak windowController, weak state] briefID in
                state?.selectedBriefID = briefID
                state?.markAsOpen(briefID: briefID)
                windowController?.show(selectingBriefID: briefID)
            }
            let settingsController = SettingsWindowController(database: db)
            settingsWindowController = settingsController
            settingsController.onRunSetup = { [weak self] in
                guard let self else { return }
                UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
                let controller = OnboardingWindowController(database: db)
                controller.onComplete = { [weak self] in
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    self?.onboardingWindowController = nil
                    self?.chatWindowController?.show()
                }
                self.onboardingWindowController = controller
                controller.show()
            }
            let openSettings: () -> Void = { [weak settingsController] in settingsController?.show() }
            menuBar.onOpenSettings = openSettings
            state.onOpenSettings = openSettings

            menuBar.onRestartSignalWatch = { [weak self] in
                guard let self else { return }
                Task {
                    guard let signalAdapter = self.appState?.adapters["signal"] as? SignalCLIAdapter else { return }
                    let ok = await signalAdapter.restartWatchDaemon()
                    if ok {
                        self.menuBarController?.setSignalHealthWarning(nil)
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        try? await self.pollEngine?.pollNow(serviceID: "signal")
                    } else {
                        self.menuBarController?.setSignalHealthWarning("Failed to restart Signal watch daemon")
                    }
                }
            }

            // Apply saved theme
            let savedTheme = UserDefaults.standard.string(forKey: "app_theme") ?? "system"
            applyTheme(savedTheme)
            menuBarController = menuBar

            let engine = PollEngine(database: db)
            engine.onPollSucceeded = { [weak self] in
                guard let self else { return }
                self.menuBarController?.setLoading(true)
                self.appState?.briefGenerationState = .summarizing
                do {
                    let newID = try await self.briefEngine?.processNewMessages(adapters: self.appState?.adapters ?? [:])
                    self.appState?.lastError = nil
                    self.appState?.briefGenerationState = newID == nil ? .noNewMessages : .complete
                    self.appState?.refreshBriefs()
                    self.appState?.nextPollDate = self.pollEngine?.nextFireDate
                    self.menuBarController?.setLoading(false)
                    if let id = newID {
                        let brief = try? self.appState?.repository.fetchBrief(id: id)
                        let body = brief?.notificationText ?? "You have new messages"
                        self.notificationManager?.post(briefID: id, title: "New messages", body: body)
                    }
                } catch {
                    self.appState?.lastError = error.localizedDescription
                    self.appState?.briefGenerationState = .failed
                    self.appState?.refreshBriefs()
                    self.appState?.nextPollDate = self.pollEngine?.nextFireDate
                    self.menuBarController?.setLoading(false)
                }
                let unread = self.appState?.unreadCount ?? 0
                self.menuBarController?.setUnreadCount(unread)
                self.menuBarController?.setBriefs(self.appState?.briefs ?? [])
                self.menuBarController?.setLastError(self.appState?.lastError)
                if let health = self.pollEngine?.currentServiceHealth {
                    self.appState?.updateServiceHealth(health)
                    if health["signal"] == .ok {
                        self.menuBarController?.setSignalHealthWarning(nil)
                    }
                }
            }

            engine.onPollFailed = { [weak self] serviceID, error in
                guard let self else { return }
                let msg = "Could not reach \(serviceID): \(error.localizedDescription)"
                self.appState?.lastError = msg
                if let health = self.pollEngine?.currentServiceHealth {
                    self.appState?.updateServiceHealth(health)
                }
                self.menuBarController?.setLastError(msg)
            }

            engine.onHealthWarning = { [weak self] serviceID, reason in
                guard let self else { return }
                if serviceID == "signal" {
                    self.menuBarController?.setSignalHealthWarning(reason)
                }
                if let health = self.pollEngine?.currentServiceHealth {
                    self.appState?.updateServiceHealth(health)
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

            let settingsRepo = SettingsRepository(database: db)
            if let account = try? settingsRepo.loadSignalAccount(), !account.isEmpty {
                let signalConfig = (try? db.dbQueue.read { db in
                    try ServiceConfig.fetchOne(db, key: "signal")
                }) ?? ServiceConfig.default(for: "signal")
                let signalAdapter = SignalCLIAdapter(accountNumber: account)
                engine.register(adapter: signalAdapter, config: signalConfig)
                state.adapters["signal"] = signalAdapter
            }

            // iMessage — always available on macOS; requires Contacts + Automation permissions.
            let imessageConfig = (try? db.dbQueue.read { db in
                try ServiceConfig.fetchOne(db, key: "imessage")
            }) ?? ServiceConfig.default(for: "imessage")
            let imessageAdapter = iMessageAdapter()
            engine.register(adapter: imessageAdapter, config: imessageConfig)
            state.adapters["imessage"] = imessageAdapter

            pollEngine = engine
            startTask = Task {
                await engine.start()
                state.nextPollDate = engine.nextFireDate
            }

            NotificationCenter.default.addObserver(
                forName: .serviceConfigDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, let db = self.database else { return }
                    let configs = (try? db.dbQueue.read { db in try ServiceConfig.fetchAll(db) }) ?? []
                    for config in configs { self.pollEngine?.reload(config: config) }
                }
            }

            // Hot-swap the LLM client when provider, API key, or consent changes in Settings.
            // Without this, revoked cloud consent only takes effect on next restart.
            NotificationCenter.default.addObserver(
                forName: .llmProviderDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let llm = self.resolvedProvider()
                    self.briefEngine?.client = llm.client
                }
            }

            state.refreshBriefs()
            state.briefGenerationState = state.briefs.isEmpty ? .noNewMessages : .cached
            menuBar.setBriefs(state.briefs)

            // Show onboarding on first launch
            if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                let onboardingController = OnboardingWindowController(database: db)
                onboardingController.onComplete = { [weak self] in
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    self?.onboardingWindowController = nil
                    self?.chatWindowController?.show()
                }
                self.onboardingWindowController = onboardingController
                onboardingController.show()
            }

        } catch {
            let alert = NSAlert()
            alert.messageText = "LLMessenger failed to start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        startTask?.cancel()
        for adapter in appState?.adapters.values ?? [:].values {
            adapter.stop()
        }
    }

    private func applyTheme(_ theme: String) {
        let appearance: NSAppearance? = switch theme {
        case "light": NSAppearance(named: .aqua)
        case "dark":  NSAppearance(named: .darkAqua)
        default:      nil
        }
        NSApp.appearance = appearance
    }

    private struct ResolvedProvider {
        let provider: LLMProvider?
        let client: LLMClient
        let model: String
        let isConfigured: Bool
    }

    private func resolvedProvider() -> ResolvedProvider {
        let repo = SettingsRepository()
        guard let provider = repo.loadSelectedLLMProvider() else {
            return ResolvedProvider(
                provider: nil,
                client: UnconfiguredLLMClient(),
                model: "",
                isConfigured: false
            )
        }

        switch provider {
        case .anthropic, .openai:
            guard let key = try? repo.loadLLMKey(provider: provider), !key.isEmpty else {
                return ResolvedProvider(
                    provider: provider,
                    client: UnconfiguredLLMClient(),
                    model: provider.defaultModel,
                    isConfigured: false
                )
            }
            guard repo.loadCloudAutoBriefsConsent() else {
                return ResolvedProvider(
                    provider: provider,
                    client: UnconfiguredLLMClient(),
                    model: provider.defaultModel,
                    isConfigured: false
                )
            }
            return ResolvedProvider(
                provider: provider,
                client: provider.makeClient(apiKey: key),
                model: provider.defaultModel,
                isConfigured: true
            )
        case .ollama:
            let savedModel = repo.loadOllamaModel()
            let model = savedModel.isEmpty ? provider.defaultModel : savedModel
            return ResolvedProvider(
                provider: provider,
                client: provider.makeClient(apiKey: nil),
                model: model,
                isConfigured: true
            )
        }
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
        let creds = SettingsRepository().loadTelegramCredentials()
        let apiId   = creds.apiId.isEmpty   ? (ProcessInfo.processInfo.environment["TELEGRAM_API_ID"]   ?? "") : creds.apiId
        let apiHash = creds.apiHash.isEmpty ? (ProcessInfo.processInfo.environment["TELEGRAM_API_HASH"] ?? "") : creds.apiHash
        return [
            "api_id":       apiId,
            "api_hash":     apiHash,
            "session_path": sessionPath
        ]
    }
}
