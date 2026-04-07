import SwiftUI

/// Data-driven power flow display. Shows only directly measured values — never derives
/// battery power from adapter minus system (those don't add up due to DC-DC conversion losses).
///
/// Three independent SMC measurements:
/// - PSTR → system power (what the machine consumes, excluding battery charging)
/// - PDTR → adapter power (total charger delivery: system + battery + losses)
/// - B0AP (or V*A) → battery power (signed: positive = charging, negative = discharging)
/// Visual state for the power flow display — what topology is shown.
/// Pure function of BatteryState + ChargingMode. Used by the view and tests alike.
enum PowerFlowVisualState: Equatable {
    case noPowerData
    case onBattery                // Battery → System (also force discharge)
    case pluggedInCharging        // Adapter → System + Battery
    case pluggedInTrickleCharging // Adapter → System + "Charging" (no wattage)
    case pluggedInPaused          // Adapter → System only (no battery bar)
    case pluggedInStopping        // Adapter → System + "Stopping..." bar
    case pluggedInStarting        // Adapter → System + "Starting..." bar
    case peakLoad                 // Adapter + Battery → System (two sources)
}

struct PowerFlowView: View {
    let battery: BatteryState
    var mode: ChargingMode = .idle

    /// Determines the visual state — pure logic, no UI.
    /// Called by both the view (single source of truth) and tests.
    static func resolveVisualState(battery: BatteryState, mode: ChargingMode) -> PowerFlowVisualState {
        let hasAnyPower = battery.systemPower != nil || battery.adapterPower != nil || battery.batteryPower != nil
        guard hasAnyPower else { return .noPowerData }

        let isInhibited = mode == .paused || mode == .sailing || mode == .heatProtection

        // Force discharge or unplugged → on battery view
        if !battery.isPluggedIn || mode == .discharging {
            return .onBattery
        }

        let bp = battery.batteryPower ?? 0

        // Peak load: battery draining while plugged in (not inhibited modes where
        // small negative readings are measurement noise, not real peak load)
        if !battery.isCharging && bp < -0.1 && !isInhibited {
            return .peakLoad
        }

        // Transitional: inhibit sent but hardware still charging
        if isInhibited && battery.isCharging {
            return .pluggedInStopping
        }

        // Actively charging with measurable battery power.
        // SMC battery power updates before IOKit flips isCharging — use it as early signal.
        if (battery.isCharging || mode == .charging || mode == .topUp) && bp > 0.1 {
            return .pluggedInCharging
        }

        // Charging but power too low to measure (trickle)
        if battery.isCharging {
            return .pluggedInTrickleCharging
        }

        // Mode says charging but IOKit hasn't confirmed.
        // If system charge limit is blocking, show paused (not "Starting..." forever).
        if mode == .charging && !battery.isCharging {
            return battery.systemChargeLimitActive ? .pluggedInPaused : .pluggedInStarting
        }

        // Default: plugged in, no battery flow (paused/sailing/heat/idle)
        return .pluggedInPaused
    }

    /// Dynamic battery icon reflecting actual charge level
    static func batterySourceIcon(percentage: Int) -> String {
        switch percentage {
        case 88...100: return "battery.100percent"
        case 63..<88:  return "battery.75percent"
        case 38..<63:  return "battery.50percent"
        case 13..<38:  return "battery.25percent"
        default:       return "battery.0percent"
        }
    }

