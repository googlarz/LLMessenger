import Foundation
import GRDB

/// Owns every path that turns pending messages into user-visible briefs. Menu,
/// timer, and digest triggers share one state/notification pipeline so they
/// cannot race or drift into different firewall behavior.
@MainActor
final class BriefRefreshCoordinator {
    private enum NotificationMode {
        case firewall(defaultTitle: String)
        case digest(defaultTitle: String, heldBack: Int)
    }

    private let database: AppDatabase
    private let state: AppState
    private let pollEngine: PollEngine
    private let briefEngine: BriefEngine
    private let notificationManager: NotificationManager
    private let menuBarController: MenuBarController
    private let minimumLoadingDuration: TimeInterval
    private var refreshInFlight = false
    private var pollRefreshPending = false
    private var digestRefreshPending = false

    init(
        database: AppDatabase,
        state: AppState,
        pollEngine: PollEngine,
        briefEngine: BriefEngine,
        notificationManager: NotificationManager,
        menuBarController: MenuBarController,
        minimumLoadingDuration: TimeInterval = 1.5
    ) {
        self.database = database
        self.state = state
        self.pollEngine = pollEngine
        self.briefEngine = briefEngine
        self.notificationManager = notificationManager
        self.menuBarController = menuBarController
        self.minimumLoadingDuration = minimumLoadingDuration
    }

    func refreshNow() async {
        guard claimRefresh() else { return }
        defer { finishRefresh() }
        let startedAt = beginLoading(state: .fetching)
        // This caller owns generation. Suppressing PollEngine's success handler
        // prevents the same batch from being summarized once in the callback and
        // then immediately summarized again here.
        _ = await pollEngine.pollAll(invokeSuccessHandler: false)
        let failedServices = pollEngine.currentServiceHealth
            .filter { $0.value != .ok }
            .keys
            .sorted()
        let pollWarning = failedServices.isEmpty
            ? nil
            : "Could not reach: \(failedServices.joined(separator: ", ")). Check permissions in System Settings."
        state.nextPollDate = pollEngine.nextFireDate
        updateServiceHealth()

        do {
            _ = try await generatePendingBriefs(
                notificationMode: .firewall(defaultTitle: "New messages"),
                selectLatest: true,
                eligibleServiceIDs: nil
            )
            state.lastError = pollWarning
        } catch {
            state.lastError = error.localizedDescription
            state.briefGenerationState = .failed
        }
        await finishLoading(startedAt: startedAt)
    }

    func refreshHistory(hours: Int, title: String) async {
        guard claimRefresh() else { return }
        defer { finishRefresh() }
        let startedAt = beginLoading(state: .fetching)
        await generateHistory(hours: hours, title: title, postNotification: true)
        await finishLoading(startedAt: startedAt)
    }

    func buildHistory(hours: Int) async {
        guard claimRefresh() else { return }
        defer { finishRefresh() }
        state.briefGenerationState = .summarizing
        await generateHistory(hours: hours, title: "Summary", postNotification: false)
        await reloadStateAndMenu()
    }

    func processPollSuccess() async {
        guard claimRefresh() else {
            pollRefreshPending = true
            return
        }
        defer { finishRefresh() }
        menuBarController.setLoading(true)
        do {
            _ = try await generatePendingBriefs(
                notificationMode: .firewall(defaultTitle: "New messages"),
                selectLatest: false,
                eligibleServiceIDs: pollEngine.automaticBriefServiceIDs
            )
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
            state.briefGenerationState = .failed
        }
        state.nextPollDate = pollEngine.nextFireDate
        updateServiceHealth()
        await reloadStateAndMenu()
        menuBarController.setLoading(false)
    }

    func processDigest() async {
        guard claimRefresh() else {
            digestRefreshPending = true
            return
        }
        defer { finishRefresh() }
        let settings = SettingsRepository()
        let heldBack = settings.loadFirewallHeldBack()
        do {
            let ids = try await generatePendingBriefs(
                notificationMode: .digest(defaultTitle: "Morning Brief", heldBack: heldBack),
                selectLatest: false,
                eligibleServiceIDs: pollEngine.automaticBriefServiceIDs
            )
            if !ids.isEmpty {
                settings.resetFirewallHeldBack()
            } else if let content = BriefNotificationPolicy.heldBackDigestContent(count: heldBack),
                      let briefID = try state.repository.latestBriefID() {
                notificationManager.post(
                    briefID: briefID,
                    title: content.title,
                    body: content.body
                )
                settings.resetFirewallHeldBack()
            }
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
            state.briefGenerationState = .failed
        }
        await reloadStateAndMenu()
    }

    private func generatePendingBriefs(
        notificationMode: NotificationMode,
        selectLatest: Bool,
        eligibleServiceIDs: Set<String>?
    ) async throws -> [Int64] {
        state.briefGenerationState = .summarizing
        let ids = try await briefEngine.processNewMessageBatch(
            adapters: state.adapters,
            eligibleServiceIDs: eligibleServiceIDs
        )
        if let latestID = ids.last {
            if selectLatest {
                state.selectBriefKeepingDraft(latestID)
            }
            await writeWidget(briefID: latestID)
        }
        postNotifications(for: ids, mode: notificationMode)
        state.briefGenerationState = ids.isEmpty ? .noNewMessages : .complete
        return ids
    }

