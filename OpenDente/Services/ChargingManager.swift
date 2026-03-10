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
    @Published private(set) var isHelperInstalled = false

    private let smc = SMCService.shared
    private let battery = BatteryService.shared
    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()
    private var heatProtectionTimer: Date?
    private var topUpPreviousLimit: Int?

    // MARK: - Lifecycle

    func start() {
        detectChargingAPI()

        // React to battery state changes
        battery.$batteryState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.evaluateState(state)
            }
            .store(in: &cancellables)
    }

    // MARK: - API Detection

    /// Detect which SMC keys this Mac supports for charging control
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
                // Hysteresis: wait 5 minutes after temp last exceeded threshold
                if let timer = heatProtectionTimer,
                   Date().timeIntervalSince(timer) >= 300 {
                    heatProtectionTimer = nil
                    // Fall through to normal evaluation
                } else {
                    return // Still in hysteresis period
                }
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
            } else if state.percentage >= lowerBound && (mode == .paused || mode == .sailing) {
                // In sailing range - don't charge
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

    // MARK: - SMC Charging Control

    /// Disable charging (battery stops receiving charge, Mac runs from adapter)
    private func inhibitCharging() {
        guard chargingAPI != .unknown else {
            log.warning("Cannot inhibit charging: no API detected")
            return
        }

        do {
            switch chargingAPI {
            case .legacy:
                try smc.writeKey("CH0B", bytes: [0x02])
                try smc.writeKey("CH0C", bytes: [0x02])
            case .tahoe:
                try smc.writeKey("CHTE", bytes: [0x01, 0x00, 0x00, 0x00])
            case .unknown:
                break
            }
            log.info("Charging inhibited")
        } catch {
            log.error("Failed to inhibit charging: \(error.localizedDescription). Root privileges required.")
        }
    }

    /// Enable charging (allow battery to charge)
    private func enableCharging() {
        guard chargingAPI != .unknown else { return }

        do {
            switch chargingAPI {
            case .legacy:
                try smc.writeKey("CH0B", bytes: [0x00])
                try smc.writeKey("CH0C", bytes: [0x00])
            case .tahoe:
                try smc.writeKey("CHTE", bytes: [0x00, 0x00, 0x00, 0x00])
            case .unknown:
                break
            }
            log.info("Charging enabled")
        } catch {
            log.error("Failed to enable charging: \(error.localizedDescription)")
        }
    }

    /// Force discharge (Mac runs from battery while plugged in)
    private func forceDischarge(_ enable: Bool) {
        guard chargingAPI != .unknown else { return }

        do {
            switch chargingAPI {
            case .legacy:
                try smc.writeKey("CH0I", bytes: [enable ? 0x01 : 0x00])
            case .tahoe:
                try smc.writeKey("CHIE", bytes: [enable ? 0x08 : 0x00])
            case .unknown:
                break
            }
            if enable {
                inhibitCharging()
            }
            log.info("Force discharge: \(enable)")
        } catch {
            log.error("Failed to set discharge: \(error.localizedDescription)")
        }
    }

    // MARK: - Cleanup

    /// Reset all SMC charging keys to defaults (enable charging, stop discharge)
    func resetToDefaults() {
        enableCharging()
        forceDischarge(false)
        mode = .idle
    }
}
