// AppState+Factories.swift
//
// View-model and repository factories + demo mode entry.

import AppKit
import Foundation
import GRDB

extension AppState {
    func makeChatViewModel() -> ChatViewModel {
        ChatViewModel(appState: self)
    }

    func makeSettingsRepository() -> SettingsRepository {
        SettingsRepository(database: database)
    }

    func startDemoMode() {
        do {
            try DemoSeeder.seed(into: database)
            productLoveMetrics = ProductLoveMetricStore.recordDemoStart()
            let task = refreshBriefs()
            Task { @MainActor in
                await task.value
                selectedBriefID = try? repository.latestBriefID()
                showReceipt("Sample command center opened. This is synthetic demo data.")
            }
        } catch {
            lastError = friendly(error)
        }
    }
}
