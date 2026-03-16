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
    }

    /// Connect to the helper daemon and start heartbeat
    private func connectToHelper() {
        let status = HelperInstaller.status
        isHelperInstalled = (status == .enabled)
        log.info("Helper status: \(HelperInstaller.statusDescription)")

        if isHelperInstalled {
            let client = HelperClient.shared
            client.connect()
            // Query the helper's detected API
            client.getChargingAPI { [weak self] api in
                // Already dispatched to main by HelperClient
                Task { @MainActor in
                    switch api {
                    case "legacy": self?.chargingAPI = .legacy
                    case "tahoe":  self?.chargingAPI = .tahoe
                    default:       break
                    }
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
        // Not plugged in = on battery, nothing to control
        guard state.isPluggedIn else {
            if mode == .topUp {
                log.info("Top Up ended: unplugged at \(state.percentage)%")
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

        // Discharge mode - user-initiated, don't override until unplugged
        if mode == .discharging {
            return
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
        guard chargingAPI != .unknown else {
            log.warning("Cannot inhibit charging: no API detected")
            return
        }

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
        mode = .idle
    }

    /// Synchronous reset for app termination
    func resetToDefaultsSync() {
        log.info("App terminating — resetting SMC to defaults")
        helper.resetToDefaultsSync(timeout: 2.0)
        mode = .idle
    }
}
