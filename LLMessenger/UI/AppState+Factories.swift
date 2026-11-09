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
            productLoveMetrics = ProductLoveMetricStore.recordDemoStart(defaults: defaults)
            let task = refreshBriefs()
            Task { @MainActor in
                await task.value
                selectedBriefID = try? repository.latestBriefID()
                // The seeded data has a digest but no drafts or owed replies, so
                // Act would open nearly empty. Land where the sample content is.
                requestedSection = .digests
                showReceipt("Sample command center opened. This is synthetic demo data.")
            }
        } catch {
            lastError = friendly(error)
        }
    }
}
