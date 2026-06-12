// LLMessenger/Core/UpdateChecker.swift
//
// Privacy-respecting update check for a directly-distributed app: one
// unauthenticated HTTPS call to the GitHub releases API, no identifiers, no
// tracking, off by a single toggle. While the repo is private the call 404s
// and the checker stays silent — it activates the day the repo goes public.

import Foundation

@MainActor
final class UpdateChecker {

    struct Update: Equatable {
        let version: String
        let url: URL
    }

    static let optOutKey = "disableUpdateChecks"
    private static let lastCheckKey = "lastUpdateCheckDate"
    private static let endpoint = URL(string: "https://api.github.com/repos/googlarz/LLMessenger/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 3600

    /// Called when a newer release is found. Wired by AppDelegate to the menu bar.
    var onUpdateAvailable: ((Update) -> Void)?

    private let session: URLSession
    private let currentVersion: String

    init(session: URLSession = .shared,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.session = session
        self.currentVersion = currentVersion
    }

    /// Checks at most once per day; silent on any failure.
    func checkIfDue() {
        guard !UserDefaults.standard.bool(forKey: Self.optOutKey) else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.checkInterval else { return }
        Task { await check() }
    }

    func check() async {
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:))
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
