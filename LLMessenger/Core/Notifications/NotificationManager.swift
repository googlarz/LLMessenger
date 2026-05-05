// LLMessenger/Core/Notifications/NotificationManager.swift
import Foundation
import UserNotifications

@MainActor
final class NotificationManager: NSObject {
    static let categoryID = "LLMessenger.brief"

    var onNotificationTap: ((Int64) -> Void)?

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        UNUserNotificationCenter.current().delegate = self
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
