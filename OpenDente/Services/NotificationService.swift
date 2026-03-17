import Foundation
import UserNotifications
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "Notifications")

/// Sends macOS notifications for key charging events.
/// Anti-spam: blocks the same event from firing twice in a row.
@MainActor
final class NotificationService {

    static let shared = NotificationService()

    enum Event: String, Equatable {
        case chargeLimitReached
        case topUpComplete
        case heatProtection
        case dischargeComplete
    }

    /// Last event sent — used to prevent duplicate notifications.
    /// Internal for testability.
    var lastEvent: Event?

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log.error("Notification permission error: \(error.localizedDescription)")
            } else {
                log.info("Notification permission: \(granted ? "granted" : "denied")")
            }
        }
    }

    func send(_ event: Event, settings: AppSettings) {
        guard settings.showNotifications else { return }
        guard event != lastEvent else { return }
        lastEvent = event

        let content = UNMutableNotificationContent()
        switch event {
        case .chargeLimitReached:
            content.title = "Charge Limit Reached"
            content.body = "Battery has reached your charge limit. Charging paused."
        case .topUpComplete:
            content.title = "Top Up Complete"
            content.body = "Battery is fully charged at 100%."
        case .heatProtection:
            content.title = "Heat Protection Active"
            content.body = "Charging paused due to high battery temperature."
        case .dischargeComplete:
            content.title = "Discharge Complete"
            content.body = "Battery has discharged to your charge limit."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.opendente.\(event.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }

    func clearLastEvent() {
        lastEvent = nil
    }
}
