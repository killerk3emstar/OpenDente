import SwiftUI

/// Minimalistic power flow display - shows energy flow direction and wattage
/// without heavy animations. Uses simple bars with numbers.
struct PowerFlowView: View {
    let battery: BatteryState

    private var hasAnyPowerData: Bool {
        battery.systemPower != nil || battery.adapterPower != nil || battery.batteryPower != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasAnyPowerData {
                powerFlowContent
            } else {
                noPowerDataView
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

    // MARK: - Power Flow Content

    @ViewBuilder
    private var powerFlowContent: some View {
        if battery.isPluggedIn {
            pluggedInView
        } else {
            onBatteryView
        }
    }

    // MARK: - Plugged In View

    private var pluggedInView: some View {
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

                if battery.isCharging, let battPower = batteryChargingPower, battPower > 0.1 {
                    flowBar(
                        label: String(format: "%.1f W", battPower),
                        icon: "battery.100percent.bolt",
                        color: .green,
                        proportion: batteryProportion
                    )
                }

                if !battery.isCharging {
                    flowBar(
                        label: "Paused",
                        icon: "laptopcomputer",
                        color: .secondary,
                        proportion: 1.0
                    )
                }
            }
        }
    }

    // MARK: - On Battery View

    private var onBatteryView: some View {
        HStack(spacing: 0) {
            sourceLabel(icon: "battery.75percent", label: batteryWattsText)

            VStack(spacing: 4) {
                if let systemPower = battery.systemPower, systemPower > 0.1 {
                    flowBar(
                        label: String(format: "%.1f W", systemPower),
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

    private func sourceLabel(icon: String, label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
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

    private var batteryWattsText: String {
        if let power = battery.systemPower, power > 0.1 {
            return String(format: "%.0fW", power)
        }
        return "Batt"
    }

    private var batteryChargingPower: Double? {
        guard battery.isCharging else { return nil }
        if let adapter = battery.adapterPower, let system = battery.systemPower, adapter > system {
            return adapter - system
        }
        return battery.batteryPower
    }

    private var systemProportion: CGFloat {
        guard let adapter = battery.adapterPower, adapter > 0.1,
              let system = battery.systemPower else { return 1.0 }
        return CGFloat(system / adapter).clamped(to: 0.1...1.0)
    }

    private var batteryProportion: CGFloat {
        guard let adapter = battery.adapterPower, adapter > 0.1,
              let battPower = batteryChargingPower else { return 0.3 }
        return CGFloat(battPower / adapter).clamped(to: 0.1...1.0)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
