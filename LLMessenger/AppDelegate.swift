// LLMessenger/AppDelegate.swift
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?
    var pollEngine: PollEngine?
    var briefEngine: BriefEngine?
    var chatWindowController: ChatWindowController?
    var appState: AppState?
    var database: AppDatabase?
    var notificationManager: NotificationManager?
    var startTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let db = try AppDatabase()
            database = db

            let llmClient = makeLLMClient()
            let model = preferredModel()

            let state = AppState(
                database: db,
                llmClient: llmClient,
                llmModel: model,
                basePrompt: PromptBuilder.defaultBasePrompt
            )
            appState = state

            briefEngine = BriefEngine(
                database: db,
                client: llmClient,
                model: model,
                basePrompt: PromptBuilder.defaultBasePrompt
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
            menuBar.onTogglePanel = { [weak windowController] in
                windowController?.toggle()
            }
            menuBarController = menuBar

            let engine = PollEngine(database: db)
            engine.onPollSucceeded = { [weak self] in
                guard let self else { return }
                let newID: Int64? = (try? await self.briefEngine?.processNewMessages()) ?? nil
                self.appState?.refreshBriefs()
                if let id = newID {
                    let brief = try? self.appState?.repository.fetchBrief(id: id)
                    let body = brief?.notificationText ?? "You have new messages"
                    self.notificationManager?.post(briefID: id, title: "New messages", body: body)
                }
                let unread = self.appState?.unreadCount ?? 0
                self.menuBarController?.setUnreadCount(unread)
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

            pollEngine = engine
            startTask = Task { await engine.start() }

            state.refreshBriefs()

        } catch {
            let alert = NSAlert()
            alert.messageText = "LLMessenger failed to start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func makeLLMClient() -> LLMClient {
        let store = KeychainStore()
        if let key = try? store.get(account: "anthropic"), !key.isEmpty {
            return LLMProvider.anthropic.makeClient(apiKey: key)
        }
        if let key = try? store.get(account: "openai"), !key.isEmpty {
            return LLMProvider.openai.makeClient(apiKey: key)
        }
        return LLMProvider.ollama.makeClient(apiKey: nil)
    }

    private func preferredModel() -> String {
        let store = KeychainStore()
        if (try? store.get(account: "anthropic")) != nil {
            return LLMProvider.anthropic.defaultModel
        }
        if (try? store.get(account: "openai")) != nil {
            return LLMProvider.openai.defaultModel
        }
        return LLMProvider.ollama.defaultModel
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
        return [
            "api_id":       ProcessInfo.processInfo.environment["TELEGRAM_API_ID"] ?? "",
            "api_hash":     ProcessInfo.processInfo.environment["TELEGRAM_API_HASH"] ?? "",
            "session_path": sessionPath
        ]
    }
}
