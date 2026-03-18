import Foundation
import SwiftUI

/// All user-configurable settings, backed by UserDefaults
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - Charging
    @AppStorage("chargingEnabled") var chargingEnabled: Bool = true

    /// Charge limit percentage (20-100), clamped on set
    var chargeLimit: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "chargeLimit")
            return v == 0 ? 80 : min(100, max(20, v))
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(min(100, max(20, newValue)), forKey: "chargeLimit")
        }
    }

    // MARK: - Sailing Mode
    @AppStorage("sailingModeEnabled") var sailingModeEnabled: Bool = true

    /// Sailing range percentage (2-25), clamped on set
    var sailingRange: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "sailingRange")
            return v == 0 ? 10 : min(25, max(2, v))
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(min(25, max(2, newValue)), forKey: "sailingRange")
        }
    }

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

    // MARK: - MagSafe LED
    @AppStorage("controlMagSafeLED") var controlMagSafeLED: Bool = true
    @AppStorage("magSafeLEDOffWhenInactive") var magSafeLEDOffWhenInactive: Bool = false

    // MARK: - General
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("useHardwareBatteryPercentage") var useHardwareBatteryPercentage: Bool = false
    @AppStorage("showNotifications") var showNotifications: Bool = true
    @AppStorage("notifyChargeLimitReached") var notifyChargeLimitReached: Bool = true
    @AppStorage("notifyTopUpComplete") var notifyTopUpComplete: Bool = true
    @AppStorage("notifyHeatProtection") var notifyHeatProtection: Bool = true
    @AppStorage("notifyDischargeComplete") var notifyDischargeComplete: Bool = true

    // MARK: - Popover Detail Items

    /// Ordered list of enabled detail items in the popover
    var popoverDetailItems: [PopoverDetailItem] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "popoverDetailItems"),
                  let items = try? JSONDecoder().decode([PopoverDetailItem].self, from: data)
            else {
                return PopoverDetailItem.defaultItems
            }
            return items
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                objectWillChange.send()
                UserDefaults.standard.set(data, forKey: "popoverDetailItems")
            }
        }
    }

    // MARK: - Computed

    /// Lower bound of sailing range
    var sailingLowerBound: Int {
        max(0, chargeLimit - sailingRange)
    }
}
