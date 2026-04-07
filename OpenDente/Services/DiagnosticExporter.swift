import AppKit
import Foundation
import OSLog
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "Diagnostics")

/// One-click diagnostic report generator for troubleshooting.
/// Collects system info, current state, settings, and recent logs into a text file.
@MainActor
enum DiagnosticExporter {

    /// Show save panel and write diagnostic report.
    static func exportWithSavePanel() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        panel.nameFieldStringValue = "OpenDente-Diagnostics-\(timestamp).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let report = generateReport()
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            log.notice("Diagnostic report exported")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            log.error("Failed to export diagnostic report: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Generate the full diagnostic report text.
    static func generateReport() -> String {
        var r = ""

        // Header
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osStr = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        var model = "unknown"
        var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 {
                model = String(cString: buf)
            }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        r += "=== OpenDente Diagnostic Report ===\n"
        r += "Generated: \(iso.string(from: Date()))\n"
        r += "App Version: \(appVersion) (\(buildNumber))\n"
        r += "Helper Version: \(ChargingManager.shared.helperVersion ?? "unknown")\n"
        r += "macOS: \(osStr)\n"
        r += "Model: \(model)\n"
        r += "\n"

        // Current State
        let charging = ChargingManager.shared
        let battery = BatteryService.shared
        let settings = AppSettings.shared
        let state = battery.batteryState
        let pct = state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)

        r += "=== Current State ===\n"
        r += "Mode: \(charging.mode.displayName)\n"
        r += "Charge Limit: \(settings.chargeLimit)%\n"

        r += "Sailing: \(settings.sailingModeEnabled ? "on" : "off")"
        if settings.sailingModeEnabled {
            r += " (range: \(settings.sailingRange)%, lower bound: \(settings.sailingLowerBound)%)"
        }
        r += "\n"

        r += "Heat Protection: \(settings.heatProtectionEnabled ? "on" : "off")"
        if settings.heatProtectionEnabled {
            r += " (threshold: \(String(format: "%.1f", settings.heatProtectionTemp))°C)"
        }
        r += "\n"

        r += "Battery: \(pct)%"
        if let temp = state.temperature {
            r += ", \(String(format: "%.1f", temp))°C"
        }
        r += ", \(state.isPluggedIn ? "plugged in" : "on battery")"
        r += ", \(state.isCharging ? "charging" : "not charging")"
        r += "\n"

        let apiName: String
        switch charging.chargingAPI {
        case .tahoe: apiName = "Tahoe (CHTE/CHIE)"
        case .legacy: apiName = "Legacy (CH0B/CH0C)"
        case .unknown: apiName = "Not detected"
        }
        r += "Charging API: \(apiName)\n"
        r += "Helper: \(HelperInstaller.statusDescription)\n"
        r += "SMC Available: \(battery.smcAvailable ? "Yes" : "No")\n"

        if let reason = state.notChargingReason, reason != 0 {
            r += "NotChargingReason: 0x\(String(reason, radix: 16, uppercase: true))\n"
        }
        if let reason = state.chargerInhibitReason, reason != 0 {
            r += "ChargerInhibitReason: 0x\(String(reason, radix: 16, uppercase: true))\n"
        }
        if charging.systemChargeLimitConflict {
            r += "System Charge Limit Conflict: YES\n"
        }
        r += "\n"

        // Settings
        r += "=== Settings ===\n"
        r += "Automatic Discharge: \(settings.automaticDischarge ? "on" : "off")\n"
        r += "Control MagSafe LED: \(settings.controlMagSafeLED ? "on" : "off")"
        if settings.controlMagSafeLED {
            r += " (off when inactive: \(settings.magSafeLEDOffWhenInactive ? "on" : "off"))"
        }
        r += "\n"
        r += "Stop Charging When Sleeping: \(settings.stopChargingWhenSleeping ? "on" : "off")\n"
        r += "Disable Sleep Until Charge Limit: \(settings.disableSleepUntilChargeLimit ? "on" : "off")\n"
        r += "Use Hardware Battery Percentage: \(settings.useHardwareBatteryPercentage ? "on" : "off")\n"
        r += "\n"

        // Logs
        r += "=== Logs (last 3 days) ===\n"
        appendLogs(&r)

        return r
    }

    // MARK: - Private

    private static func appendLogs(_ r: inout String) {
        do {
            let store = try OSLogStore(scope: .system)
            let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 60 * 60)
            let position = store.position(date: threeDaysAgo)
            let predicate = NSPredicate(
                format: "subsystem == 'com.opendente.app' OR subsystem == 'com.opendente.helper'"
            )

            let entries = try store.getEntries(at: position, matching: predicate)
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

            var count = 0
            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                let ts = dateFormatter.string(from: logEntry.date)
                let level = levelString(logEntry.level)
                r += "\(ts) [\(logEntry.subsystem):\(logEntry.category)] [\(level)] \(logEntry.composedMessage)\n"
                count += 1
            }

            if count == 0 {
                r += "(No log entries found in the last 3 days)\n"
            } else {
                r += "\n(\(count) log entries)\n"
            }
        } catch {
            r += "(Failed to read log store: \(error.localizedDescription))\n"
            r += "(Fallback: run in Terminal: log show --predicate 'subsystem == \"com.opendente.app\" OR subsystem == \"com.opendente.helper\"' --last 3d --info)\n"
        }
    }

    private static func levelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug:       return "debug"
        case .info:        return "info"
        case .notice:      return "notice"
        case .error:       return "error"
        case .fault:       return "fault"
        @unknown default:  return "unknown"
        }
    }
}
