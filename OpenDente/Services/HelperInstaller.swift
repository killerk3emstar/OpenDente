import Foundation
import ServiceManagement
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "HelperInstaller")

/// Manages registration of the privileged helper daemon via SMAppService.
/// Uses the modern SMAppService.daemon() API (macOS 13+), no SMJobBless needed.
@MainActor
enum HelperInstaller {

    private static var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.launchdPlistName)
    }

    /// Current registration status
    static var status: SMAppService.Status {
        service.status
    }

    /// Whether the helper is registered and enabled
    static var isRegistered: Bool {
        service.status == .enabled
    }

    /// Register the helper daemon. Returns true if registration succeeded.
    /// When status is `.requiresApproval`, register() can't help — the user must
    /// toggle the helper ON in System Settings > General > Login Items.
    @discardableResult
    static func register() -> Bool {
        let currentStatus = service.status

        if currentStatus == .requiresApproval {
            log.info("Helper requires approval — opening System Settings")
            openSystemSettings()
            return false
        }

        log.notice("Helper status before register: \(String(describing: currentStatus), privacy: .public)")
        do {
            try service.register()
            log.notice("Helper daemon registered successfully (status now: \(String(describing: service.status), privacy: .public))")
            return service.status == .enabled
        } catch {
            log.error("Failed to register helper daemon: \(error, privacy: .public)")
            return false
        }
    }

    /// Unregister the helper daemon
    static func unregister() {
        do {
            try service.unregister()
            log.info("Helper daemon unregistered")
        } catch {
            log.error("Failed to unregister helper daemon: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Open System Settings to the Login Items pane where the user can toggle the helper
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Human-readable status description
    static var statusDescription: String {
        switch service.status {
        case .enabled:          return "Enabled"
        case .notRegistered:    return "Not Installed"
        case .requiresApproval: return "Requires Approval"
        case .notFound:         return "Not Found in Bundle"
        @unknown default:       return "Unknown"
        }
    }
}
