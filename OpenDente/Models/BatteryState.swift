import Foundation

/// Complete snapshot of battery state at a point in time
struct BatteryState: Equatable {
    // MARK: - Core
    let percentage: Int              // 0-100 (macOS reported)
    let isCharging: Bool
    let isPluggedIn: Bool

    // MARK: - Capacity
    let currentCapacity: Int?        // mAh remaining
    let maxCapacity: Int?            // mAh full charge capacity
    let designCapacity: Int?         // mAh original design capacity
    let cycleCount: Int?

    // MARK: - Power
    let temperature: Double?         // Celsius
    let voltage: Double?             // Volts
    let amperage: Double?            // Amps (positive = charging, negative = discharging)
    let systemPower: Double?         // Watts - total system draw
    let adapterPower: Double?        // Watts - power from adapter
    let batteryPower: Double?        // Watts - power to/from battery

    // MARK: - Time
    let timeToEmpty: Int?            // Minutes
    let timeToFull: Int?             // Minutes

    // MARK: - Computed
    var healthPercentage: Double? {
        guard let max = maxCapacity, let design = designCapacity, design > 0 else { return nil }
        return Double(max) / Double(design) * 100.0
    }

    var isOnBattery: Bool { !isPluggedIn }

    var powerSource: String {
        isPluggedIn ? "Power Adapter" : "Battery"
    }

    var timeRemainingFormatted: String? {
        let minutes: Int?
        if isCharging {
            minutes = timeToFull
        } else {
            minutes = timeToEmpty
        }
        guard let min = minutes, min > 0, min < 6000 else { return nil }
        let h = min / 60
        let m = min % 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        return "\(m)m"
    }

    static let unknown = BatteryState(
        percentage: 0, isCharging: false, isPluggedIn: false,
        currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
        temperature: nil, voltage: nil, amperage: nil,
        systemPower: nil, adapterPower: nil, batteryPower: nil,
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

/// Which generation of SMC charging keys to use
enum SMCChargingAPI {
    case legacy     // CH0B/CH0C/CH0I (M1/M2/M3)
    case tahoe      // CHTE/CHIE (newer Macs)
    case unknown    // Not yet detected
}
