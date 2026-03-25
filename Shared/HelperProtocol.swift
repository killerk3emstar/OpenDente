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

    /// Set the MagSafe LED color (0x03 = green, 0x04 = orange, 0x00 = system default)
    func setMagSafeLED(color: UInt8, reply: @escaping (Bool, String?) -> Void)

    /// Sync sleep settings so the helper can independently inhibit charging on sleep.
    /// Defense-in-depth: if the app's XPC inhibit call doesn't complete before macOS
    /// suspends the process, the helper's IOKit sleep callback fires in kernel context
    /// and can inhibit charging as a backup.
    /// `sleepLEDColor`: LED color to set when inhibiting on sleep (0xFF = don't touch LED).
    func syncSleepSettings(stopChargingWhenSleeping: Bool, sleepLEDColor: UInt8, reply: @escaping (Bool) -> Void)
}
