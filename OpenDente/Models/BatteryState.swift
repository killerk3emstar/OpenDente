import Foundation

// MARK: - Adapter Types

struct USBPDProfile: Equatable {
    let voltage: Double  // V
    let current: Double  // A
    var watts: Int { Int(round(voltage * current)) }
}

struct AdapterInfo: Equatable {
    let name: String              // "96W USB-C Power Adapter" (Name key)
    let description: String?      // "pd charger" (Description key)
    let manufacturer: String?     // "Apple Inc."
    let model: String?            // "0x7002"
    let watts: Int                // 94
    let voltage: Double           // V — live from VD0R or negotiated AdapterVoltage
    let current: Double           // A — live from ID0R or negotiated Current
    let serial: String?           // "C4H441203C3PM0WBF"
    let firmware: String?         // "01090058"
    let isWireless: Bool
    let usbPDProfiles: [USBPDProfile]
    let activeProfileIndex: Int?  // UsbHvcHvcIndex
}

/// Complete snapshot of battery state at a point in time
struct BatteryState: Equatable {
    // MARK: - Core
    let percentage: Int              // 0-100 (macOS reported)
    let hardwarePercentage: Int?     // Raw SoC from SMC (B0RM/B0FC)
    let isCharging: Bool
    let isPluggedIn: Bool

    // MARK: - Capacity
    let currentCapacity: Int?        // mAh remaining
    let maxCapacity: Int?            // mAh full charge capacity
    let designCapacity: Int?         // mAh original design capacity
    let cycleCount: Int?

    // MARK: - Power
    let temperature: Double?         // Celsius
    let voltage: Double?             // Volts (battery)
    let amperage: Double?            // Amps (battery, positive = charging, negative = discharging)
    let systemPower: Double?         // Watts - total system draw
    let adapterPower: Double?        // Watts - power from adapter
    let adapterInfo: AdapterInfo?     // Rich charger info from IORegistry + SMC
    let batteryPower: Double?        // Watts - power to/from battery
    let notChargingReason: UInt64?   // IORegistry ChargerData.NotChargingReason (0 = normal)

    // MARK: - Time
    let timeToEmpty: Int?            // Minutes
    let timeToFull: Int?             // Minutes

    // MARK: - Computed
    var healthPercentage: Double? {
        guard let max = maxCapacity, let design = designCapacity, design > 0, max > 0 else { return nil }
        return Double(max) / Double(design) * 100.0
    }

    /// Returns hardware percentage if enabled and available, otherwise macOS percentage
    func effectivePercentage(useHardware: Bool) -> Int {
        if useHardware, let hw = hardwarePercentage { return hw }
        return percentage
    }

    var isOnBattery: Bool { !isPluggedIn }

    var powerSource: String {
        isPluggedIn ? "Power Adapter" : "Battery"
    }

    /// Format a duration in minutes as "Xh Ym" or "Ym"
    static func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// Build the status bar text from display flags. Shared between AppDelegate and SettingsView.
    func statusBarText(
        effectivePercentage pct: Int,
        showPercentage: Bool,
        showTemperature: Bool,
        showPower: Bool
    ) -> String {
        var parts: [String] = []
        if showPercentage { parts.append("\(pct)%") }
        if showTemperature, let temp = temperature {
            parts.append(String(format: "%.0f°", temp))
        }
        if showPower, let power = systemPower, power > 0 {
            parts.append(String(format: "%.0fW", power))
        }
        return parts.joined(separator: " ")
    }

    static let unknown = BatteryState(
        percentage: 0, hardwarePercentage: nil, isCharging: false, isPluggedIn: false,
        currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
        temperature: nil, voltage: nil, amperage: nil,
        systemPower: nil, adapterPower: nil, adapterInfo: nil,
        batteryPower: nil, notChargingReason: nil,
        timeToEmpty: nil, timeToFull: nil
    )
}

/// The current operational mode of OpenDente
enum ChargingMode: String, CaseIterable {
    case charging         // Actively charging toward limit
    case paused           // Limit reached, using AC power
    case sailing          // In sailing range, not charging
    case discharging      // Actively discharging while plugged in
    case topUp            // Charging to 100% temporarily
    case calibrating      // Running calibration cycle
    case heatProtection   // Paused due to high temperature
    case onBattery        // Not plugged in
    case idle             // App just started / unknown state

    var displayName: String {
        switch self {
        case .charging:       return "Charging"
        case .paused:         return "Charge Limit Reached"
        case .sailing:        return "Sailing"
        case .discharging:    return "Discharging"
        case .topUp:          return "Topping Up"
        case .calibrating:    return "Calibrating"
        case .heatProtection: return "Heat Protection"
        case .onBattery:      return "On Battery"
        case .idle:           return "Idle"
        }
    }

