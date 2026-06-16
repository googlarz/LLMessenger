// LLMessenger/AppDelegate.swift
import AppKit
import GRDB

extension UserDefaults {
    @objc dynamic var realtimeFirewallDisabled: Bool {
        return bool(forKey: "realtimeFirewallDisabled")
    }
}

extension Notification.Name {
    static let serviceConfigDidChange = Notification.Name("com.llmessenger.serviceConfigDidChange")
    /// Posted by LLMSettingsTab when provider, API key, or cloud consent changes.
    /// AppDelegate observes this to hot-swap the LLM client without requiring a restart.
    static let llmProviderDidChange = Notification.Name("com.llmessenger.llmProviderDidChange")
    /// Posted after any health-record write (retry, poll completion, error). The
    /// Settings tab listens to re-read the health dict and repaint cards.
    static let serviceHealthDidChange = Notification.Name("com.llmessenger.serviceHealthDidChange")
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
    var updateChecker: UpdateChecker?
    var digestScheduler: DigestScheduler?
    var realtimeMonitor: RealtimeMonitor?
    var realtimeKillSwitchObserver: NSKeyValueObservation?
    var agentEngine: AgentEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        CrashGuard.install()
        do {
            let db = try AppDatabase.production()
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
            windowController.onRetryService = { [weak self] serviceID in
                guard let self else { return }
                Task { @MainActor in await self.retryService(serviceID) }
            }

            let notifications = NotificationManager()
            notifications.requestPermission()
            notifications.onNotificationTap = { [weak windowController, weak state] briefID in
                state?.selectedBriefID = briefID
                state?.markAsOpen(briefID: briefID)
                windowController?.show(selectingBriefID: briefID)
            }
            notificationManager = notifications

            let menuBar = MenuBarController()
            // Shared by the menu bar's "New Brief" and the brief header's
            // "Refresh" — full poll → summarize → notify cycle. Call sites
            // track their own instrumentation source.
            let runBriefRefresh: () -> Void = { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
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
                            // Notification firewall: routine briefs stay silent;
                            // only high-priority items earn an interruption.
                            let settingsRepo = SettingsRepository()
                            if settingsRepo.loadFirewallEnabled() && self.highPriorityCardCount(brief: brief) == 0 {
                                settingsRepo.incrementFirewallHeldBack(by: 1)
                            } else {
                                let (title, body) = self.highPriorityNotification(brief: brief, defaultTitle: "New messages")
                                self.notificationManager?.post(briefID: id, title: title, body: body)
                            }
                            let cards: [BriefCardRecord]
                            if let dbQueue = self.database?.dbQueue {
                                cards = (try? await dbQueue.read { db in
                                    try BriefCardRecord.filter(Column("briefId") == id).fetchAll(db)
                                }) ?? []
                            } else {
                                cards = []
                            }
                            WidgetDataProvider.write(briefID: id, cards: cards, openingSummary: brief?.openingSummary)
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
            menuBar.onNewBrief = {
                InstrumentationManager.shared.track(event: .refreshTriggered, metadata: ["source": "menuBar"])
                runBriefRefresh()
            }
            state.onRequestRefresh = runBriefRefresh
            menuBar.onLast24h = { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appState?.briefGenerationState = .fetching
                    self.menuBarController?.setLoading(true)
                    let start = Date()
                    let adapters = self.appState?.adapters ?? [:]
                    do {
                        self.appState?.briefGenerationState = .summarizing
                        if let briefID = try await self.briefEngine?.summarizeLast(hours: 48, adapters: adapters) {
                            let brief = try? self.appState?.repository.fetchBrief(id: briefID)
                            let (title, body) = self.highPriorityNotification(brief: brief, defaultTitle: "48h Summary")
                            self.notificationManager?.post(briefID: briefID, title: title, body: body)
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
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appState?.briefGenerationState = .fetching
                    self.menuBarController?.setLoading(true)
                    let start = Date()
                    let adapters = self.appState?.adapters ?? [:]
                    do {
                        self.appState?.briefGenerationState = .summarizing
                        if let briefID = try await self.briefEngine?.summarizeLast(hours: 168, adapters: adapters) {
                            let brief = try? self.appState?.repository.fetchBrief(id: briefID)
                            let (title, body) = self.highPriorityNotification(brief: brief, defaultTitle: "7-Day Summary")
                            self.notificationManager?.post(briefID: briefID, title: title, body: body)
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
            let runSetupWizard: () -> Void = { [weak self] in
                guard let self else { return }
                UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
                let controller = OnboardingWindowController(database: db)
                controller.onComplete = { [weak self] in
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    self?.onboardingWindowController = nil
                    self?.didFinishOnboarding()
                }
                self.onboardingWindowController = controller
                controller.show()
            }
            settingsController.onRunSetup = runSetupWizard
            state.onExitDemo = { [weak state] in
                guard let state else { return }
                try? DemoSeeder.wipe(from: state.database)
                state.selectedBriefID = nil
                state.refreshBriefs()
                runSetupWizard()
            }
            settingsController.onBuild7DaySummaries = { [weak self] in
                guard let self else { return }
                let adapters = self.appState?.adapters ?? [:]
                self.appState?.briefGenerationState = .summarizing
                do {
                    let newBriefID = try await self.briefEngine?.summarizeLast(hours: 168, adapters: adapters)
                    self.appState?.briefGenerationState = .complete
                    self.appState?.lastError = nil
                    // Auto-select so the brief opens immediately instead of sitting unread in the list.
                    if let id = newBriefID { self.appState?.selectedBriefID = id }
                } catch {
                    self.appState?.briefGenerationState = .failed
                    self.appState?.lastError = error.localizedDescription
                }
                self.appState?.refreshBriefs()
            }
            settingsController.onSyncContacts = { [weak self] in
                self?.appState?.contactDirectory.refresh()
            }
            settingsController.onRetryService = { [weak self] serviceID in
                guard let self else { return }
                await self.retryService(serviceID)
            }
            settingsController.onScheduleChanged = { [weak self] in
                guard let self else { return }
                let settings = SettingsRepository().loadDigestSettings()
                self.digestScheduler?.reschedule(settings: settings)
            }
            let openSettings: () -> Void = { [weak settingsController] in settingsController?.show() }
            menuBar.onOpenSettings = openSettings
            state.onOpenSettings = openSettings

            state.onBriefsChanged = { [weak self] in
                guard let self else { return }
                self.menuBarController?.setUnreadCount(self.appState?.unreadCount ?? 0)
                self.menuBarController?.setBriefs(self.appState?.briefs ?? [])
                self.menuBarController?.setNowNeedsAttention(self.appState?.nowNeedsAttention ?? false)
                self.menuBarController?.setOwedCount(self.appState?.owedCount ?? 0)
                self.menuBarController?.setActionsReady(self.appState?.actionsReadyCount ?? 0)
                self.menuBarController?.setArmedAutoSendCount(self.appState?.armedAutoSendCount ?? 0)
            }
            menuBar.onUndoAutoSends = { [weak self] in self?.appState?.undoAllAutoSends() }

            menuBar.onRestartSignalWatch = { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
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
                        let (title, body) = self.highPriorityNotification(brief: brief, defaultTitle: "New messages")
                        self.notificationManager?.post(briefID: id, title: title, body: body)
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

            // Register every service that's configurable. Each is a no-op if its
            // prerequisites aren't met (Signal account empty, Telegram binary missing,
            // Slack workspace list empty, etc) — reregisterAdapter() re-runs the same
            // logic later when the user adds credentials in Settings or clicks Retry.
            for svc in ["telegram", "signal", "imessage", "slack"] {
                self.registerAdapter(serviceID: svc, engine: engine, db: db, state: state)
            }

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
                    guard let self, let db = self.database,
                          let engine = self.pollEngine, let state = self.appState
                    else { return }
                    let configs = (try? db.dbQueue.read { db in try ServiceConfig.fetchAll(db) }) ?? []
                    for config in configs { engine.reload(config: config) }
                    // Adapters added after launch (e.g. user pastes Signal account or
                    // a Slack token) need to actually be instantiated and started.
                    // reload() only updates configs of already-registered adapters.
                    for svc in ["telegram", "signal", "imessage", "slack"] {
                        self.registerAdapter(serviceID: svc, engine: engine, db: db, state: state)
                    }
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

            // refreshBriefs loads off the main actor — await it before reading
            // state.briefs, which was previously always empty at this point.
            Task { @MainActor [weak self] in
                guard let self, let state = self.appState else { return }
                await state.refreshBriefs().value
                state.briefGenerationState = state.briefs.isEmpty ? .noNewMessages : .cached
                self.menuBarController?.setBriefs(state.briefs)
                self.menuBarController?.setUnreadCount(state.unreadCount)
            }

            let checker = UpdateChecker()
            checker.onUpdateAvailable = { [weak self] update in
                self?.menuBarController?.setAvailableUpdate(update)
            }
            updateChecker = checker
            checker.checkIfDue()

            // Morning Digest — fire brief generation + notification at scheduled time
            let digest = DigestScheduler()
            digest.onFire = { [weak self] in
                guard let self, let engine = self.briefEngine, let state = self.appState else { return }
                state.briefGenerationState = .summarizing
                do {
                    let newID = try await engine.processNewMessages(adapters: state.adapters)
                    state.briefGenerationState = newID == nil ? .noNewMessages : .complete
                    state.refreshBriefs()
                    if let id = newID {
                        let brief = try? state.repository.fetchBrief(id: id)
                        let (title, body) = self.highPriorityNotification(brief: brief, defaultTitle: "Morning Brief")
                        // Surface what the firewall silenced since the last digest.
                        let settingsRepo = SettingsRepository()
                        let heldBack = settingsRepo.loadFirewallHeldBack()
                        let digestBody = heldBack > 0
                            ? "\(body) · \(heldBack) routine update\(heldBack == 1 ? "" : "s") held back"
                            : body
                        settingsRepo.resetFirewallHeldBack()
                        self.notificationManager?.post(briefID: id, title: title, body: digestBody)
                    }
                } catch {
                    state.briefGenerationState = .failed
                }
            }
            digestScheduler = digest
            digest.start(settings: SettingsRepository().loadDigestSettings())

            // Real-Time Firewall (P3)
            let monitor = RealtimeMonitor(
                adapters: state.adapters,
                db: db,
                notificationManager: notifications,
                llmClient: llm.client,
                rulesProvider: {
                    (try? await db.dbQueue.read { db in try PriorityRule.fetchAll(db) }) ?? []
                }
            )
            realtimeMonitor = monitor
            Task { await monitor.start() }

            realtimeKillSwitchObserver = UserDefaults.standard.observe(
                \.realtimeFirewallDisabled, options: [.new]
            ) { [weak self] _, change in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, let monitor = self.realtimeMonitor else { return }
                    if change.newValue == true {
                        await monitor.stop()
                    } else {
                        await monitor.start()
                    }
                }
            }

            // Agent (P1) — proposes actions you approve. Mirrors realtimeMonitor wiring.
            let agent = AgentEngine(
                db: db,
                llmClient: llm.client,
                llmModel: llm.model,
                repository: state.repository,
                rulesProvider: {
                    (try? await db.dbQueue.read { db in try PriorityRule.fetchAll(db) }) ?? []
                }
            )
            agentEngine = agent
            // P5: let the command bar run a planning cycle on demand.
            state.onTriggerAgentCycle = { [weak agent] in
                await agent?.trigger()
            }
            Task { [weak self] in
                await agent.setOnActionsChanged {
                    await MainActor.run {
                        self?.appState?.reloadAgentActions()
                    }
                }
                await agent.start()
            }

            // Show onboarding on first launch
            if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                let onboardingController = OnboardingWindowController(database: db)
                onboardingController.onComplete = { [weak self] in
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    self?.onboardingWindowController = nil
                    self?.didFinishOnboarding()
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

    /// Routes onboarding completion: demo mode lands directly on the seeded
    /// morning brief with every service quiet; the normal path just shows
    /// the panel.
    private func didFinishOnboarding() {
        if DemoSeeder.isActive {
            for service in ["imessage", "signal", "telegram", "slack"] {
                var config = ServiceConfig.default(for: service)
                config.enabled = false
                pollEngine?.reload(config: config)
            }
            appState?.refreshBriefs()
            let latest = (try? appState?.repository.latestBriefID()) ?? nil
            chatWindowController?.show(selectingBriefID: latest)
        } else {
            chatWindowController?.show()
        }
    }

    /// Reopen events (Dock-less `open -a LLMessenger`, Spotlight relaunch)
    /// should surface the panel — standard menu-bar-app behaviour.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { chatWindowController?.show() }
        return true
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
        // Local-only mode short-circuits provider selection: Ollama only, no cloud LLMs.
        if repo.loadLocalOnlyMode() {
            let savedModel = repo.loadOllamaModel()
            let provider: LLMProvider = .ollama
            let model = savedModel.isEmpty ? provider.defaultModel : savedModel
            return ResolvedProvider(
                provider: provider,
                client: provider.makeClient(apiKey: nil),
                model: model,
                isConfigured: true
            )
        }

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
        case .appleIntelligence:
            return ResolvedProvider(
                provider: provider,
                client: provider.makeClient(apiKey: nil),
                model: provider.defaultModel,
                isConfigured: AppleFM.isAvailable
            )
        }
    }

    /// Shared retry handler — wired to both the chrome chip and the per-card
    /// "Retry now" button. Ensures the adapter exists (re-registers from settings
    /// if needed), takes service-specific auto-repair actions before polling
    /// (e.g. restart the Signal watch daemon if it looks stuck), polls once,
    /// and surfaces any failure via appState.lastError so the user sees what
    /// actually went wrong instead of a silent no-op or a vague "daemon stuck".
    @MainActor
    private func retryService(_ serviceID: String) async {
        guard let engine = pollEngine, let db = database, let state = appState else { return }
        // If credentials were added after launch, register the adapter on demand.
        registerAdapter(serviceID: serviceID, engine: engine, db: db, state: state)

        guard state.adapters[serviceID] != nil else {
            state.lastError = "\(Theme.serviceName(serviceID)) isn't configured yet — set it up in Settings → Services first."
            return
        }

        // Service-specific auto-repair: don't just tell the user the daemon
        // might be stuck — *fix* it before polling.
        if serviceID == "signal",
           let signal = state.adapters["signal"] as? SignalCLIAdapter {
            _ = await signal.restartWatchDaemon()
            // Brief pause so the daemon's first poll lands before we retry.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if serviceID == "telegram" {
            // Clean up SQLite rollback journals left by a previously crashed
            // adapter process. Pyrogram opens session.session and sees the
            // .session-journal file as "another writer mid-transaction",
            // failing with "database is locked" even when no process holds it.
            let sessionDir = NSHomeDirectory() + "/.config/llmessenger/data/telegram"
            let leftovers = ["session.session-journal", "session.session-wal", "session.session-shm"]
            for f in leftovers {
                try? FileManager.default.removeItem(atPath: "\(sessionDir)/\(f)")
            }
        }

        do {
            try await engine.pollNow(serviceID: serviceID)
            state.lastError = nil
        } catch {
            state.lastError = "\(Theme.serviceName(serviceID)) retry failed: \(error.localizedDescription)"
        }
        state.updateServiceHealth(engine.currentServiceHealth)
        // Tell the Settings tab to re-read health from the DB so the card repaints
        // green/red without the user having to navigate away and back.
        NotificationCenter.default.post(name: .serviceHealthDidChange, object: nil)
    }

    /// Registers (or refreshes) a single service adapter from current settings.
    /// Safe to call repeatedly — skipping a service if prerequisites aren't met,
    /// replacing an existing registration when something changed. Used at launch,
    /// when settings change, and when the user clicks Retry on a broken service.
    @MainActor
    private func registerAdapter(serviceID: String,
                                 engine: PollEngine,
                                 db: AppDatabase,
                                 state: AppState) {
        let config = (try? db.dbQueue.read { db in
            try ServiceConfig.fetchOne(db, key: serviceID)
        }) ?? ServiceConfig.default(for: serviceID)
        let isLocalOnly = SettingsRepository().loadLocalOnlyMode()

        switch serviceID {
        case "imessage":
            // iMessage is always available; FDA/permission errors surface via health.
            if state.adapters["imessage"] == nil {
                let adapter = iMessageAdapter()
                engine.register(adapter: adapter, config: config)
                state.adapters["imessage"] = adapter
            }

        case "signal":
            let repo = SettingsRepository(database: db)
            guard let account = try? repo.loadSignalAccount(), !account.isEmpty else { return }
            // Replace existing adapter if account changed.
            if let existing = state.adapters["signal"] as? SignalCLIAdapter {
                existing.stop()
            }
            let adapter = SignalCLIAdapter(accountNumber: account)
            engine.register(adapter: adapter, config: config)
            state.adapters["signal"] = adapter

        case "telegram":
            guard let binaryPath = telegramAdapterPath() else { return }
            // If a Telegram adapter is already registered, leave it alone — the
            // engine will call its start() on the next poll, which handles
            // relaunching a dead subprocess. We used to short-circuit ALL retries
            // here, but if the previous Telegram process died (broken pipe / crash)
            // it left the session.session SQLite lock held; the next click of
            // Retry needs to first stop() the dead adapter so its file handles
            // close, then re-register.
            if let existing = state.adapters["telegram"] as? SubprocessAdapter {
                existing.stop()
            }
            let adapter = SubprocessAdapter(
                serviceID: "telegram",
                adapterPath: binaryPath,
                config: telegramAdapterConfig()
            )
            engine.register(adapter: adapter, config: config)
            state.adapters["telegram"] = adapter

        case "slack":
            guard !isLocalOnly, !SlackWorkspaceStore.load().isEmpty else { return }
            if let existing = state.adapters["slack"] as? SlackAdapter {
                existing.reloadWorkspaces()
                return
            }
            let adapter = SlackAdapter()
            engine.register(adapter: adapter, config: config)
            state.adapters["slack"] = adapter

        default:
            break
        }
    }

    /// Builds a high-priority-aware notification title and body for a brief.
    /// When the brief contains at least one high-priority card, the title names
    /// the count and the body is the top high-priority headline.
    /// Falls back to the generic "New messages" / notificationText pair.
    private func highPriorityCardCount(brief: Brief?) -> Int {
        (BriefJSON.decodeLenient(from: brief?.openingSummary)?.cards.filter { $0.priority == "high" }.count) ?? 0
    }

    private func highPriorityNotification(brief: Brief?, defaultTitle: String) -> (title: String, body: String) {
        let defaultBody = brief?.notificationText ?? "You have new messages"
        guard let parsed = BriefJSON.decodeLenient(from: brief?.openingSummary)
        else {
            return (defaultTitle, defaultBody)
        }
        let highCards = parsed.cards.filter { $0.priority == "high" }
        guard !highCards.isEmpty, let topHeadline = highCards.first?.headline else {
            return (defaultTitle, defaultBody)
        }
        let title = highCards.count == 1 ? "1 item needs your reply" : "\(highCards.count) items need your reply"
        return (title, topHeadline)
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
