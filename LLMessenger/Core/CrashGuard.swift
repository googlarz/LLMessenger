// LLMessenger/Core/CrashGuard.swift
//
// Lightweight local crash capture for a directly-distributed app: uncaught
// exceptions and fatal signals write a plain-text report to
// ~/Library/Application Support/LLMessenger/CrashReports/. Reports never
// leave the machine — they ride along only when the user explicitly exports
// diagnostics from the About tab.

import AppKit
import Foundation

enum CrashGuard {

    static var reportsDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LLMessenger/CrashReports", isDirectory: true)
    }

    static func install() {
        try? FileManager.default.createDirectory(at: reportsDirectory,
                                                 withIntermediateDirectories: true)

        NSSetUncaughtExceptionHandler { exception in
            CrashGuard.write(kind: "uncaught-exception", body: """
            Exception: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "—")

            \(exception.callStackSymbols.joined(separator: "\n"))
            """)
        }

        // Best-effort: Thread.callStackSymbols is not strictly async-signal-
        // safe, but for a local-only crash note the tradeoff is standard
        // practice. The handler re-raises with default disposition so the
        // OS report is still produced.
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { code in
                CrashGuard.write(kind: "signal-\(code)", body:
                    Thread.callStackSymbols.joined(separator: "\n"))
                signal(code, SIG_DFL)
                raise(code)
            }
        }
    }

    static func pendingReports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "txt" }.sorted { $0.path > $1.path }
    }

    private static func write(kind: String, body: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let report = """
        LLMessenger crash report — \(kind)
        Version: \(version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Date: \(ISO8601DateFormatter().string(from: Date()))

        \(body)
        """
        let name = "crash-\(Int(Date().timeIntervalSince1970))-\(kind).txt"
        try? report.write(to: reportsDirectory.appendingPathComponent(name),
                          atomically: false, encoding: .utf8)
    }
}
