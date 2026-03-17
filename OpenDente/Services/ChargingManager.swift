import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "Charging")

/// Protocol for SMC charging control operations. Enables testing without real hardware.
protocol ChargingControl: Sendable {
    func enableCharging(completion: (@Sendable (Bool, String?) -> Void)?)
    func inhibitCharging(completion: (@Sendable (Bool, String?) -> Void)?)
    func forceDischarge(enable: Bool, completion: (@Sendable (Bool, String?) -> Void)?)
    func resetToDefaults(completion: (@Sendable (Bool, String?) -> Void)?)
    func setMagSafeLED(color: UInt8, completion: (@Sendable (Bool, String?) -> Void)?)
    nonisolated func resetToDefaultsSync(timeout: TimeInterval)
}

extension ChargingControl {
    nonisolated func resetToDefaultsSync() {
        resetToDefaultsSync(timeout: 2.0)
    }
}

extension HelperClient: ChargingControl {}

/// Manages charging logic: charge limit, sailing mode, heat protection, discharge, top up.
/// Writes to SMC require root privileges (via privileged helper).
@MainActor
final class ChargingManager: ObservableObject {

    static let shared = ChargingManager()

    @Published internal(set) var mode: ChargingMode = .idle {
        didSet {
            if mode != oldValue {
                log.info("Mode: \(oldValue.displayName) → \(self.mode.displayName)")
                updateMagSafeLED()
            }
        }
    }
    @Published internal(set) var chargingAPI: SMCChargingAPI = .unknown
    @Published var isHelperInstalled = false

    private let smc = SMCService.shared
    private let battery: BatteryService
    let settings: AppSettings
    private let helper: ChargingControl
    private var cancellables = Set<AnyCancellable>()
    var heatProtectionTimer: Date?

    /// Tracked helper version — used to gate protocol features (e.g. MagSafe LED).
    /// Internal for testability.
    var helperVersion: String?

    /// Last LED color sent to avoid duplicate XPC calls
    private var lastLEDColor: UInt8?

    /// Timestamp of last inhibit send — used to debounce verification re-sends.
    /// Internal for testability.
    var lastInhibitTime: Date?

    private convenience init() {
        self.init(settings: .shared, helper: HelperClient.shared, battery: .shared)
    }

    /// Initializer with dependency injection for testability
    init(settings: AppSettings, helper: ChargingControl, battery: BatteryService) {
        self.settings = settings
        self.helper = helper
        self.battery = battery
    }

    // MARK: - Lifecycle

    func start() {
        log.info("Starting — limit: \(self.settings.chargeLimit)%, sailing: \(self.settings.sailingModeEnabled ? "on" : "off"), heat protection: \(self.settings.heatProtectionEnabled ? "on" : "off")")
        detectChargingAPI()
        connectToHelper()

        // React to battery state changes
        battery.$batteryState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.evaluateState(state)
            }
            .store(in: &cancellables)

