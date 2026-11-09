// LLMessenger/Core/UpdateChecker.swift
//
// Privacy-respecting update check for a directly-distributed app: one
// unauthenticated HTTPS call to the GitHub releases API, no identifiers, no
// tracking, off by a single toggle (Settings → AI & Privacy → Privacy). While the repo is private the call 404s
// and the checker stays silent — it activates the day the repo goes public.

import Foundation

@MainActor
final class UpdateChecker {

    struct Update: Equatable {
        let version: String
        let url: URL
    }

    static let optOutKey = SettingsRepository.updateChecksDisabledKey
    private static let lastCheckKey = "lastUpdateCheckDate"
    private static let endpoint = URL(string: "https://api.github.com/repos/googlarz/LLMessenger/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 3600

    /// Called when a newer release is found. Wired by AppDelegate to the menu bar.
    var onUpdateAvailable: ((Update) -> Void)?

    private let session: URLSession
    private let currentVersion: String
    private let defaults: UserDefaults

    init(session: URLSession = .shared,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         defaults: UserDefaults = .standard) {
        self.session = session
        self.currentVersion = currentVersion
        self.defaults = defaults
    }

    /// Checks at most once per day; silent on any failure. The opt-out is read on every
    /// call, so switching it off in Settings takes effect before the next check.
    /// Returns whether a check was started.
    @discardableResult
    func checkIfDue() -> Bool {
        guard Self.isCheckDue(disabled: defaults.bool(forKey: Self.optOutKey),
                              lastCheck: defaults.object(forKey: Self.lastCheckKey) as? Date,
                              now: Date()) else { return false }
        Task { await check() }
        return true
    }

    /// The whole "should we ask GitHub now" decision, with no side effects.
    nonisolated static func isCheckDue(disabled: Bool, lastCheck: Date?, now: Date,
                                       interval: TimeInterval = 24 * 3600) -> Bool {
        guard !disabled else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) > interval
    }

    /// A menu-bar app can run for weeks, so a launch-time check is not enough.
    /// This wakes up every hour and asks `checkIfDue`, which re-reads the opt-out
    /// each time and lets at most one real check through per day.
    func startPeriodicChecks(every tick: TimeInterval = 3600) {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        timer.tolerance = tick / 10
        self.timer = timer
    }

    private var timer: Timer?

    func check() async {
        defaults.set(Date(), forKey: Self.lastCheckKey)
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            NetworkAuditLog.record(
                provider: "GitHub Updates",
                request: request,
                status: nil,
                durationMs: Int(Date().timeIntervalSince(start) * 1_000),
                error: error
            )
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        NetworkAuditLog.record(
            provider: "GitHub Updates",
            request: request,
            status: status,
            durationMs: Int(Date().timeIntervalSince(start) * 1_000),
            error: nil
        )

        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:)),
              htmlURL.host == "github.com"   // guard against a tampered API response opening an arbitrary URL
        else { return }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if Self.isVersion(latest, newerThan: currentVersion) {
            onUpdateAvailable?(Update(version: latest, url: htmlURL))
        }
    }

    /// Numeric dotted-version comparison: "1.10.0" > "1.9.3".
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
