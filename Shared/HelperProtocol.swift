import Foundation

/// XPC protocol for communication between the app and the privileged helper daemon.
/// Every method has a reply block so the app can verify each operation succeeded.
@objc protocol HelperProtocol {
    /// Re-enable charging (safe default state)
    func enableCharging(reply: @escaping (Bool, String?) -> Void)

    /// Inhibit charging (battery stops receiving charge, Mac runs from adapter)
    func inhibitCharging(reply: @escaping (Bool, String?) -> Void)

    /// Enable or disable force discharge (Mac runs from battery while plugged in)
    func forceDischarge(enable: Bool, reply: @escaping (Bool, String?) -> Void)

    /// Reset all SMC charging keys to defaults (enable charging, stop discharge)
    func resetToDefaults(reply: @escaping (Bool, String?) -> Void)

    /// Heartbeat from app to keep watchdog alive
    func heartbeat(reply: @escaping (Bool) -> Void)

    /// Suspend the watchdog timer (e.g. before system sleep)
    func suspendWatchdog(reply: @escaping (Bool) -> Void)

    /// Get the helper daemon version
    func getVersion(reply: @escaping (String) -> Void)

    /// Get the detected charging API name ("legacy", "tahoe", or "unknown")
    func getChargingAPI(reply: @escaping (String) -> Void)
}
