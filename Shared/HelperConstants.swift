import Foundation

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

    /// Helper version
    static let helperVersion = "1.0.0"

    /// Name of the launchd plist file (in app bundle Contents/Library/LaunchDaemons/)
    static let launchdPlistName = "com.opendente.helper.plist"
}