    private func generateHistory(
        hours: Int,
        title: String,
        postNotification: Bool
    ) async {
        state.briefGenerationState = .summarizing
        do {
            if let briefID = try await briefEngine.summarizeLast(
                hours: hours,
                adapters: state.adapters
            ) {
                state.selectBriefKeepingDraft(briefID)
                state.briefGenerationState = .complete
                state.lastError = nil
                await writeWidget(briefID: briefID)
                if postNotification {
                    let brief = try? state.repository.fetchBrief(id: briefID)
                    let content = notificationContent(for: brief, defaultTitle: title)
                    notificationManager.post(
                        briefID: briefID,
                        title: content.title,
                        body: content.body
                    )
                }
            } else {
                state.briefGenerationState = .noNewMessages
                state.lastError = nil
            }
        } catch {
            state.lastError = error.localizedDescription
            state.briefGenerationState = .failed
        }
    }

    private func postNotifications(for ids: [Int64], mode: NotificationMode) {
        let settings = SettingsRepository()
        for (index, id) in ids.enumerated() {
            let brief = try? state.repository.fetchBrief(id: id)
            let cards = canonicalCards(for: brief)
            switch mode {
            case .firewall(let defaultTitle):
                let highPriorityCount = BriefNotificationPolicy.highPriorityCount(
                    cards: cards,
                    effectivePriority: state.effectivePriority
                )
                if settings.loadFirewallEnabled(), highPriorityCount == 0 {
                    settings.incrementFirewallHeldBack(by: 1)
                    continue
                }
                let content = notificationContent(for: brief, defaultTitle: defaultTitle)
                notificationManager.post(briefID: id, title: content.title, body: content.body)

            case .digest(let defaultTitle, let heldBack):
                let content = notificationContent(for: brief, defaultTitle: defaultTitle)
                let isLast = index == ids.count - 1
                let body = heldBack > 0 && isLast
                    ? "\(content.body) · \(heldBack) routine update\(heldBack == 1 ? "" : "s") held back"
                    : content.body
                notificationManager.post(briefID: id, title: content.title, body: body)
            }
        }
    }

    private func notificationContent(
        for brief: Brief?,
        defaultTitle: String
    ) -> (title: String, body: String) {
        BriefNotificationPolicy.content(
            cards: canonicalCards(for: brief),
            defaultTitle: defaultTitle,
            defaultBody: brief?.notificationText ?? "You have new messages",
            effectivePriority: state.effectivePriority
        )
    }

    private func canonicalCards(for brief: Brief?) -> [BriefCard] {
        guard let brief else { return [] }
        if let id = brief.id,
           let records = try? state.repository.fetchBriefCards(briefID: id),
           !records.isEmpty {
            return records.map(\.briefCard)
        }
        return BriefJSON.decodedCached(for: brief)?.cards ?? []
    }

    private func writeWidget(briefID: Int64) async {
        let brief = try? state.repository.fetchBrief(id: briefID)
        let cards = (try? await database.dbQueue.read { db in
            try BriefCardRecord
                .filter(Column("briefId") == briefID)
                .order(Column("position").asc)
                .fetchAll(db)
        }) ?? []
        WidgetDataProvider.write(
            briefID: briefID,
            cards: cards,
            openingSummary: brief?.openingSummary
        )
    }

    private func beginLoading(state generationState: BriefGenerationState) -> Date {
        state.briefGenerationState = generationState
        menuBarController.setLoading(true)
        return Date()
    }

    private func finishLoading(startedAt: Date) async {
        let remaining = minimumLoadingDuration - Date().timeIntervalSince(startedAt)
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        await reloadStateAndMenu()
        menuBarController.setLoading(false)
    }

    private func reloadStateAndMenu() async {
        await state.refreshBriefs().value
        menuBarController.setBriefs(state.briefs)
        menuBarController.setLastError(state.lastError)
        menuBarController.setUnreadCount(state.unreadCount)
    }

    private func updateServiceHealth() {
        let health = pollEngine.currentServiceHealth
        state.updateServiceHealth(health)
        if health["signal"] == .ok {
            menuBarController.setSignalHealthWarning(nil)
        }
    }

    private func claimRefresh() -> Bool {
        guard !refreshInFlight else { return false }
        refreshInFlight = true
        return true
    }

    private func finishRefresh() {
        refreshInFlight = false
        if digestRefreshPending {
            digestRefreshPending = false
            pollRefreshPending = false
            Task { @MainActor [weak self] in
                await self?.processDigest()
            }
        } else if pollRefreshPending {
            pollRefreshPending = false
            Task { @MainActor [weak self] in
                await self?.processPollSuccess()
            }
        }
    }
}
