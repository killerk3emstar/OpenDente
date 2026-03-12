import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "Charging")

/// Manages charging logic: charge limit, sailing mode, heat protection, discharge, top up.
/// Writes to SMC require root privileges (via privileged helper).
@MainActor
final class ChargingManager: ObservableObject {

    static let shared = ChargingManager()

    @Published private(set) var mode: ChargingMode = .idle {
        didSet {
            if mode != oldValue {
                log.info("Mode: \(oldValue.rawValue) → \(self.mode.rawValue)")
            }
        }
    }
    @Published private(set) var chargingAPI: SMCChargingAPI = .unknown
    @Published var isHelperInstalled = false

    private let smc = SMCService.shared
    private let battery = BatteryService.shared
    private let settings = AppSettings.shared
    private let helper = HelperClient.shared
    private var cancellables = Set<AnyCancellable>()
    private var heatProtectionTimer: Date?
    private var topUpPreviousLimit: Int?

    // MARK: - Lifecycle

    func start() {
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
            helper.connect()
            // Query the helper's detected API
            helper.getChargingAPI { [weak self] api in
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

    private func evaluateState(_ state: BatteryState) {
        // Not plugged in = on battery, nothing to control
        guard state.isPluggedIn else {
            if mode == .topUp {
                // Unplugging during Top Up ends it
                endTopUp()
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
                    inhibitCharging()
                    mode = .heatProtection
                }
                return
            } else if mode == .heatProtection {
                if let timer = heatProtectionTimer {
                    // Hysteresis: wait 5 minutes after temp last exceeded threshold
                    if Date().timeIntervalSince(timer) >= 300 {
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

        let limit = settings.chargeLimit

        // Sailing mode logic
        if settings.sailingModeEnabled {
            let lowerBound = settings.sailingLowerBound

            if state.percentage >= limit {
                // At or above limit - pause charging
                if mode != .paused {
                    inhibitCharging()
                    mode = .paused
                }
            } else if state.percentage >= lowerBound && (mode == .paused || mode == .sailing || mode == .heatProtection) {
                // In sailing range - don't charge (includes transition from heat protection)
                if mode != .sailing {
                    inhibitCharging()
                    mode = .sailing
                }
            } else if state.percentage < lowerBound {
                // Below sailing range - start charging
                if mode != .charging {
                    enableCharging()
                    mode = .charging
                }
            }
        } else {
            // No sailing mode - simple limit
            if state.percentage >= limit {
                if mode != .paused {
                    inhibitCharging()
                    mode = .paused
                }
            } else {
                if mode != .charging {
                    enableCharging()
                    mode = .charging
                }
            }
        }

        // Automatic discharge: if battery > limit and auto-discharge is on
        if settings.automaticDischarge && state.percentage > limit && mode == .paused {
            startDischarge()
        }
    }

    // MARK: - Actions

    /// Start Top Up - temporarily charge to 100%
    func startTopUp() {
        topUpPreviousLimit = settings.chargeLimit
        enableCharging()
        mode = .topUp
    }

    /// End Top Up - restore previous limit and re-evaluate state
    private func endTopUp() {
        topUpPreviousLimit = nil
        mode = .idle
        evaluateState(battery.batteryState)
    }

    /// Manually start discharge
    func startDischarge() {
        forceDischarge(true)
        mode = .discharging
    }

    /// Stop discharge
    func stopDischarge() {
        forceDischarge(false)
        mode = .idle
    }

    /// Manually pause charging at current level
    func pauseCharging() {
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
        guard chargingAPI != .unknown else { return }

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
        guard chargingAPI != .unknown else { return }

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
        helper.resetToDefaultsSync()
        mode = .idle
    }
}
