// LLMessenger/Core/Notifications/NotificationManager.swift
import AppKit
import Foundation
import UserNotifications

@MainActor
final class NotificationManager: NSObject {
    static let categoryID = "LLMessenger.brief"

    var onNotificationTap: ((Int64) -> Void)?

    func requestPermission() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            case .denied:
                // Previously denied — open System Settings so the user can re-enable.
                DispatchQueue.main.async {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
            default:
                break
            }
        }
    }

    func post(briefID: Int64, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["briefID": briefID]

        let request = UNNotificationRequest(
            identifier: "brief-\(briefID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated static func briefID(from userInfo: [AnyHashable: Any]) -> Int64? {
        userInfo["briefID"] as? Int64
    }

    nonisolated static func scheduleSnoozeNotification(briefID: Int64, headline: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Snoozed brief"
        content.body = headline
        content.userInfo = ["briefID": briefID]
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: "snooze-\(briefID)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Fires the moment an action is armed for auto-send, giving the user an
    /// OS-level Undo opportunity — the 30s countdown is only visible in the app
    /// if it happens to be open, which is uncommon for a background delegation.
    nonisolated static func postAutoSendArmedNotification(
        conversationName: String,
        actionTitle: String,
        actionID: Int64
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Sending on your behalf in 30s"
        content.body = "\(conversationName) — \(actionTitle). Open LLMessenger to undo."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(
            identifier: "autosend-armed-\(actionID)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    nonisolated static func postDraftReadyNotification(senderName: String, briefID: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "Draft ready"
        content.body = "Tap to review your reply to \(senderName)"
        content.userInfo = ["briefID": briefID, "type": "draftReady"]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "draft-\(briefID)-\(senderName)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let id = Self.briefID(from: userInfo) {
            Task { @MainActor in self.onNotificationTap?(id) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
