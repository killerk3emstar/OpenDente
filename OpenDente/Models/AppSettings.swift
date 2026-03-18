import Foundation
import SwiftUI

/// All user-configurable settings, backed by UserDefaults.
/// Production uses `.standard` via `AppSettings.shared`.
/// Tests pass an isolated suite to avoid polluting real settings.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Charging

    var chargingEnabled: Bool {
        get { defaults.object(forKey: "chargingEnabled") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "chargingEnabled") }
    }

    /// Charge limit percentage (20-100), clamped on set
    var chargeLimit: Int {
        get {
            let v = defaults.integer(forKey: "chargeLimit")
            return v == 0 ? 80 : min(100, max(20, v))
        }
        set {
            objectWillChange.send()
            defaults.set(min(100, max(20, newValue)), forKey: "chargeLimit")
        }
    }

    // MARK: - Sailing Mode

    var sailingModeEnabled: Bool {
        get { defaults.object(forKey: "sailingModeEnabled") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "sailingModeEnabled") }
    }

    /// Sailing range percentage (2-25), clamped on set
    var sailingRange: Int {
        get {
            let v = defaults.integer(forKey: "sailingRange")
            return v == 0 ? 10 : min(25, max(2, v))
        }
        set {
            objectWillChange.send()
            defaults.set(min(25, max(2, newValue)), forKey: "sailingRange")
        }
    }

    // MARK: - Heat Protection

    var heatProtectionEnabled: Bool {
        get { defaults.object(forKey: "heatProtectionEnabled") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "heatProtectionEnabled") }
    }

    var heatProtectionTemp: Double {
        get {
            let v = defaults.double(forKey: "heatProtectionTemp")
            return v == 0 ? 35.0 : v
        }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "heatProtectionTemp") }
    }

    // MARK: - Discharge

    var automaticDischarge: Bool {
        get { defaults.bool(forKey: "automaticDischarge") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "automaticDischarge") }
    }

    // MARK: - Sleep

    var stopChargingWhenSleeping: Bool {
        get { defaults.bool(forKey: "stopChargingWhenSleeping") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "stopChargingWhenSleeping") }
    }

    var disableSleepUntilChargeLimit: Bool {
        get { defaults.bool(forKey: "disableSleepUntilChargeLimit") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "disableSleepUntilChargeLimit") }
    }

    // MARK: - Status Bar Display

    var statusBarShowPercentage: Bool {
        get { defaults.object(forKey: "statusBarShowPercentage") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "statusBarShowPercentage") }
    }

    var statusBarShowTemperature: Bool {
        get { defaults.bool(forKey: "statusBarShowTemperature") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "statusBarShowTemperature") }
    }

    var statusBarShowPower: Bool {
        get { defaults.bool(forKey: "statusBarShowPower") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "statusBarShowPower") }
    }

    var statusBarShowMode: Bool {
        get { defaults.object(forKey: "statusBarShowMode") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "statusBarShowMode") }
    }

    // MARK: - Power Flow

    var showPowerFlow: Bool {
        get { defaults.object(forKey: "showPowerFlow") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "showPowerFlow") }
    }

    // MARK: - MagSafe LED

    var controlMagSafeLED: Bool {
        get { defaults.object(forKey: "controlMagSafeLED") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "controlMagSafeLED") }
    }

    var magSafeLEDOffWhenInactive: Bool {
        get { defaults.bool(forKey: "magSafeLEDOffWhenInactive") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "magSafeLEDOffWhenInactive") }
    }

    // MARK: - General

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "launchAtLogin") }
    }

    var useHardwareBatteryPercentage: Bool {
        get { defaults.bool(forKey: "useHardwareBatteryPercentage") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "useHardwareBatteryPercentage") }
    }

    var showNotifications: Bool {
        get { defaults.object(forKey: "showNotifications") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "showNotifications") }
    }

    var notifyChargeLimitReached: Bool {
        get { defaults.object(forKey: "notifyChargeLimitReached") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "notifyChargeLimitReached") }
    }

    var notifyTopUpComplete: Bool {
        get { defaults.object(forKey: "notifyTopUpComplete") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "notifyTopUpComplete") }
    }

    var notifyHeatProtection: Bool {
        get { defaults.object(forKey: "notifyHeatProtection") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "notifyHeatProtection") }
    }

    var notifyDischargeComplete: Bool {
        get { defaults.object(forKey: "notifyDischargeComplete") as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "notifyDischargeComplete") }
    }

    // MARK: - Popover Detail Items

    /// Ordered list of enabled detail items in the popover
    var popoverDetailItems: [PopoverDetailItem] {
        get {
            guard let data = defaults.data(forKey: "popoverDetailItems"),
                  let items = try? JSONDecoder().decode([PopoverDetailItem].self, from: data)
            else {
                return PopoverDetailItem.defaultItems
            }
            return items
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                objectWillChange.send()
                defaults.set(data, forKey: "popoverDetailItems")
            }
        }
    }

    // MARK: - Computed

    /// Lower bound of sailing range
    var sailingLowerBound: Int {
        max(0, chargeLimit - sailingRange)
    }
}
