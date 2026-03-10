import Foundation
import SwiftUI

/// All user-configurable settings, backed by UserDefaults
final class AppSettings: ObservableObject, @unchecked Sendable {

    static let shared = AppSettings()

    // MARK: - Charging
    @AppStorage("chargeLimit") var chargeLimit: Int = 80
    @AppStorage("chargingEnabled") var chargingEnabled: Bool = true

    // MARK: - Sailing Mode
    @AppStorage("sailingModeEnabled") var sailingModeEnabled: Bool = true
    @AppStorage("sailingRange") var sailingRange: Int = 10  // % below limit before recharging

    // MARK: - Heat Protection
    @AppStorage("heatProtectionEnabled") var heatProtectionEnabled: Bool = true
    @AppStorage("heatProtectionTemp") var heatProtectionTemp: Double = 35.0

    // MARK: - Discharge
    @AppStorage("automaticDischarge") var automaticDischarge: Bool = false

    // MARK: - Sleep
    @AppStorage("stopChargingWhenSleeping") var stopChargingWhenSleeping: Bool = false
    @AppStorage("disableSleepUntilChargeLimit") var disableSleepUntilChargeLimit: Bool = false

    // MARK: - Status Bar Display
    @AppStorage("statusBarShowPercentage") var statusBarShowPercentage: Bool = true
    @AppStorage("statusBarShowTemperature") var statusBarShowTemperature: Bool = false
    @AppStorage("statusBarShowPower") var statusBarShowPower: Bool = false
    @AppStorage("statusBarShowMode") var statusBarShowMode: Bool = true

    // MARK: - Power Flow
    @AppStorage("showPowerFlow") var showPowerFlow: Bool = true

    // MARK: - General
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("useHardwareBatteryPercentage") var useHardwareBatteryPercentage: Bool = false
    @AppStorage("showNotifications") var showNotifications: Bool = true

    // MARK: - Computed

    /// Lower bound of sailing range
    var sailingLowerBound: Int {
        max(0, chargeLimit - sailingRange)
    }
}
