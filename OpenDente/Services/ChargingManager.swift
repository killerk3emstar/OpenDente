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
                inhibitRetryCount = 0
                updateMagSafeLED()
            }
        }
    }
    @Published internal(set) var chargingAPI: SMCChargingAPI = .unknown
    @Published var isHelperInstalled = false
    @Published private(set) var isPreventingSleep = false

    private let smc = SMCService.shared
    private let battery: BatteryService
    let settings: AppSettings
    private let helper: ChargingControl
    private let sleepAssertion: SleepAssertionControl
    private var cancellables = Set<AnyCancellable>()
    var heatProtectionTimer: Date?

    /// Mode captured at sleep entry — used to know what was happening before sleep.
    /// Internal for testability.
    private(set) var modeBeforeSleep: ChargingMode?

    /// Tracked helper version — used to gate protocol features (e.g. MagSafe LED).
    /// Internal for testability.
    var helperVersion: String?

    /// Last LED color sent to avoid duplicate XPC calls.
    /// Internal setter for testability (simulating helper reconnect).
    internal(set) var lastLEDColor: UInt8?

    /// Timestamp of last inhibit send — used to debounce verification re-sends.
    /// Internal for testability.
    var lastInhibitTime: Date?

    /// Number of verification re-sends in the current inhibit cycle.
    /// Reset when IOKit confirms not charging or mode changes.
    var inhibitRetryCount: Int = 0

    /// Last known IOKit isCharging state — used by LED to reflect hardware truth
    /// regardless of which evaluateState code path ran.
    private(set) var lastIsCharging: Bool = false

    private convenience init() {
        self.init(settings: .shared, helper: HelperClient.shared, battery: .shared,
                  sleepAssertion: SleepAssertionManager())
    }

    /// Initializer with dependency injection for testability
    init(settings: AppSettings, helper: ChargingControl, battery: BatteryService,
         sleepAssertion: SleepAssertionControl? = nil) {
        self.settings = settings
        self.helper = helper
        self.battery = battery
        self.sleepAssertion = sleepAssertion ?? SleepAssertionManager()
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

        // React to settings changes (e.g. charge limit, sailing range) so the state
        // machine re-evaluates immediately instead of waiting for the next battery poll.
        // .receive(on:) defers to the next RunLoop iteration, after the new value is set.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.evaluateState(self.battery.batteryState)
                // Resync sleep setting with helper on any settings change.
                // Lightweight: sends a single bool over XPC, no SMC writes.
                self.syncSleepSettingsWithHelper()
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

            // Auto-resync when helper restarts (crash recovery) or reconnects
            client.onHelperRestarted = { [weak self] in
                log.info("Helper restarted/reconnected — resyncing state")
                self?.syncWithHelper()
            }

            syncWithHelper()
        }
    }

    /// Query helper version/API and resync charging state.
    /// Called on initial connection and after helper restarts.
    private func syncWithHelper() {
        let client = HelperClient.shared
        client.getChargingAPI { [weak self] api in
            Task { @MainActor in
                switch api {
                case "legacy": self?.chargingAPI = .legacy
                case "tahoe":  self?.chargingAPI = .tahoe
                default:       break
                }
            }
        }
        client.getVersion { [weak self] version in
            Task { @MainActor in
                self?.helperVersion = version
                log.info("Helper version: \(version)")
                // Reset LED cache — helper may have restarted with default LED state
                self?.lastLEDColor = nil
                self?.updateMagSafeLED()
                // Sync sleep settings with helper (defense-in-depth)
                self?.syncSleepSettingsWithHelper()
                // Resync charging state with the (re)connected helper
                self?.resyncChargingState()
            }
        }
    }

    /// Sync the stopChargingWhenSleeping setting to the helper (version-gated).
    /// Also computes the LED color the helper should use when inhibiting on sleep.
    private func syncSleepSettingsWithHelper() {
        guard let version = helperVersion,
              version.isVersionAtLeast(HelperConstants.minVersionSleepSync) else {
            return
        }
        // 0xFF = sentinel for "don't touch LED" (when controlMagSafeLED is off)
        let ledColor: UInt8 = settings.controlMagSafeLED
            ? (settings.magSafeLEDOffWhenInactive ? HelperConstants.ledOff : HelperConstants.ledGreen)
            : 0xFF
        HelperClient.shared.syncSleepSettings(
            stopChargingWhenSleeping: settings.stopChargingWhenSleeping,
            sleepLEDColor: ledColor
        )
    }

    // MARK: - API Detection

    /// Detect which SMC keys this Mac supports for charging control (read-only, no root needed)
    private func detectChargingAPI() {
        // Try Tahoe keys first (newer)
        if smc.keyExists("CHTE") {
            chargingAPI = .tahoe
            log.info("Detected Tahoe charging API (CHTE/CHIE)")
        } else if smc.keyExists("CH0B") {
            chargingAPI = .legacy
            log.info("Detected legacy charging API (CH0B/CH0C)")
        } else {
            chargingAPI = .unknown
            log.info("No charging control keys detected")
        }

        logDiagnosticDump()
    }

    /// One-time diagnostic dump at startup for Tahoe investigation.
    private func logDiagnosticDump() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osStr = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        var model = "unknown"
        var size: Int = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 {
                model = String(cString: buf)
            }
        }

        let diagnosticKeys = ["CHTE", "CHIE", "CH0B", "CH0C", "CH0I", "CH0J", "ACLC"]
        var keyLines: [String] = []
        for key in diagnosticKeys {
            if let info = smc.keyInfo(key) {
                keyLines.append("  \(key): exists=true  type=\(info.type)  size=\(info.size)")
            } else {
                keyLines.append("  \(key): exists=false")
            }
        }

        let state = battery.batteryState
        let pct = state.percentage
        let apiName: String
        switch chargingAPI {
        case .tahoe: apiName = "tahoe"
        case .legacy: apiName = "legacy"
        case .unknown: apiName = "unknown"
        }

        log.info("""
        === OpenDente Diagnostic Dump ===
        macOS: \(osStr, privacy: .public)
        Model: \(model, privacy: .public)
        Charging API: \(apiName, privacy: .public)
        \(keyLines.joined(separator: "\n"), privacy: .public)
        Battery: \(pct)%, charging=\(state.isCharging), pluggedIn=\(state.isPluggedIn)
        =================================
        """)
    }

    // MARK: - State Machine

    /// Evaluate battery state and decide charging mode. Internal for testability.
    func evaluateState(_ state: BatteryState) {
        let pct = state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)

        // Skip evaluation if data looks uninitialized (startup race / IOKit not ready).
        // A Mac genuinely at 0% on battery would have timeToEmpty populated.
        guard pct > 0 || state.isCharging || state.isPluggedIn
              || state.timeToEmpty != nil || state.timeToFull != nil else {
            return  // Stay in current mode until real data arrives
        }

        lastIsCharging = state.isCharging
        defer { updateMagSafeLED() }
        defer { updateSleepAssertion(state) }

        // Not plugged in = on battery, nothing to control.
        // Exception: during force discharge, IOKit reports power source as "battery"
        // even though the charger is physically connected. Don't kill our own discharge.
        guard state.isPluggedIn || mode == .discharging else {
            if mode == .topUp {
                log.info("Top Up ended: unplugged at \(state.percentage)%")
            }
            // Clean slate — no pending inhibit verification on battery
            lastInhibitTime = nil
            inhibitRetryCount = 0
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

        // Top Up mode — stay until unplugged (guard above) or user cancels
        if mode == .topUp {
            return
        }

        // Calibration mode - handled separately
        if mode == .calibrating {
            return
        }

        // Discharge mode - don't override until unplugged (or auto-discharge reaches limit)
        if mode == .discharging {
            // Real unplug detection: during force discharge, IOKit reports isPluggedIn=false.
            // A real unplug is when isPluggedIn=false AND adapter power is gone.
            if !state.isPluggedIn && (state.adapterPower ?? 0) < 0.1 {
                log.info("Discharge ended: charger unplugged at \(pct)%")
                forceDischarge(false)
                mode = .onBattery
                return
            }
            if pct <= settings.chargeLimit {
                log.info("Discharge reached limit: \(pct)% ≤ \(self.settings.chargeLimit)%")
                stopDischarge()
                // Fall through to normal evaluation
            } else {
                return
            }
        }

        let limit = settings.chargeLimit

        // Sailing mode = hysteresis to prevent micro-cycling (80→79→charge→80→…).
        // Two asymmetric thresholds:
        //   Stop charging at:  limit (e.g. 80%)
        //   Start charging at: lowerBound (e.g. 70%) — only if sailing enabled
        // Sailing is entered from .paused/.heatProtection (dropping from above)
        // or from .onBattery/.idle (plug-in/app start within range).
        // NEVER from .charging — that would cut off a charge cycle before reaching the limit.
        if settings.sailingModeEnabled {
            let lowerBound = settings.sailingLowerBound

            if pct >= limit {
                if mode != .paused {
                    log.info("Limit reached: \(pct)% ≥ \(limit)% → paused")
                    if mode != .sailing && mode != .heatProtection {
                        inhibitCharging()
                    }
                    mode = .paused
                }
            } else if pct >= lowerBound {
                if mode == .charging {
                    // Keep charging toward limit — don't interrupt
                } else if mode != .sailing {
                    log.info("Sailing: \(pct)% in range \(lowerBound)–\(limit)%")
                    if mode != .paused && mode != .heatProtection {
                        inhibitCharging()
                    }
                    mode = .sailing
                }
            } else {
                if mode != .charging {
                    log.info("Below range: \(pct)% < \(lowerBound)% → charging to \(limit)%")
                    enableCharging()
                    mode = .charging
                }
            }
        } else {
            // No sailing mode — simple limit
            if pct >= limit {
                if mode != .paused {
                    log.info("Limit reached: \(pct)% ≥ \(limit)% → paused")
                    if mode != .heatProtection {
                        inhibitCharging()
                    }
                    mode = .paused
                }
            } else {
                if mode != .charging {
                    log.info("Below limit: \(pct)% < \(limit)% → charging")
                    enableCharging()
                    mode = .charging
                }
            }
        }

        // Automatic discharge: if battery > limit and auto-discharge is on
        if settings.automaticDischarge && pct > limit && mode == .paused {
            log.info("Auto-discharge: \(pct)% > \(limit)%")
            startDischarge()
        }

        // Verification: system is the source of truth.
        // If we think charging is inhibited but IOKit still reports isCharging,
        // the SMC write may not have taken effect — re-send.
        // IOKit can lag 15-30s on Apple Silicon before reflecting the new state,
        // so debounce at 15s and limit to 3 retries to avoid unnecessary SMC writes.
        let inhibitElapsed = lastInhibitTime.map { Date().timeIntervalSince($0) } ?? .infinity
        if (mode == .paused || mode == .sailing || mode == .heatProtection)
            && state.isCharging {
            if inhibitElapsed >= 15 && inhibitRetryCount < 3 {
                inhibitRetryCount += 1
                log.warning("IOKit still reports charging in \(self.mode.displayName) mode — re-sending inhibit (\(self.inhibitRetryCount)/3, \(String(format: "%.0f", inhibitElapsed), privacy: .public)s since first inhibit) | IOKit: isCharging=\(state.isCharging), pct=\(pct)%, adapterPower=\(String(format: "%.1f", state.adapterPower ?? -1), privacy: .public)W")
                inhibitCharging()
            } else if inhibitRetryCount >= 3 {
                log.error("Inhibit retry exhausted (3/3, \(String(format: "%.0f", inhibitElapsed), privacy: .public)s) — SMC writes may be overridden by system | IOKit: isCharging=\(state.isCharging), pct=\(pct)%")
            }
        } else if (mode == .paused || mode == .sailing || mode == .heatProtection)
                    && !state.isCharging && lastInhibitTime != nil
                    && inhibitElapsed >= 2 {
            // Require ≥2s since inhibit write to avoid confirming in the same evaluateState
            // call that sent the inhibit (e.g. cable plug with stale SMC inhibit).
            if inhibitRetryCount > 0 {
                log.info("IOKit confirmed: charging stopped in \(self.mode.displayName) mode (after \(self.inhibitRetryCount) retries, \(String(format: "%.0f", inhibitElapsed), privacy: .public)s)")
            } else {
                log.info("IOKit confirmed: charging stopped in \(self.mode.displayName) mode")
            }
            inhibitRetryCount = 0
            lastInhibitTime = nil
        }
    }

    // MARK: - Sleep/Wake

    /// Called by AppDelegate when macOS is about to sleep.
    /// If stopChargingWhenSleeping is on: inhibits charging so the battery doesn't
    /// charge to 100% during sleep. Also stops discharge (pointless during sleep).
    func handleWillSleep() {
        modeBeforeSleep = mode
        log.info("Will sleep: mode=\(self.mode.displayName), stopCharging=\(self.settings.stopChargingWhenSleeping), disableSleep=\(self.settings.disableSleepUntilChargeLimit)")

        // Always stop discharge before sleep — no system load means meaningless drain
        if mode == .discharging {
            forceDischarge(false)
            log.info("Will sleep: stopped discharge")
        }

        guard settings.stopChargingWhenSleeping else {
            log.info("Will sleep: stopChargingWhenSleeping OFF — no inhibit")
            return
        }
        // If mode is .onBattery or .idle, there's nothing to inhibit
        guard mode != .onBattery && mode != .idle else {
            log.info("Will sleep: mode is \(self.mode.displayName) — nothing to inhibit")
            return
        }

        // Pre-emptively inhibit charging before sleep.
        // Even if already inhibited (paused/sailing), re-send as defense in depth —
        // macOS may have cleared the SMC state.
        inhibitCharging()

        // Update LED to reflect that charging is now inhibited.
        // Without this, LED stays orange (frozen) during sleep even though
        // charging was stopped. MagSafe LED is visible with the lid closed.
        if settings.controlMagSafeLED {
            let color = settings.magSafeLEDOffWhenInactive
                ? HelperConstants.ledOff
                : HelperConstants.ledGreen
            sendLEDColor(color)
        }

        log.info("Will sleep: inhibited charging (stopChargingWhenSleeping)")
    }

    /// Called by AppDelegate after macOS wakes from sleep.
    /// Clears stale state and re-evaluates — the state machine handles all transitions.
    func handleDidWake(_ currentState: BatteryState) {
        let previousMode = modeBeforeSleep
        let pct = currentState.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)
        log.info("Did wake: modeBeforeSleep=\(previousMode?.displayName ?? "nil"), battery=\(pct)%, pluggedIn=\(currentState.isPluggedIn), isCharging=\(currentState.isCharging)")

        modeBeforeSleep = nil
        // Clear stale verification state from before sleep
        lastInhibitTime = nil
        inhibitRetryCount = 0

        // If we were discharging, handleWillSleep stopped forceDischarge but left mode
        // as .discharging. Reset to .onBattery so evaluateState doesn't get stuck in the
        // discharge early-return path. Using .onBattery (not .idle) avoids a spurious
        // "discharge complete" notification from the .discharging → .idle transition.
        if mode == .discharging {
            mode = .onBattery
        }

        let modeBeforeEval = mode
        evaluateState(currentState)

        // evaluateState skips SMC writes when mode hasn't changed (optimization).
        // After sleep, SMC state may be stale (we inhibited during sleep, or macOS
        // reset charging state). Re-send the correct command if mode was unchanged.
        if mode == modeBeforeEval {
            resyncSMCAfterWake()
        }

        log.info("Did wake: evaluated → mode=\(self.mode.displayName)")
    }

    /// Re-send the SMC command for the current mode after wake.
    /// Called when evaluateState kept the same mode and thus skipped the SMC write.
    private func resyncSMCAfterWake() {
        switch mode {
        case .charging, .topUp:
            enableCharging()
            log.info("Wake resync: re-enabled charging")
        case .paused, .sailing, .heatProtection:
            inhibitCharging()
            log.info("Wake resync: re-inhibited charging")
        case .discharging:
            forceDischarge(true)
            log.info("Wake resync: re-enabled discharge")
        case .onBattery, .idle, .calibrating:
            break
        }
    }

    // MARK: - Sleep Assertion

    /// Update IOPMAssertion to prevent/allow system idle sleep.
    /// Called at the end of every evaluateState.
    private func updateSleepAssertion(_ state: BatteryState) {
        guard settings.disableSleepUntilChargeLimit else {
            if isPreventingSleep {
                log.info("Sleep assertion: released (setting disabled)")
                sleepAssertion.allowSleep()
                isPreventingSleep = false
            }
            return
        }

        let pct = state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)
        // Keep awake while actively working toward the charge limit
        let shouldPrevent = state.isPluggedIn
            && pct != settings.chargeLimit
            && (mode == .charging || mode == .discharging)

        if shouldPrevent && !isPreventingSleep {
            log.info("Sleep assertion: preventing sleep (mode=\(self.mode.displayName), \(pct)% → \(self.settings.chargeLimit)%)")
            isPreventingSleep = sleepAssertion.preventSleep(
                reason: "OpenDente: Charging to \(settings.chargeLimit)%"
            )
        } else if !shouldPrevent && isPreventingSleep {
            log.info("Sleep assertion: released (mode=\(self.mode.displayName), pct=\(pct)%, limit=\(self.settings.chargeLimit)%, pluggedIn=\(state.isPluggedIn))")
            sleepAssertion.allowSleep()
            isPreventingSleep = false
        }
    }

    // MARK: - Actions

    /// Whether SMC commands can be sent (helper installed and API detected)
    private var canControlCharging: Bool {
        isHelperInstalled && chargingAPI != .unknown
    }

    /// Start Top Up - temporarily charge to 100%
    func startTopUp() {
        guard canControlCharging else {
            log.warning("Cannot start Top Up: \(self.controlUnavailableReason)")
            return
        }
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
        guard canControlCharging else {
            log.warning("Cannot start discharge: \(self.controlUnavailableReason)")
            return
        }
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
        guard canControlCharging else {
            log.warning("Cannot pause charging: \(self.controlUnavailableReason)")
            return
        }
        log.info("Charging paused manually at \(self.battery.batteryState.percentage)%")
        inhibitCharging()
        mode = .paused
    }

    private var controlUnavailableReason: String {
        if !isHelperInstalled { return "helper not installed" }
        if chargingAPI == .unknown { return "no charging API detected" }
        return "unknown"
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
                log.info("SMC: inhibit written — waiting for IOKit confirmation")
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

        // End any pending inhibit verification cycle
        lastInhibitTime = nil
        inhibitRetryCount = 0

        helper.enableCharging { [weak self] success, error in
            if success {
                log.info("SMC: enable written")
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

    /// Re-send current mode's SMC commands after helper reconnects.
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

    /// Update MagSafe LED to reflect current mode + IOKit truth.
    /// Uses `lastIsCharging` (updated every evaluateState) so LED reflects
    /// hardware reality, not just mode intent.
    /// Gated behind helper version check — calling setMagSafeLED on an old helper
    /// that doesn't implement it would disrupt the XPC connection.
    private func updateMagSafeLED() {
        guard settings.controlMagSafeLED else {
            // If disabled, reset to auto (only if we previously set something)
            if lastLEDColor != nil && lastLEDColor != HelperConstants.ledAuto {
                sendLEDColor(HelperConstants.ledAuto)
            }
            return
        }
        guard let version = helperVersion,
              version.isVersionAtLeast(HelperConstants.minVersionMagSafeLED) else {
            return
        }

        // LED reflects both mode intent AND IOKit truth:
        // - charging/topUp/discharging → always orange (we're actively controlling)
        // - inhibited modes → orange while IOKit still reports charging (transition),
        //   then green/off once IOKit confirms charging actually stopped.
        let isCharging = lastIsCharging
        let color: UInt8
        if mode == .onBattery || mode == .idle {
            color = HelperConstants.ledAuto
        } else if mode == .discharging || mode == .charging || mode == .topUp {
            color = HelperConstants.ledOrange
        } else if isCharging {
            color = HelperConstants.ledOrange  // IOKit still reports charging (transition)
        } else {
            // IOKit confirms not charging
            switch mode {
            case .paused, .sailing, .heatProtection, .calibrating:
                color = settings.magSafeLEDOffWhenInactive ? HelperConstants.ledOff : HelperConstants.ledGreen
            default:
                color = HelperConstants.ledAuto
            }
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
                log.warning("Helper reset failed — charging may remain inhibited until helper recovers")
            }
        }
        // Reset LED to system default (only if helper supports it)
        if let version = helperVersion,
           version.isVersionAtLeast(HelperConstants.minVersionMagSafeLED) {
            helper.setMagSafeLED(color: HelperConstants.ledAuto, completion: nil)
        }
        lastLEDColor = nil
        sleepAssertion.allowSleep()
        isPreventingSleep = false
        mode = .idle
    }

    /// Synchronous reset for app termination
    func resetToDefaultsSync() {
        log.info("App terminating — resetting SMC to defaults")
        helper.resetToDefaultsSync(timeout: 2.0)
        sleepAssertion.allowSleep()
        isPreventingSleep = false
        mode = .idle
    }
}