    /// Resolved once per render — single source of truth for both view and tests.
    private var visualState: PowerFlowVisualState {
        Self.resolveVisualState(battery: battery, mode: mode)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch visualState {
            case .noPowerData:
                noPowerDataView
            case .onBattery:
                onBatteryView
            case .peakLoad:
                peakLoadView(batteryDrain: abs(battery.batteryPower ?? 0))
            case .pluggedInCharging:
                pluggedInAdapterView {
                    flowBar(
                        label: String(format: "%.1f W", battery.batteryPower ?? 0),
                        icon: "battery.100percent.bolt",
                        color: .green,
                        proportion: batteryProportion(battery.batteryPower ?? 0)
                    )
                }
            case .pluggedInTrickleCharging:
                pluggedInAdapterView {
                    flowBar(
                        label: "Charging",
                        icon: "battery.100percent.bolt",
                        color: .green,
                        proportion: 0.1
                    )
                }
            case .pluggedInPaused:
                pluggedInAdapterView { EmptyView() }
            case .pluggedInStopping:
                pluggedInAdapterView {
                    let bp = battery.batteryPower ?? 0
                    let label = bp > 0.1
                        ? String(format: "Stopping\u{2026} %.1f W", bp)
                        : "Stopping\u{2026}"
                    flowBar(
                        label: label,
                        icon: "stop.circle",
                        color: .orange,
                        proportion: bp > 0.1 ? batteryProportion(bp) : 0.3
                    )
                }
            case .pluggedInStarting:
                pluggedInAdapterView {
                    flowBar(
                        label: "Starting\u{2026}",
                        icon: "battery.100percent.bolt",
                        color: .green,
                        proportion: 0.1
                    )
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    // MARK: - No Data View

    private var noPowerDataView: some View {
        HStack(spacing: 8) {
            Image(systemName: battery.isPluggedIn ? "bolt.fill" : "battery.75percent")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(battery.isPluggedIn ? "Plugged In" : "On Battery")
                    .font(.system(size: 11, weight: .medium))
                Text("Power data requires SMC access")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(battery.percentage)%")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
        }
    }

    // MARK: - Plugged In Adapter View

    /// Common layout for all plugged-in states: adapter source + system bar + optional battery bar.
    private func pluggedInAdapterView<BatteryBar: View>(@ViewBuilder batteryBar: () -> BatteryBar) -> some View {
        HStack(spacing: 0) {
            sourceLabel(icon: "bolt.fill", label: adapterWattsText)

            VStack(spacing: 4) {
                if let systemPower = battery.systemPower, systemPower > 0.1 {
                    flowBar(
                        label: String(format: "%.1f W", systemPower),
                        icon: "laptopcomputer",
                        color: .blue,
                        proportion: systemProportion
                    )
                }

                batteryBar()
            }
        }
    }

    // MARK: - Peak Load View (two sources → system)

    /// When system draws more than adapter can provide, battery supplements.
    /// Layout: two rows, each with its own source label.
    private func peakLoadView(batteryDrain: Double) -> some View {
        let adapterPower = battery.adapterPower ?? 0
        let total = adapterPower + batteryDrain
        let adapterShare = total > 0 ? CGFloat(adapterPower / total) : 0.5
        let batteryShare = total > 0 ? CGFloat(batteryDrain / total) : 0.5

        return VStack(spacing: 4) {
            // Row 1: adapter contribution
            if adapterPower > 0.1 {
                HStack(spacing: 0) {
                    sourceLabel(icon: "bolt.fill", label: adapterWattsText)
                    flowBar(
                        label: String(format: "%.1f W", adapterPower),
                        icon: "laptopcomputer",
                        color: .blue,
                        proportion: adapterShare.clamped(to: 0.1...1.0)
                    )
                }
            }

            // Row 2: battery contribution
            HStack(spacing: 0) {
                sourceLabel(icon: batterySourceIcon, label: nil)
                flowBar(
                    label: String(format: "%.1f W", batteryDrain),
                    icon: "laptopcomputer",
                    color: .orange,
                    proportion: batteryShare.clamped(to: 0.1...1.0)
                )
            }
        }
    }

    // MARK: - On Battery View (also used for force discharge)

    private var onBatteryView: some View {
        HStack(spacing: 0) {
            sourceLabel(icon: batterySourceIcon, label: nil)

            VStack(spacing: 4) {
                if let systemPower = battery.systemPower, systemPower > 0.1 {
                    flowBar(
                        label: String(format: "%.1f W", systemPower),
                        icon: "laptopcomputer",
                        color: .orange,
                        proportion: 1.0
                    )
                } else if let bp = battery.batteryPower, abs(bp) > 0.1 {
                    // Fallback to battery power if system power unavailable
                    flowBar(
                        label: String(format: "%.1f W", abs(bp)),
                        icon: "laptopcomputer",
                        color: .orange,
                        proportion: 1.0
                    )
                } else {
                    flowBar(
                        label: "Discharging",
                        icon: "laptopcomputer",
                        color: .orange,
                        proportion: 1.0
                    )
                }
            }
        }
    }

    // MARK: - Components

    private func sourceLabel(icon: String, label: String?) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            if let label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44)
    }

    private func flowBar(label: String, icon: String, color: Color, proportion: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right")
                .font(.system(size: 8))
                .foregroundStyle(color.opacity(0.6))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.15))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.4))
                        .frame(width: max(geo.size.width * proportion, 20))
                }
                .overlay(
                    Text(label)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                )
            }
            .frame(height: 20)

            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 20)
        }
    }

    // MARK: - Computed Values

    private var adapterWattsText: String {
        if let adapter = battery.adapterPower, adapter > 0.1 {
            return String(format: "%.0fW", adapter)
        }
        return "AC"
    }

    private var batterySourceIcon: String {
        Self.batterySourceIcon(percentage: battery.percentage)
    }

    private var systemProportion: CGFloat {
        guard let adapter = battery.adapterPower, adapter > 0.1,
              let system = battery.systemPower else { return 1.0 }
        return CGFloat(system / adapter).clamped(to: 0.1...1.0)
    }

    private func batteryProportion(_ batteryPower: Double) -> CGFloat {
        guard let adapter = battery.adapterPower, adapter > 0.1 else { return 0.3 }
        return CGFloat(batteryPower / adapter).clamped(to: 0.1...1.0)
    }
}
