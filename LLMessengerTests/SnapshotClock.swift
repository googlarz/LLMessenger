import Foundation

/// The one reference time snapshot fixtures use instead of `Date()`, so wall-clock
/// times printed in a screenshot (message and digest times) are the same on every run.
/// Today at 00:30: yesterday evening's items stay "yesterday", this morning's stay "today".
enum SnapshotClock {
    static var anchor: Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: 0, minute: 30, second: 0, of: Date()) ?? Date()
    }
}
