// LLMessenger/Core/DataExporter.swift
//
// Backup / restore for the single-device ceiling: everything lives in one
// SQLite store + a handful of UserDefaults keys, so a reinstall or a second
// Mac otherwise means total amnesia (see the architecture-limits review).
// This does NOT export credentials — those stay in Keychain and must be
// re-entered; exporting secrets to a plain file would be a security regression.

import AppKit
import Foundation
import GRDB

@MainActor
enum DataExporter {

    /// Behavioral UserDefaults keys worth carrying across a reinstall/new Mac.
    /// Deliberately excludes anything credential-shaped (those live in Keychain)
    /// and anything purely session-local (window frames, transient UI state).
    static let exportedDefaultsKeys: [String] = [
        "handledCardKeys",
        "hasCompletedOnboarding",
        "realtimeFirewallDisabled",
        "showActionsReadyInMenuBar",
        "showOwedCountInMenuBar",
        "loveMetrics.firstSeenAt",
        "loveMetrics.activeDays",
        "loveMetrics.handledCards",
        "loveMetrics.priorityCorrections",
        "loveMetrics.quietedThreads",
        "loveMetrics.openedDigests",
        "loveMetrics.guideDismissed",
        "loveMetrics.firstRealDigestAcknowledged"
    ]

    private static let exportTableName = "exportedUserDefaults"

    // MARK: - Export

    static func export(database: AppDatabase) {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "LLMessenger-backup-\(stamp).llmessengerbackup"
        panel.title = "Export Backup"
        panel.message = "Saves your digest history, learned context, and preferences. " +
                        "Credentials are NOT included — you'll sign back in to each service."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try writeBackup(database: database, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Writes a full consistent copy of `database` to `url`, then appends a table
    /// holding the exported UserDefaults keys as JSON-encoded strings. Testable
    /// entry point — `export(database:)` is the NSSavePanel-driven UI wrapper.
    static func writeBackup(database: AppDatabase, to url: URL,
                            defaults: UserDefaults = .standard) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let dest = try DatabaseQueue(path: url.path)
        try database.dbQueue.backup(to: dest)
        try dest.write { db in
            try db.create(table: exportTableName, ifNotExists: true) { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text)
            }
            for key in exportedDefaultsKeys {
                guard let value = defaults.object(forKey: key) else { continue }
                let json = try? JSONSerialization.data(withJSONObject: ["v": value], options: [])
                guard let json, let jsonString = String(data: json, encoding: .utf8) else { continue }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO \(exportTableName) (key, value) VALUES (?, ?)",
                    arguments: [key, jsonString]
                )
            }
        }
        // Closing the last connection to a WAL-mode database triggers SQLite's
        // automatic checkpoint, folding -wal content back into the main file —
        // without this the exported .llmessengerbackup could be missing recent
        // writes if opened by anything other than another GRDB connection.
        try dest.close()
    }

    // MARK: - Import

    /// Presents an open panel, then replaces the live store with the chosen
    /// backup and applies its exported defaults. The app must relaunch afterward
    /// for every open GRDB connection to pick up the new file — this function
    /// terminates the app on success; the caller should warn the user first.
    static func promptImport(currentDatabasePath: String) {
        let panel = NSOpenPanel()
        panel.title = "Restore Backup"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let confirm = NSAlert()
        confirm.messageText = "Restore this backup?"
        confirm.informativeText = "This replaces your current digest history and preferences with the " +
                                  "backup's contents, then quits the app. Your current data is kept " +
                                  "alongside as a .before-restore copy. You'll need to reopen LLMessenger."
        confirm.addButton(withTitle: "Restore and Quit")
        confirm.addButton(withTitle: "Cancel")
        confirm.alertStyle = .warning
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            try restore(from: url, toDatabasePath: currentDatabasePath)
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Restore failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Replaces the on-disk store at `currentDatabasePath` with the backup at
    /// `url`, keeping the previous store as a `.before-restore` sidecar rather
    /// than deleting it, and applies the backup's exported defaults. Does not
    /// touch any already-open connection — the process must relaunch.
    static func restore(from url: URL, toDatabasePath currentDatabasePath: String,
                        defaults: UserDefaults = .standard) throws {
        // Validate it's a readable SQLite store with our export table before
        // touching the live file — a partial/corrupt copy must fail loudly here,
        // not after the live store has already been overwritten.
        let source = try DatabaseQueue(path: url.path)
        try source.read { db in
            guard try db.tableExists(exportTableName) || db.tableExists("briefs") else {
                throw DatabaseError(message: "Not a recognizable LLMessenger backup")
            }
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: currentDatabasePath) {
            let backupPath = currentDatabasePath + ".before-restore"
            try? fm.removeItem(atPath: backupPath)
            try fm.copyItem(atPath: currentDatabasePath, toPath: backupPath)
        }

        try source.read { db in
            let rows = (try? Row.fetchAll(db, sql: "SELECT key, value FROM \(exportTableName)")) ?? []
            for row in rows {
                guard let key: String = row["key"], let jsonString: String = row["value"],
                      let data = jsonString.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let value = obj["v"] else { continue }
                defaults.set(value, forKey: key)
            }
        }

        // Close our read connection before the file copy so nothing holds a
        // lock or leaves WAL pages unflushed on the source file.
        try? source.close()

        try? fm.removeItem(atPath: currentDatabasePath)
        try fm.copyItem(atPath: url.path, toPath: currentDatabasePath)
    }
}
