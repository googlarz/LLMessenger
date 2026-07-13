// AppState+Tasks.swift
//
// Task strip: refresh and complete.

import AppKit
import Foundation
import GRDB

extension AppState {
    func refreshTasks() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let fetched = (try? self.repository.fetchPendingTasks()) ?? []
            await MainActor.run { self.tasks = fetched }
        }
    }

    func completeTask(_ taskID: Int64) {
        do {
            try repository.completeTask(id: taskID)
            refreshTasks()
            showReceipt("Task completed.", actionTitle: "Undo") { [weak self] in
                guard let self else { return }
                do {
                    try self.repository.reopenTask(id: taskID)
                    self.refreshTasks()
                    self.productLoveMetrics = ProductLoveMetricStore.recordUndo(defaults: self.defaults)
                } catch {
                    self.lastError = self.friendly(error)
                }
            }
        } catch {
            lastError = friendly(error)
        }
    }
}