        // Evaluate immediately — the Combine publisher delivers on next run loop,
        // but we need mode set before setupStatusItem() runs
        evaluateState(battery.batteryState)
    }

    /// Connect to the helper daemon and start heartbeat.
    /// Called at startup and after helper installation.
    func connectToHelper() {
        let status = HelperInstaller.status
        isHelperInstalled = (status == .enabled)
        log.info("Helper status: \(HelperInstaller.statusDescription)")

        if isHelperInstalled {
            let client = HelperClient.shared
            client.connect()
            // Query the helper's detected API
            client.getChargingAPI { [weak self] api in
                Task { @MainActor in
                    switch api {
                    case "legacy": self?.chargingAPI = .legacy
                    case "tahoe":  self?.chargingAPI = .tahoe
                    default:       break
                    }
                }
            }
            // Query helper version for feature gating (e.g. MagSafe LED requires ≥1.1.0)
            client.getVersion { [weak self] version in
                Task { @MainActor in
                    self?.helperVersion = version
                    log.info("Helper version: \(version)")
                    self?.updateMagSafeLED()
                    // Resync charging state with the (re)connected helper
                    self?.resyncChargingState()
                }
            }
        }
    }

    // MARK: - API Detection

    /// Detect which SMC keys this Mac supports for charging control (read-only, no root needed)
    private func detectChargingAPI() {
        // Try Tahoe keys first (newer)
        if smc.keyExists("CHTE") {
            chargingAPI = .tahoe
            log.info("Detected Tahoe charging API (CHTE/CHIE)")
            return
        }

        // Try legacy keys
        if smc.keyExists("CH0B") {
            chargingAPI = .legacy
            log.info("Detected legacy charging API (CH0B/CH0C)")
            return
        }

        chargingAPI = .unknown
        log.info("No charging control keys detected")
    }

    // MARK: - State Machine

    /// Evaluate battery state and decide charging mode. Internal for testability.
    func evaluateState(_ state: BatteryState) {
        // Skip evaluation if data looks uninitialized (startup race / IOKit not ready).
        // A Mac genuinely at 0% on battery would have timeToEmpty populated.
        guard state.percentage > 0 || state.isCharging || state.isPluggedIn
              || state.timeToEmpty != nil || state.timeToFull != nil else {
            return  // Stay in current mode until real data arrives
        }

        // Not plugged in = on battery, nothing to control
        guard state.isPluggedIn else {
            if mode == .topUp {
                log.info("Top Up ended: unplugged at \(state.percentage)%")
            }
            if mode == .discharging {
                log.info("Discharge ended: unplugged at \(state.percentage)%")
                forceDischarge(false)
            }
            mode = .onBattery
            return
        }

        // Heat protection takes priority
        if settings.heatProtectionEnabled, let temp = state.temperature {
            if temp >= settings.heatProtectionTemp {
                // Reset hysteresis timer on every spike (including re-spikes during cooldown)
                heatProtectionTimer = Date()
                if mode != .heatProtection {
                    log.warning("Heat protection: \(temp, format: .fixed(precision: 1))°C ≥ \(self.settings.heatProtectionTemp)°C at \(state.percentage)%")
                    if mode == .discharging {
                        forceDischarge(false)
                    }
                    inhibitCharging()
                    mode = .heatProtection
                }
                return
            } else if mode == .heatProtection {
                if let timer = heatProtectionTimer {
                    // Hysteresis: wait 5 minutes after temp last exceeded threshold
                    if Date().timeIntervalSince(timer) >= 300 {
                        log.info("Heat protection ended: \(temp, format: .fixed(precision: 1))°C < \(self.settings.heatProtectionTemp)°C, cooldown elapsed")
                        heatProtectionTimer = nil
                        // Fall through to normal evaluation
                    } else {
                        return // Still in hysteresis period
                    }
                }
                // heatProtectionTimer is nil — hysteresis ended, fall through to re-evaluate
            }
        }

        // Top Up mode - charge to 100%
        if mode == .topUp {
            if state.percentage >= 100 {
                // Stay at 100% until unplugged (handled above)
            }
            return
        }

        // Calibration mode - handled separately
        if mode == .calibrating {
            return
        }

        // Discharge mode - don't override until unplugged (or auto-discharge reaches limit)
        if mode == .discharging {
            if settings.automaticDischarge && state.percentage <= settings.chargeLimit {
                log.info("Auto-discharge reached limit: \(state.percentage)% ≤ \(self.settings.chargeLimit)%")
                stopDischarge()
                // Fall through to normal evaluation
            } else {
                return
            }
        }

        let limit = settings.chargeLimit

        // Sailing mode logic
        if settings.sailingModeEnabled {
            let lowerBound = settings.sailingLowerBound

            if state.percentage >= limit {
                // At or above limit - pause charging
                if mode != .paused {
                    log.info("Limit reached: \(state.percentage)% ≥ \(limit)% → inhibiting")
                    inhibitCharging()
                    mode = .paused
                }
            } else if state.percentage >= lowerBound {
                // In sailing range — don't charge, coast on adapter power
                if mode != .sailing {
                    log.info("Sailing: \(state.percentage)% in range \(lowerBound)–\(limit)%")
                    // Only send SMC write if charging isn't already inhibited
                    if mode != .paused {
                        inhibitCharging()
                    }
                    mode = .sailing
                }
            } else {
                // Below sailing range — charge back up to limit
                if mode != .charging {
                    log.info("Below range: \(state.percentage)% < \(lowerBound)% → charging to \(limit)%")
                    enableCharging()
                    mode = .charging
                }
            }
        } else {
            // No sailing mode - simple limit
            if state.percentage >= limit {
                if mode != .paused {
                    log.info("Limit reached: \(state.percentage)% ≥ \(limit)% → inhibiting")
                    inhibitCharging()
                    mode = .paused
                }
            } else {
                if mode != .charging {
                    log.info("Below limit: \(state.percentage)% < \(limit)% → charging")
                    enableCharging()
                    mode = .charging
                }
            }
        }

        // Automatic discharge: if battery > limit and auto-discharge is on
        if settings.automaticDischarge && state.percentage > limit && mode == .paused {
            log.info("Auto-discharge: \(state.percentage)% > \(limit)%")
            startDischarge()
        }

        // Verification: system is the source of truth.
        // If we think charging is inhibited but IOKit still reports isCharging,
        // the SMC write may not have taken effect — re-send.
        // Debounce: wait at least 5s after last inhibit for IOKit to catch up.
        if (mode == .paused || mode == .sailing || mode == .heatProtection)
            && state.isCharging {
            let elapsed = lastInhibitTime.map { Date().timeIntervalSince($0) } ?? .infinity
            if elapsed >= 5 {
                log.warning("System still reports charging in \(self.mode.displayName) mode — re-sending inhibit")
                inhibitCharging()
            }
        }

        // Refresh LED — picks up settings changes without waiting for a mode transition.
        // Cached (sendLEDColor skips if color unchanged), so no extra XPC calls normally.
        updateMagSafeLED()
    }

    // MARK: - Actions

    /// Start Top Up - temporarily charge to 100%
    func startTopUp() {
        log.info("Top Up started at \(self.battery.batteryState.percentage)% (limit was \(self.settings.chargeLimit)%)")

        enableCharging()
        mode = .topUp
    }

    /// Cancel Top Up manually — inhibit charging as a safe default,
    /// next poll will re-evaluate the correct mode.
    func cancelTopUp() {
        guard mode == .topUp else { return }
        log.info("Top Up cancelled by user at \(self.battery.batteryState.percentage)%")

        inhibitCharging()
        mode = .idle
    }

    /// Manually start discharge
    func startDischarge() {
        log.info("Discharge started at \(self.battery.batteryState.percentage)%")
        forceDischarge(true)
        mode = .discharging
    }

    /// Stop discharge
    func stopDischarge() {
        log.info("Discharge stopped at \(self.battery.batteryState.percentage)%")
        forceDischarge(false)
        mode = .idle
    }

    /// Manually pause charging at current level
    func pauseCharging() {
        log.info("Charging paused manually at \(self.battery.batteryState.percentage)%")
        inhibitCharging()
        mode = .paused
    }

    // MARK: - SMC Charging Control (via Helper)

    /// Disable charging (battery stops receiving charge, Mac runs from adapter)
    private func inhibitCharging() {
        guard isHelperInstalled else { return }
        guard chargingAPI != .unknown else {
            log.warning("Cannot inhibit charging: no API detected")
            return
        }

        lastInhibitTime = Date()
        helper.inhibitCharging { [weak self] success, error in
            if success {
                log.info("Charging inhibited")
            } else {
                log.error("Failed to inhibit charging: \(error ?? "unknown error")")
                Task { @MainActor in self?.mode = .idle }
            }
        }
    }

    /// Enable charging (allow battery to charge)
    private func enableCharging() {
        guard isHelperInstalled else { return }
        guard chargingAPI != .unknown else {
            log.warning("Cannot enable charging: no API detected")
            return
        }

        helper.enableCharging { [weak self] success, error in
            if success {
                log.info("Charging enabled")
            } else {
                log.error("Failed to enable charging: \(error ?? "unknown error")")
                Task { @MainActor in self?.mode = .idle }
            }
        }
    }

    /// Force discharge (Mac runs from battery while plugged in)
    private func forceDischarge(_ enable: Bool) {
        guard isHelperInstalled else { return }
        guard chargingAPI != .unknown else {
            log.warning("Cannot set discharge: no API detected")
            return
        }

        helper.forceDischarge(enable: enable) { [weak self] success, error in
            if success {
                log.info("Force discharge: \(enable)")
            } else {
                log.error("Failed to set discharge: \(error ?? "unknown error")")
                Task { @MainActor in self?.mode = .idle }
            }
        }
    }

    // MARK: - Helper Resync

    /// Re-send current mode's SMC commands after helper reconnects
    private func resyncChargingState() {
        log.info("Resyncing charging state after helper reconnect (mode: \(self.mode.displayName))")
        switch mode {
        case .charging, .topUp:
            enableCharging()
        case .paused, .sailing, .heatProtection:
            inhibitCharging()
        case .discharging:
            forceDischarge(true)
        case .onBattery, .idle, .calibrating:
            break
        }
        updateMagSafeLED()
    }

    // MARK: - MagSafe LED

    /// Update MagSafe LED to reflect current mode.
    /// Gated behind helper version check — calling setMagSafeLED on an old helper
    /// that doesn't implement it would disrupt the XPC connection.
    private func updateMagSafeLED() {
        guard settings.controlMagSafeLED else {
            // If disabled, reset to auto (only if we previously set something)
            if lastLEDColor != nil && lastLEDColor != 0x00 {
                sendLEDColor(0x00)
            }
            return
        }
        guard let version = helperVersion,
              version.isVersionAtLeast(HelperConstants.minVersionMagSafeLED) else {
            log.debug("LED update skipped: helperVersion=\(self.helperVersion ?? "nil")")
            return
        }

        let color: UInt8
        switch mode {
        case .charging, .topUp, .discharging:
            color = 0x04  // orange — actively charging or discharging
        case .paused, .sailing, .heatProtection, .calibrating:
            color = settings.magSafeLEDOffWhenInactive ? 0x01 : 0x03  // off or green
        case .onBattery, .idle:
            color = 0x00  // auto — MagSafe not connected or unknown
        }

        sendLEDColor(color)
    }

    private func sendLEDColor(_ color: UInt8) {
        guard color != lastLEDColor else { return }
        lastLEDColor = color
        helper.setMagSafeLED(color: color) { success, error in
            if !success, let error {
                log.debug("MagSafe LED not available: \(error)")
            }
        }
    }

    // MARK: - Cleanup

    /// Reset all SMC charging keys to defaults (enable charging, stop discharge)
    func resetToDefaults() {
        helper.resetToDefaults { success, _ in
            if success {
                log.info("Reset to defaults via helper")
            } else {
                log.warning("Helper reset failed, attempting direct reset")
            }
        }
        // Reset LED to system default (only if helper supports it)
        if let version = helperVersion,
           version.isVersionAtLeast(HelperConstants.minVersionMagSafeLED) {
            helper.setMagSafeLED(color: 0x00, completion: nil)
        }
        lastLEDColor = nil
        mode = .idle
    }

    /// Synchronous reset for app termination
    func resetToDefaultsSync() {
        log.info("App terminating — resetting SMC to defaults")
        helper.resetToDefaultsSync(timeout: 2.0)
        mode = .idle
    }
}
