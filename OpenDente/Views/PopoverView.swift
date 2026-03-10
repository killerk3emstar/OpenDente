import SwiftUI

/// Main popover content shown when clicking the status bar icon
struct PopoverView: View {
    @ObservedObject var battery = BatteryService.shared
    @ObservedObject var charging = ChargingManager.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            batteryBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            if settings.showPowerFlow {
                PowerFlowView(battery: battery.batteryState)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()

            detailsGrid
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            bottomBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 320)
        .onAppear {
            battery.setPopoverVisible(true)
        }
        .onDisappear {
            battery.setPopoverVisible(false)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Limit: \(settings.chargeLimit)%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Image(systemName: charging.mode.statusBarIcon)
                        .font(.system(size: 10))
                    Text(charging.mode.displayName)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: { charging.startTopUp() }) {
                Label("Top Up", systemImage: "arrow.up.to.line.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!battery.batteryState.isPluggedIn || charging.mode == .topUp)

            Button(action: { openSettings() }) {
                Image(systemName: "gear")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Battery Bar

    private var batteryBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let percentage = CGFloat(battery.batteryState.percentage) / 100.0
            let limitPosition = CGFloat(settings.chargeLimit) / 100.0
            let sailingLower = CGFloat(settings.sailingLowerBound) / 100.0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternarySystemFill))

                RoundedRectangle(cornerRadius: 6)
                    .fill(batteryColor)
                    .frame(width: width * percentage)

                if settings.sailingModeEnabled {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 1)
                        .offset(x: width * sailingLower)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 2)
                    .offset(x: width * limitPosition - 1)

                HStack {
                    modeIcon
                        .font(.system(size: 11, weight: .bold))
                    Text("\(battery.batteryState.percentage)%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(percentage > 0.3 ? .white : .primary)
                .padding(.leading, 8)
            }
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private var modeIcon: some View {
        switch charging.mode {
        case .charging, .topUp:
            Image(systemName: "bolt.fill")
        case .discharging:
            Image(systemName: "bolt.fill")
                .rotationEffect(.degrees(180))
        case .sailing:
            Image(systemName: "wind")
        case .heatProtection:
            Image(systemName: "thermometer.sun.fill")
        default:
            EmptyView()
        }
    }

    private var batteryColor: Color {
        switch charging.mode {
        case .charging, .topUp:
            return .green
        case .discharging:
            return .orange
        case .heatProtection:
            return .red
        case .sailing:
            return .blue
        default:
            if battery.batteryState.percentage <= 20 {
                return .red
            }
            return .green
        }
    }

    // MARK: - Details Grid

    private var detailsGrid: some View {
        let state = battery.batteryState

        return VStack(spacing: 6) {
            if let temp = state.temperature {
                detailRow("Temperature", value: String(format: "%.1f°C", temp))
            }
            if let health = state.healthPercentage {
                detailRow("Battery Health", value: String(format: "%.1f%%", health))
            }
            if let cycles = state.cycleCount {
                detailRow("Cycle Count", value: "\(cycles)")
            }
            if let time = state.timeRemainingFormatted {
                detailRow(state.isCharging ? "Time to Full" : "Time Remaining", value: time)
            }
            if let power = state.systemPower, power > 0 {
                detailRow("System Power", value: String(format: "%.1f W", power))
            }
            if let adapter = state.adapterPower, adapter > 0 {
                detailRow("Adapter Power", value: String(format: "%.1f W", adapter))
            }

            if !battery.smcAvailable {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text("SMC not available — detailed data unavailable")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            HStack(spacing: 6) {
                Text("\(settings.chargeLimit)%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 35)

                Slider(
                    value: Binding(
                        get: { Double(settings.chargeLimit) },
                        set: { settings.chargeLimit = Int($0) }
                    ),
                    in: 20...100,
                    step: 5
                )
                .controlSize(.small)
            }

            Spacer()

            Button("Quit") {
                ChargingManager.shared.resetToDefaults()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func openSettings() {
        // Close popover first
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.openSettingsWindow()
        }
    }
}
