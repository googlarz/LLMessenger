// LLMessenger/Core/DiagnosticsReporter.swift
//
// User-initiated diagnostics export (About tab). Deliberately contains NO
// message content, sender names, conversation titles, or credentials —
// versions, table counts, service health, store integrity, and any local
// crash reports. Safe to attach to a support email.

import AppKit
import Foundation
import GRDB

@MainActor
enum DiagnosticsReporter {

    static func generate(database: AppDatabase) -> String {
        var lines: [String] = []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        lines.append("LLMessenger diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Version: \(version) (\(build))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Demo mode: \(DemoSeeder.isActive ? "active" : "off")")
        lines.append("")

        lines.append("== Store ==")
        do {
            try database.integrityCheck()
            lines.append("Integrity: ok")
        } catch {
            lines.append("Integrity: FAILED — \(error.localizedDescription)")
        }
        let counts = (try? database.dbQueue.read { db -> [String] in
            try ["briefs", "messages", "briefCards", "briefCardSources", "tasks", "serviceConfig"].map {
                "\($0): \(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1) rows"
            }
        }) ?? ["table counts unavailable"]
        lines.append(contentsOf: counts)
        lines.append("")

        lines.append("== Service health ==")
        let health = (try? SettingsRepository(database: database).loadAllServiceHealth()) ?? [:]
        if health.isEmpty {
            lines.append("No health records.")
        } else {
            for (service, record) in health.sorted(by: { $0.key < $1.key }) {
                let checked = record.lastCheck.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
                lines.append("\(service): \(record.status) · last check \(checked)")
            }
        }
        lines.append("")

        let crashes = CrashGuard.pendingReports()
        lines.append("== Crash reports (\(crashes.count)) ==")
        for url in crashes.prefix(5) {
            lines.append("--- \(url.lastPathComponent) ---")
            lines.append((try? String(contentsOf: url, encoding: .utf8)) ?? "(unreadable)")
        }

        return lines.joined(separator: "\n")
    }

    /// Prompts for a destination and writes the report.
    static func export(database: AppDatabase) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LLMessenger-diagnostics.txt"
        panel.title = "Export Diagnostics"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? generate(database: database).write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
