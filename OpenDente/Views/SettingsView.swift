import SwiftUI
import ServiceManagement

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

            BatteryInfoTab()
                .tabItem { Label("Battery", systemImage: "battery.100percent") }
        }
        .frame(width: 450, height: 360)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                Toggle("Show Notifications", isOn: $settings.showNotifications)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[Settings] Failed to set launch at login: \(error)")
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
                Toggle("Stop Charging when Sleeping", isOn: $settings.stopChargingWhenSleeping)
                Toggle("Use Hardware Battery Percentage", isOn: $settings.useHardwareBatteryPercentage)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Status Bar Tab

struct StatusBarTab: View {
    @ObservedObject var settings = AppSettings.shared

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
                HStack {
                    Image(systemName: "battery.75percent.bolt")
                    Text(statusBarPreview)
                        .font(.system(size: 12, design: .monospaced))
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

    private var statusBarPreview: String {
        var parts: [String] = []
        if settings.statusBarShowPercentage { parts.append("80%") }
        if settings.statusBarShowTemperature { parts.append("32°C") }
        if settings.statusBarShowPower { parts.append("21W") }
        return parts.isEmpty ? "(icon only)" : parts.joined(separator: " ")
    }
}

// MARK: - Battery Info Tab

struct BatteryInfoTab: View {
    @ObservedObject var battery = BatteryService.shared
    @ObservedObject var charging = ChargingManager.shared

    var body: some View {
        let state = battery.batteryState

        Form {
            Section("Status") {
                infoRow("Mode", value: charging.mode.displayName)
                infoRow("Power Source", value: state.powerSource)
                infoRow("Percentage", value: "\(state.percentage)%")
                if let temp = state.temperature {
                    infoRow("Temperature", value: String(format: "%.1f°C", temp))
                }
            }

            Section("Capacity") {
                if let current = state.currentCapacity {
                    infoRow("Current", value: "\(current) mAh")
                }
                if let max = state.maxCapacity {
                    infoRow("Full Charge", value: "\(max) mAh")
                }
                if let design = state.designCapacity {
                    infoRow("Design", value: "\(design) mAh")
                }
                if let health = state.healthPercentage {
                    infoRow("Health", value: String(format: "%.1f%%", health))
                }
                if let cycles = state.cycleCount {
                    infoRow("Cycle Count", value: "\(cycles)")
                }
            }

            Section("Power") {
                if let voltage = state.voltage {
                    infoRow("Voltage", value: String(format: "%.2f V", voltage))
                }
                if let amperage = state.amperage {
                    infoRow("Current", value: String(format: "%.2f A", amperage))
                }
                if let system = state.systemPower {
                    infoRow("System Power", value: String(format: "%.1f W", system))
                }
                if let adapter = state.adapterPower {
                    infoRow("Adapter Power", value: String(format: "%.1f W", adapter))
                }
            }

            Section("SMC") {
                infoRow("SMC Available", value: battery.smcAvailable ? "Yes" : "No")
                infoRow("Charging API", value: chargingAPIName)
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

    private func infoRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
