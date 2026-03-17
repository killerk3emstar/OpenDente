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
                PowerFlowView(battery: battery.batteryState, mode: charging.mode)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if !charging.isHelperInstalled {
                helperWarning
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
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

            if charging.mode == .topUp {
                Button(action: { charging.cancelTopUp() }) {
                    Label("Cancel", systemImage: "xmark.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            } else {
                Button(action: { charging.startTopUp() }) {
                    Label("Top Up", systemImage: "arrow.up.to.line.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!battery.batteryState.isPluggedIn)
            }

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
        let items = settings.popoverDetailItems

        return VStack(spacing: 6) {
            ForEach(items) { item in
                if let row = detailValue(for: item, state: state) {
                    detailRow(row.label, value: row.value)
                }
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

    private func detailValue(for item: PopoverDetailItem, state: BatteryState) -> (label: String, value: String)? {
        switch item {
        case .temperature:
            guard let temp = state.temperature else { return nil }
            return ("Temperature", String(format: "%.1f°C", temp))
        case .batteryHealth:
            guard let health = state.healthPercentage else { return nil }
            return ("Battery Health", String(format: "%.1f%%", health))
        case .cycleCount:
            guard let cycles = state.cycleCount else { return nil }
            return ("Cycle Count", "\(cycles)")
        case .timeRemaining:
            return charging.mode.timeRemainingDisplay(
                chargeLimit: settings.chargeLimit,
                percentage: state.percentage,
                timeToFull: state.timeToFull,
                timeToEmpty: state.timeToEmpty
            )
        case .systemPower:
            guard let power = state.systemPower, power > 0 else { return nil }
            return ("System Power", String(format: "%.1f W", power))
        case .adapterPower:
            guard let adapter = state.adapterPower, adapter > 0 else { return nil }
            return ("Adapter Power", String(format: "%.1f W", adapter))
        case .voltage:
            guard let voltage = state.voltage else { return nil }
            return ("Voltage", String(format: "%.2f V", voltage))
        case .amperage:
            guard let amperage = state.amperage else { return nil }
            return ("Current", String(format: "%.3f A", amperage))
        case .currentCapacity:
            guard let current = state.currentCapacity, let max = state.maxCapacity else { return nil }
            return ("Capacity", "\(current) / \(max) mAh")
        case .batteryPower:
            guard let power = state.batteryPower, power > 0.1 else { return nil }
            return ("Battery Power", String(format: "%.1f W", power))
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

    // MARK: - Helper Warning

    private var needsHelperApproval: Bool {
        HelperInstaller.status == .requiresApproval
    }

    private var helperWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(needsHelperApproval
                 ? "Helper needs approval in System Settings"
                 : "Helper not installed — charging control unavailable")
                .font(.system(size: 10))
            Spacer()
            if needsHelperApproval {
                Button("Approve") {
                    HelperInstaller.openSystemSettings()
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Button("Install") {
                    openSettings()
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .foregroundStyle(.orange)
    }

    // MARK: - Actions

    private func openSettings() {
        AppDelegate.instance?.openSettingsWindow()
    }
}
