import AppKit
import Foundation
import UserNotifications
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "Notifications")

/// Sends macOS notifications for key charging events.
/// Anti-spam: blocks the same event from firing twice in a row.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationService()

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Show banner + play sound even when the app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    enum Event: String, Equatable {
        case chargeLimitReached
        case topUpComplete
        case heatProtection
        case dischargeComplete
        case systemChargeLimitConflict
        case inhibitFailed
    }

    /// Last event sent — used to prevent duplicate notifications.
    /// Internal for testability.
    var lastEvent: Event?

    func requestPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            guard settings.authorizationStatus == .notDetermined else {
                if settings.authorizationStatus == .denied {
                    log.info("Notification permission previously denied — user must enable in System Settings")
                }
                return
            }

            // Menu bar apps (.accessory) can't show the permission dialog
            // unless temporarily brought to the foreground as a regular app.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                log.info("Notification permission: \(granted ? "granted" : "denied", privacy: .public)")
            } catch {
                log.error("Notification permission error: \(error.localizedDescription, privacy: .public)")
            }

            NSApp.setActivationPolicy(.accessory)
        }
    }

    func send(_ event: Event, settings: AppSettings) {
        guard settings.showNotifications else { return }
        guard isEnabled(event, settings: settings) else { return }
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
        case .systemChargeLimitConflict:
            content.title = "System Charge Limit Active"
            content.body = "macOS Charge Limit is preventing charging. Lower it in System Settings > Battery."
        case .inhibitFailed:
            content.title = "Charging Control Failed"
            content.body = "Unable to stop charging. Try unplugging and re-plugging the charger."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.opendente.\(event.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("Failed to deliver notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func clearLastEvent() {
        lastEvent = nil
    }

    private func isEnabled(_ event: Event, settings: AppSettings) -> Bool {
        switch event {
        case .chargeLimitReached: return settings.notifyChargeLimitReached
        case .topUpComplete:      return settings.notifyTopUpComplete
        case .heatProtection:     return settings.notifyHeatProtection
        case .dischargeComplete:  return settings.notifyDischargeComplete
        case .systemChargeLimitConflict: return true  // always notify — important warning
        case .inhibitFailed:            return true  // always notify — safety critical
        }
    }
}
