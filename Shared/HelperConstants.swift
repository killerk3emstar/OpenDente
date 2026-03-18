import Foundation

extension String {
    /// Numeric-aware version comparison: "1.10.0" >= "1.2.0" returns true.
    /// Uses Foundation's `.numeric` option so multi-digit components compare correctly.
    func isVersionAtLeast(_ other: String) -> Bool {
        self.compare(other, options: .numeric) != .orderedAscending
    }
}

enum HelperConstants {
    /// Mach service name (must match launchd plist MachServices key and helper bundle ID)
    static let machServiceName = "com.opendente.helper"

    /// Helper bundle identifier
    static let helperBundleID = "com.opendente.helper"

    /// App bundle identifier (for XPC caller verification)
    static let appBundleID = "com.opendente.app"

    /// Watchdog timeout in seconds — if no heartbeat received within this window
    /// and charging is inhibited, the helper resets to safe defaults
    static let watchdogTimeout: TimeInterval = 120

    /// How often the app sends heartbeat pings
    static let heartbeatInterval: TimeInterval = 30

    /// How often the watchdog checks for missed heartbeats
    static let watchdogCheckInterval: TimeInterval = 30

    /// Root-owned state directory
    static let stateDirectory = "/Library/Application Support/OpenDente"

    /// State file path (written atomically by helper)
    static let stateFilePath = "/Library/Application Support/OpenDente/helper-state"

    /// Helper version (bump when protocol changes)
    static let helperVersion = "1.1.0"

    /// Minimum helper version that supports MagSafe LED control (ACLC)
    static let minVersionMagSafeLED = "1.1.0"

    /// Name of the launchd plist file (in app bundle Contents/Library/LaunchDaemons/)
    static let launchdPlistName = "com.opendente.helper.plist"

    // MARK: - MagSafe LED Colors (ACLC key values)

    /// Let the system control the LED (default behavior)
    static let ledAuto: UInt8 = 0x00
    /// Turn LED off
    static let ledOff: UInt8 = 0x01
    /// Green LED (charging complete / limit reached)
    static let ledGreen: UInt8 = 0x03
    /// Orange LED (actively charging / discharging)
    static let ledOrange: UInt8 = 0x04
}
