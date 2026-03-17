import SwiftUI
import ServiceManagement
import os.log

/// Settings window with tabbed interface
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }

            ChargingTab()
                .tabItem { Label("Charging", systemImage: "bolt.fill") }

            StatusBarTab()
                .tabItem { Label("Status Bar", systemImage: "menubar.rectangle") }

            PopoverItemsTab()
                .tabItem { Label("Popover", systemImage: "list.bullet") }

            BatteryInfoTab()
                .tabItem { Label("Battery", systemImage: "battery.100percent") }
        }
        .frame(width: 450, height: 400)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var charging = ChargingManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                Toggle("Show Notifications", isOn: $settings.showNotifications)
            }

            Section("Privileged Helper") {
                LabeledContent("Status") {
                    Text(HelperInstaller.statusDescription)
                        .foregroundStyle(charging.isHelperInstalled ? .green : .orange)
                }

                if !charging.isHelperInstalled {
                    helperActions

                    Text("The helper daemon is required for charging control. It runs as root to write SMC keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var helperActions: some View {
        let status = HelperInstaller.status
        if status == .requiresApproval {
            Button("Open System Settings") {
                HelperInstaller.openSystemSettings()
            }
            Text("Toggle OpenDente ON in Login Items to approve the helper.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Button("Install Helper") {
                if HelperInstaller.register() {
                    charging.connectToHelper()
                }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Logger(subsystem: "com.opendente.app", category: "Settings").error("Failed to set launch at login: \(error.localizedDescription)")
        }
    }
}

// MARK: - Charging Tab

struct ChargingTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var charging = ChargingManager.shared

    var body: some View {
        Form {
            Section("Charge Limit") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(settings.chargeLimit) },
                            set: { settings.chargeLimit = Int($0) }
                        ),
                        in: 20...100,
                        step: 5
                    )
                    Text("\(settings.chargeLimit)%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 45, alignment: .trailing)
                }
            }

            Section("Sailing Mode") {
                Toggle("Enable Sailing Mode", isOn: $settings.sailingModeEnabled)

                if settings.sailingModeEnabled {
                    HStack {
                        Text("Range")
                        Slider(
                            value: Binding(
                                get: { Double(settings.sailingRange) },
                                set: { settings.sailingRange = Int($0) }
                            ),
                            in: 2...25,
                            step: 1
                        )
                        Text("\(settings.sailingRange)%")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 35, alignment: .trailing)
                    }
                    Text("Won't recharge until battery drops to \(settings.sailingLowerBound)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Heat Protection") {
                Toggle("Enable Heat Protection", isOn: $settings.heatProtectionEnabled)

                if settings.heatProtectionEnabled {
                    HStack {
                        Text("Max Temperature")
                        Slider(
                            value: $settings.heatProtectionTemp,
                            in: 30...45,
                            step: 1
                        )
                        Text(String(format: "%.0f°C", settings.heatProtectionTemp))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 45, alignment: .trailing)
                    }
                }
            }

            Section("Other") {
                Toggle("Automatic Discharge", isOn: $settings.automaticDischarge)
                Toggle("Control MagSafe LED", isOn: $settings.controlMagSafeLED)
                if settings.controlMagSafeLED {
                    Toggle("Turn off LED when not charging", isOn: $settings.magSafeLEDOffWhenInactive)
                        .padding(.leading, 16)
                    Text("Off when limit reached/sailing, orange when charging. Otherwise green/orange.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                } else {
                    Text("Orange when charging, green when limit reached. Requires MagSafe.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Toggle("Stop Charging when Sleeping ★", isOn: $settings.stopChargingWhenSleeping)
                Toggle("Use Hardware Battery Percentage", isOn: $settings.useHardwareBatteryPercentage)

                Text("★ Not yet implemented — coming in a future update")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Status Bar Tab

struct StatusBarTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var battery = BatteryService.shared
    @ObservedObject var charging = ChargingManager.shared

    var body: some View {
        Form {
            Section("Show in Status Bar") {
                Toggle("Battery Percentage", isOn: $settings.statusBarShowPercentage)
                Toggle("Temperature", isOn: $settings.statusBarShowTemperature)
                Toggle("Power Usage", isOn: $settings.statusBarShowPower)
                Toggle("Charging Mode Icon", isOn: $settings.statusBarShowMode)
            }

            Section("Popover") {
                Toggle("Show Power Flow", isOn: $settings.showPowerFlow)
            }

            Section {
                Text("Preview:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: statusBarIcon)
                        .font(.system(size: 15))
                    if !statusBarPreview.isEmpty {
                        Text(statusBarPreview)
                            .font(.system(size: 13, design: .monospaced))
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
        .formStyle(.grouped)
    }

    private var statusBarIcon: String {
        let state = battery.batteryState
        let pct = state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)
        return charging.mode.batteryIconName(percentage: pct, isCharging: state.isCharging)
    }

    private var statusBarPreview: String {
        let state = battery.batteryState
        let pct = state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)
        var parts: [String] = []
        if settings.statusBarShowPercentage {
            parts.append("\(pct)%")
        }
        if settings.statusBarShowTemperature, let temp = state.temperature {
            parts.append(String(format: "%.0f°", temp))
        }
        if settings.statusBarShowPower, let power = state.systemPower, power > 0 {
            parts.append(String(format: "%.0fW", power))
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Popover Items Tab

struct PopoverItemsTab: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var enabledItems: [PopoverDetailItem] = []
    @State private var disabledItems: [PopoverDetailItem] = []

    var body: some View {
        VStack(spacing: 0) {
            Text("Drag to reorder. Toggle to show/hide.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

            List {
                Section("Visible") {
                    ForEach(enabledItems) { item in
                        PopoverItemRow(item: item, isEnabled: true) {
                            disableItem(item)
                        }
                    }
                    .onMove { from, to in
                        enabledItems.move(fromOffsets: from, toOffset: to)
                        save()
                    }
                }

                Section("Hidden") {
                    ForEach(disabledItems) { item in
                        PopoverItemRow(item: item, isEnabled: false) {
                            enableItem(item)
                        }
                    }
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        enabledItems = settings.popoverDetailItems
        let enabledSet = Set(enabledItems.map(\.rawValue))
        disabledItems = PopoverDetailItem.allCases.filter { !enabledSet.contains($0.rawValue) }
    }

    private func save() {
        settings.popoverDetailItems = enabledItems
    }

    private func disableItem(_ item: PopoverDetailItem) {
        enabledItems.removeAll { $0 == item }
        disabledItems.append(item)
        save()
    }

    private func enableItem(_ item: PopoverDetailItem) {
        disabledItems.removeAll { $0 == item }
        enabledItems.append(item)
        save()
    }
}

struct PopoverItemRow: View {
    let item: PopoverDetailItem
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .frame(width: 18)

            Text(item.displayName)
                .foregroundStyle(isEnabled ? .primary : .secondary)

            Spacer()

            Button(action: onToggle) {
                Image(systemName: isEnabled ? "eye.fill" : "eye.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(isEnabled ? .blue : .secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Battery Info Tab

struct BatteryInfoTab: View {
    @ObservedObject var battery = BatteryService.shared
    @ObservedObject var charging = ChargingManager.shared

    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        let state = battery.batteryState

        Form {
            Section("Battery") {
                infoRow("macOS Percentage", value: "\(state.percentage)%")
                if let hw = state.hardwarePercentage {
                    infoRow("Hardware SoC", value: "\(hw)%")
                }
                if let current = state.currentCapacity, let max = state.maxCapacity {
                    infoRow("Capacity", value: "\(current) / \(max) mAh")
                }
                if let design = state.designCapacity {
                    infoRow("Design Capacity", value: "\(design) mAh")
                }
                if let health = state.healthPercentage {
                    infoRow("Health", value: String(format: "%.1f%%", health))
                }
                if let cycles = state.cycleCount {
                    infoRow("Cycle Count", value: "\(cycles)")
                }
                if let temp = state.temperature {
                    infoRow("Temperature", value: String(format: "%.1f°C", temp))
                }
            }

            Section("Power") {
                infoRow("Source", value: state.powerSource)
                if let voltage = state.voltage {
                    infoRow("Voltage", value: String(format: "%.2f V", voltage))
                }
                if let amperage = state.amperage {
                    infoRow("Current", value: String(format: "%.2f A", amperage))
                }
                if let power = state.batteryPower {
                    infoRow("Battery Power", value: String(format: "%.1f W", abs(power)))
                }
                if let system = state.systemPower {
                    infoRow("System Power", value: String(format: "%.1f W", system))
                }
                if let adapter = state.adapterPower {
                    infoRow("Adapter Power", value: String(format: "%.1f W", adapter))
                }
            }

            Section("Control") {
                infoRow("Mode", value: charging.mode.displayName)
                infoRow("Charging API", value: chargingAPIName)
                if settings.controlMagSafeLED {
                    infoRow("MagSafe LED", value: ledColorName)
                }
                infoRow("SMC Available", value: battery.smcAvailable ? "Yes" : "No")
                if let version = charging.helperVersion {
                    infoRow("Helper Version", value: version)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var chargingAPIName: String {
        switch charging.chargingAPI {
        case .legacy: return "Legacy (CH0B/CH0C)"
        case .tahoe:  return "Tahoe (CHTE/CHIE)"
        case .unknown: return "Not detected"
        }
    }

    private var ledColorName: String {
        switch charging.lastLEDColor {
        case 0x00: return "Auto"
        case 0x01: return "Off"
        case 0x03: return "Green"
        case 0x04: return "Orange"
        default:   return charging.lastLEDColor.map { String(format: "0x%02X", $0) } ?? "–"
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
