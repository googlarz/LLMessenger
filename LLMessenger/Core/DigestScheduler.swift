// LLMessenger/Core/DigestScheduler.swift
import Foundation

@MainActor
final class DigestScheduler {

    struct Settings: Codable {
        var enabled: Bool = false
        var hour: Int = 8
        var minute: Int = 0
    }

    var onFire: (() async -> Void)?

    private var timer: Timer?
    private static let lastFiredKey = "digestLastFiredDate"

    func start(settings: Settings) {
        scheduleTimer(settings: settings)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reschedule(settings: Settings) {
        stop()
        if settings.enabled {
            scheduleTimer(settings: settings)
        }
    }

    // MARK: - Private

    private func scheduleTimer(settings: Settings) {
        guard settings.enabled else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.checkAndFire(settings: settings)
            }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Check immediately on start in case the app was launched after the scheduled time.
        Task { @MainActor [weak self] in
            await self?.checkAndFire(settings: settings)
        }
    }

    private func checkAndFire(settings: Settings) async {
        guard settings.enabled else { return }
        let now = Date()
        let cal = Calendar.current
        let h = cal.component(.hour, from: now)
        let m = cal.component(.minute, from: now)
        // Fire when we are within the scheduled minute window.
        guard h == settings.hour && m == settings.minute else { return }
        // Fire at most once per calendar day.
        if let last = UserDefaults.standard.object(forKey: Self.lastFiredKey) as? Date,
           cal.isDate(last, inSameDayAs: now) { return }
        UserDefaults.standard.set(now, forKey: Self.lastFiredKey)
        await onFire?()
    }

    /// Next scheduled fire time for display in the settings UI.
    func nextFireDate(for settings: Settings) -> Date? {
        guard settings.enabled else { return nil }
        let cal = Calendar.current
        let now = Date()
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.hour = settings.hour
        components.minute = settings.minute
        components.second = 0
        guard let candidate = cal.date(from: components) else { return nil }
        // If today's window has already passed (or fired today), schedule for tomorrow.
        if candidate <= now {
            return cal.date(byAdding: .day, value: 1, to: candidate)
        }
        return candidate
    }
}