    /// Time remaining label and value for the popover detail row.
    /// Returns nil for modes where time remaining should be hidden.
    func timeRemainingDisplay(
        chargeLimit: Int,
        percentage: Int,
        timeToFull: Int?,
        timeToEmpty: Int?
    ) -> (label: String, value: String)? {
        switch self {
        case .charging:
            if percentage >= chargeLimit {
                return ("Time to \(chargeLimit)%", "Reached")
            }
            guard let ttf = timeToFull, ttf > 0, ttf < 6000 else {
                return ("Time to \(chargeLimit)%", "Calculating…")
            }
            let remaining = 100 - percentage
            guard remaining > 0 else { return ("Time to \(chargeLimit)%", "Calculating…") }
            let toLimit = chargeLimit - percentage
            let estimated = max(1, Int(Double(ttf) * Double(toLimit) / Double(remaining)))
            return ("Time to \(chargeLimit)%", BatteryState.formatMinutes(estimated))

        case .topUp:
            if percentage >= 100 {
                return ("Time to Full", "Charged")
            }
            guard let ttf = timeToFull, ttf > 0, ttf < 6000 else {
                return ("Time to Full", "Calculating…")
            }
            return ("Time to Full", BatteryState.formatMinutes(ttf))

        case .discharging, .onBattery:
            guard let tte = timeToEmpty, tte > 0, tte < 6000 else {
                return ("Time Remaining", "Calculating…")
            }
            return ("Time Remaining", BatteryState.formatMinutes(tte))

        case .paused, .sailing:
            return ("Time Remaining", "–")

        case .heatProtection:
            return ("Time Remaining", "Paused")

        case .idle, .calibrating:
            return nil
        }
    }

    /// SF Symbol name for the status bar battery icon
    func batteryIconName(percentage: Int, isCharging: Bool) -> String {
        if isCharging || self == .charging || self == .topUp {
            return "battery.100percent.bolt"
        }
        switch percentage {
        case 88...100: return "battery.100percent"
        case 63..<88:  return "battery.75percent"
        case 38..<63:  return "battery.50percent"
        case 13..<38:  return "battery.25percent"
        default:       return "battery.0percent"
        }
    }

    var statusBarIcon: String {
        switch self {
        case .charging:       return "bolt.fill"
        case .paused:         return "pause.circle.fill"
        case .sailing:        return "wind"
        case .discharging:    return "arrow.down.circle.fill"
        case .topUp:          return "arrow.up.to.line.circle.fill"
        case .calibrating:    return "arrow.triangle.2.circlepath"
        case .heatProtection: return "thermometer.sun.fill"
        case .onBattery:      return "battery.100percent"
        case .idle:           return "battery.100percent"
        }
    }
}

/// Items that can be shown in the popover details grid
enum PopoverDetailItem: String, CaseIterable, Codable, Identifiable {
    case temperature
    case batteryHealth
    case cycleCount
    case timeRemaining
    case systemPower
    case adapterPower
    case adapterName
    case adapterManufacturer
    case adapterModel
    case adapterSerial
    case adapterVoltage
    case adapterCurrent
    case voltage
    case amperage
    case currentCapacity
    case designCapacity
    case batteryPower
    case notChargingReason

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .temperature:         return "Temperature"
        case .batteryHealth:       return "Battery Health"
        case .cycleCount:          return "Cycle Count"
        case .timeRemaining:       return "Time Remaining"
        case .systemPower:         return "System Power"
        case .adapterPower:        return "Adapter Power"
        case .adapterName:         return "Adapter"
        case .adapterManufacturer: return "Manufacturer"
        case .adapterModel:       return "Adapter Model"
        case .adapterSerial:       return "Adapter Serial"
        case .adapterVoltage:      return "Adapter Voltage"
        case .adapterCurrent:      return "Adapter Current"
        case .voltage:             return "Battery Voltage"
        case .amperage:            return "Battery Current"
        case .currentCapacity:     return "Capacity"
        case .designCapacity:      return "Design Capacity"
        case .batteryPower:        return "Battery Power"
        case .notChargingReason:   return "Not Charging Reason"
        }
    }

    var icon: String {
        switch self {
        case .temperature:         return "thermometer.medium"
        case .batteryHealth:       return "heart.fill"
        case .cycleCount:          return "arrow.triangle.2.circlepath"
        case .timeRemaining:       return "clock"
        case .systemPower:         return "bolt.fill"
        case .adapterPower:        return "powerplug.fill"
        case .adapterName:         return "powerplug.fill"
        case .adapterManufacturer: return "building.2"
        case .adapterModel:       return "cpu"
        case .adapterSerial:       return "number"
        case .adapterVoltage:      return "bolt.circle"
        case .adapterCurrent:      return "bolt.horizontal"
        case .voltage:             return "minus.plus.batteryblock.fill"
        case .amperage:            return "arrow.left.arrow.right"
        case .currentCapacity:     return "battery.75percent"
        case .designCapacity:      return "battery.100percent"
        case .batteryPower:        return "battery.100percent.bolt"
        case .notChargingReason:   return "questionmark.circle"
        }
    }

    /// Default items shown in the popover (in order)
    static let defaultItems: [PopoverDetailItem] = [
        .temperature, .batteryHealth, .cycleCount,
        .timeRemaining, .systemPower, .adapterPower
    ]
}

// MARK: - Comparable Utilities

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Which generation of SMC charging keys to use
enum SMCChargingAPI {
    case legacy     // CH0B/CH0C/CH0I (M1/M2/M3)
    case tahoe      // CHTE/CHIE (newer Macs)
    case unknown    // Not yet detected
}
