import XCTest
@testable import OpenDente

// MARK: - Mock Helper

/// Records all charging control calls for verification.
/// Completes with success by default. Set `shouldFail` to simulate helper failures.
final class MockChargingControl: ChargingControl, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case enableCharging
        case inhibitCharging
        case forceDischarge(enable: Bool)
        case resetToDefaults
        case setMagSafeLED(color: UInt8)
    }

    /// All calls in order — use this to verify exact sequences of SMC operations
    private(set) var calls: [Call] = []

    func clearCalls() { calls.removeAll() }

    /// If true, completion reports failure (simulates helper crash/disconnect)
    var shouldFail = false

    func enableCharging(completion: (@Sendable (Bool, String?) -> Void)?) {
        calls.append(.enableCharging)
        if shouldFail {
            completion?(false, "mock failure")
        } else {
            completion?(true, nil)
        }
    }

    func inhibitCharging(completion: (@Sendable (Bool, String?) -> Void)?) {
        calls.append(.inhibitCharging)
        if shouldFail {
            completion?(false, "mock failure")
        } else {
            completion?(true, nil)
        }
    }

    func forceDischarge(enable: Bool, completion: (@Sendable (Bool, String?) -> Void)?) {
        calls.append(.forceDischarge(enable: enable))
        if shouldFail {
            completion?(false, "mock failure")
        } else {
            completion?(true, nil)
        }
    }

    func resetToDefaults(completion: (@Sendable (Bool, String?) -> Void)?) {
        calls.append(.resetToDefaults)
        completion?(true, nil)
    }

    func setMagSafeLED(color: UInt8, completion: (@Sendable (Bool, String?) -> Void)?) {
        calls.append(.setMagSafeLED(color: color))
        completion?(true, nil)
    }

    nonisolated func resetToDefaultsSync(timeout: TimeInterval) {}

    func reset() { calls.removeAll() }
}

// MARK: - Test Factory

/// Create a BatteryState with sensible defaults, overriding only what's needed.
/// Plugged in by default because that's when charging control is active.
func makeBatteryState(
    percentage: Int = 50,
    hardwarePercentage: Int? = nil,
    isCharging: Bool = false,
    isPluggedIn: Bool = true,
    temperature: Double? = 25.0,
    adapterPower: Double? = nil,
    timeToEmpty: Int? = nil,
    timeToFull: Int? = nil
) -> BatteryState {
    BatteryState(
        percentage: percentage,
        hardwarePercentage: hardwarePercentage,
        isCharging: isCharging,
        isPluggedIn: isPluggedIn,
        currentCapacity: nil,
        maxCapacity: nil,
        designCapacity: nil,
        cycleCount: nil,
        temperature: temperature,
        voltage: nil,
        amperage: nil,
        systemPower: nil,
        adapterPower: adapterPower,
        batteryPower: nil,
        timeToEmpty: timeToEmpty,
        timeToFull: timeToFull
    )
}

// MARK: - Charging Manager Tests

@MainActor
final class ChargingManagerTests: XCTestCase {

    private var manager: ChargingManager!
    private var mock: MockChargingControl!
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        settings = AppSettings.shared
        mock = MockChargingControl()
        manager = ChargingManager(settings: settings, helper: mock, battery: .shared)
        manager.chargingAPI = .legacy
        manager.isHelperInstalled = true

        // Known defaults for deterministic tests
        settings.chargeLimit = 80
        settings.sailingModeEnabled = false
        settings.heatProtectionEnabled = false
        settings.automaticDischarge = false
        settings.controlMagSafeLED = false  // Prevent LED calls from polluting existing tests
        settings.useHardwareBatteryPercentage = false
    }

    override func tearDown() {
        settings.chargeLimit = 80
        settings.sailingModeEnabled = true
        settings.sailingRange = 10
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0
        settings.automaticDischarge = false
        settings.controlMagSafeLED = true
        settings.magSafeLEDOffWhenInactive = false
        settings.useHardwareBatteryPercentage = false
        manager = nil
        mock = nil
        super.tearDown()
    }

    // =========================================================================
    // MARK: - Basic Charge Limit
    // =========================================================================

    func testBelowLimit_enablesCharging() {
        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertEqual(manager.mode, .charging)
        XCTAssertEqual(mock.calls, [.enableCharging])
    }

    func testAtExactLimit_inhibitsCharging() {
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)
        XCTAssertEqual(mock.calls, [.inhibitCharging])
    }

    func testAboveLimit_inhibitsCharging() {
        manager.evaluateState(makeBatteryState(percentage: 95))
        XCTAssertEqual(manager.mode, .paused)
        XCTAssertEqual(mock.calls, [.inhibitCharging])
    }

    func testAt100Percent_inhibitsCharging() {
        manager.evaluateState(makeBatteryState(percentage: 100))
        XCTAssertEqual(manager.mode, .paused)
    }

    // =========================================================================
    // MARK: - Redundant SMC Write Prevention
    // =========================================================================
    // Each SMC write wears the hardware. Verify we only write on actual transitions.

    func testRepeatedEvaluateAtSameLevel_noRedundantWrites() {
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(mock.calls.count, 1) // One inhibit
        mock.reset()

        // 5 more evaluations at same level
        for _ in 0..<5 {
            manager.evaluateState(makeBatteryState(percentage: 80))
        }
        XCTAssertTrue(mock.calls.isEmpty, "No SMC writes when mode doesn't change")
    }

    func testChargingStaysCharging_noRedundantWrites() {
        manager.evaluateState(makeBatteryState(percentage: 50))
        mock.reset()

        manager.evaluateState(makeBatteryState(percentage: 55))
        manager.evaluateState(makeBatteryState(percentage: 60))
        manager.evaluateState(makeBatteryState(percentage: 65))
        XCTAssertTrue(mock.calls.isEmpty, "Staying in charging should not re-send enableCharging")
    }

    // =========================================================================
    // MARK: - Boundary Oscillation (percentage bouncing around limit)
    // =========================================================================
    // Apple Silicon has binary charging control. If percentage oscillates
    // around the limit, we must handle it without excessive SMC writes.

    func testOscillationAroundLimit_minimizesSMCWrites() {
        // Simulate: 79 → 80 → 79 → 80 → 79 → 80
        manager.evaluateState(makeBatteryState(percentage: 79))
        XCTAssertEqual(manager.mode, .charging)

        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)

        manager.evaluateState(makeBatteryState(percentage: 79))
        XCTAssertEqual(manager.mode, .charging)

        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)

        // Verify: each transition caused exactly one write
        XCTAssertEqual(mock.calls, [
            .enableCharging,   // 79 (idle → charging)
            .inhibitCharging,  // 80 (charging → paused)
            .enableCharging,   // 79 (paused → charging)
            .inhibitCharging,  // 80 (charging → paused)
        ])
    }

    // =========================================================================
    // MARK: - On Battery (unplugged)
    // =========================================================================

    func testUnplugged_switchesToOnBattery_noSMCWrites() {
        manager.evaluateState(makeBatteryState(percentage: 50, isPluggedIn: false))
        XCTAssertEqual(manager.mode, .onBattery)
        XCTAssertTrue(mock.calls.isEmpty, "No SMC writes when on battery")
    }

    func testPlugBackIn_belowSailingRange_charges() {
        // Unplug
        manager.evaluateState(makeBatteryState(percentage: 50, isPluggedIn: false))
        XCTAssertEqual(manager.mode, .onBattery)
        mock.reset()

        // Plug back in below limit (and below sailing range if enabled)
        manager.evaluateState(makeBatteryState(percentage: 50, isPluggedIn: true))
        XCTAssertEqual(manager.mode, .charging)
        XCTAssertEqual(mock.calls, [.enableCharging])
    }

    func testPlugBackInAboveLimit_pauses() {
        manager.evaluateState(makeBatteryState(percentage: 90, isPluggedIn: false))
        mock.reset()

        manager.evaluateState(makeBatteryState(percentage: 90, isPluggedIn: true))
        XCTAssertEqual(manager.mode, .paused)
        XCTAssertEqual(mock.calls, [.inhibitCharging])
    }

    // =========================================================================
    // MARK: - Sailing Mode: Full Lifecycle
    // =========================================================================
    // Sailing = don't recharge until battery drops below (limit - range).
    // Reduces charge cycles by allowing battery to coast down naturally.

    func testSailingFullCycle() {
        settings.sailingModeEnabled = true
        settings.sailingRange = 10  // lower bound = 70

        // Step 1: Start below limit → charge
        manager.evaluateState(makeBatteryState(percentage: 65))
        XCTAssertEqual(manager.mode, .charging)

        // Step 2: Reach limit → pause
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)

        // Step 3: Battery drops into sailing range → sail (no recharge)
        manager.evaluateState(makeBatteryState(percentage: 78))
        XCTAssertEqual(manager.mode, .sailing)

        // Step 4: Still sailing at lower end of range
        manager.evaluateState(makeBatteryState(percentage: 71))
        XCTAssertEqual(manager.mode, .sailing)

        // Step 5: Drop below sailing range → start charging
        manager.evaluateState(makeBatteryState(percentage: 69))
        XCTAssertEqual(manager.mode, .charging)

        // Step 6: Charge back up to limit → pause again
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)
    }

    func testSailing_pausedToSailing_noRedundantSMCWrite() {
        settings.sailingModeEnabled = true
        settings.sailingRange = 10

        // Reach limit → paused (inhibitCharging called)
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)
        mock.reset()

        // Drop into sailing range — charging already inhibited, no need to write again
        manager.evaluateState(makeBatteryState(percentage: 75))
        XCTAssertEqual(manager.mode, .sailing)
        XCTAssertTrue(mock.calls.isEmpty,
            "paused→sailing: charging already inhibited, no SMC write needed")
    }

    func testSailing_appStartInSailingRange_sails() {
        settings.sailingModeEnabled = true
        settings.sailingRange = 10  // lower bound = 70

        // Battery at 75% is within sailing range (70-80%)
        // Should sail, not charge — the whole point of sailing is to avoid unnecessary cycles
        manager.evaluateState(makeBatteryState(percentage: 75))
        XCTAssertEqual(manager.mode, .sailing,
            "Battery in sailing range should sail, not charge — avoid unnecessary cycle")
        XCTAssertEqual(mock.calls, [.inhibitCharging])
    }

    func testSailing_appStartBelowSailingRange_charges() {
        settings.sailingModeEnabled = true
        settings.sailingRange = 10  // lower bound = 70

        // Battery at 65% is below sailing range — must charge up
        manager.evaluateState(makeBatteryState(percentage: 65))
        XCTAssertEqual(manager.mode, .charging)
        XCTAssertEqual(mock.calls, [.enableCharging])
    }

    func testSailing_atExactLowerBound_fromPaused_sails() {
        settings.sailingModeEnabled = true
        settings.sailingRange = 10  // lower bound = 70

        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)

        // At exact lower bound — should still sail, not charge
        manager.evaluateState(makeBatteryState(percentage: 70))
        XCTAssertEqual(manager.mode, .sailing,
            "At exact lower bound should still be sailing")
    }

    func testSailing_oneBelowLowerBound_charges() {
        settings.sailingModeEnabled = true
        settings.sailingRange = 10

        manager.evaluateState(makeBatteryState(percentage: 80))
        manager.evaluateState(makeBatteryState(percentage: 70))
        XCTAssertEqual(manager.mode, .sailing)

        manager.evaluateState(makeBatteryState(percentage: 69))
        XCTAssertEqual(manager.mode, .charging,
            "One below lower bound should trigger charging")
    }

    // =========================================================================
    // MARK: - Discharge Mode (Bug #1 regression)
    // =========================================================================
    // User-initiated discharge must be respected by the state machine.
    // Before the fix, evaluateState would immediately override discharge mode.

    func testDischarge_notOverriddenWhileAboveLimit() {
        manager.startDischarge()
        XCTAssertEqual(manager.mode, .discharging)
        mock.reset()

        // Still above limit — discharge must continue
        manager.evaluateState(makeBatteryState(percentage: 85))
        XCTAssertEqual(manager.mode, .discharging,
            "REGRESSION: Discharge must not be overridden while above limit")
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testDischarge_stopsAtLimit() {
        manager.startDischarge()
        XCTAssertEqual(manager.mode, .discharging)
        mock.reset()

        // At limit — discharge must stop
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertNotEqual(manager.mode, .discharging,
            "Discharge must stop when reaching the charge limit")
        XCTAssertTrue(mock.calls.contains(.forceDischarge(enable: false)))
    }

    func testDischarge_stopsBelowLimit() {
        manager.startDischarge()
        XCTAssertEqual(manager.mode, .discharging)
        mock.reset()

        // Below limit — discharge must stop
        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertNotEqual(manager.mode, .discharging,
            "Discharge must stop when below the charge limit")
    }

    func testDischarge_notOverriddenEvenAboveLimit() {
        manager.startDischarge()
        mock.reset()

        manager.evaluateState(makeBatteryState(percentage: 95))
        XCTAssertEqual(manager.mode, .discharging)
    }

    func testDischarge_endsOnRealUnplug() {
        manager.startDischarge()
        mock.reset()

        // Real unplug: isPluggedIn=false AND adapterPower=0
        manager.evaluateState(makeBatteryState(percentage: 70, isPluggedIn: false, adapterPower: 0))
        XCTAssertEqual(manager.mode, .onBattery)
        XCTAssertEqual(mock.calls, [.forceDischarge(enable: false)],
            "Real unplug during discharge must clear discharge key (CH0I)")
    }

    func testDischarge_survivesIOKitFlicker() {
        // During force discharge, IOKit reports isPluggedIn=false but adapter is still connected
        manager.startDischarge()
        mock.reset()

        manager.evaluateState(makeBatteryState(percentage: 85, isPluggedIn: false, adapterPower: 30.0))
        XCTAssertEqual(manager.mode, .discharging,
            "Discharge must survive IOKit isPluggedIn flicker when adapter power is present")
        XCTAssertTrue(mock.calls.isEmpty, "No SMC writes during IOKit flicker")
    }

    func testDischarge_unplugAndReplug_noStaleDischargeKey() {
        manager.startDischarge()
        mock.reset()

        // Real unplug — should clear discharge key
        manager.evaluateState(makeBatteryState(percentage: 50, isPluggedIn: false, adapterPower: 0))
        XCTAssertEqual(manager.mode, .onBattery)
        mock.reset()

        // Plug back in — should charge normally, not discharge
        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertEqual(manager.mode, .charging)
        XCTAssertEqual(mock.calls, [.enableCharging],
            "After replug, should charge — no stale discharge state")
    }

    func testDischarge_stopDischarge_returnsToIdle() {
        manager.startDischarge()
        mock.reset()
        manager.stopDischarge()

        XCTAssertEqual(manager.mode, .idle)
        XCTAssertEqual(mock.calls, [.forceDischarge(enable: false)])
    }

    func testDischarge_startSendsCorrectSMCCalls() {
        manager.startDischarge()
        XCTAssertEqual(mock.calls, [.forceDischarge(enable: true)])
    }

    // =========================================================================
    // MARK: - Heat Protection
    // =========================================================================

    func testHeat_highTemp_inhibitsCharging() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0

        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 36.0))
        XCTAssertEqual(manager.mode, .heatProtection)
        XCTAssertEqual(mock.calls, [.inhibitCharging])
    }

    func testHeat_exactThreshold_inhibits() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0

        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 35.0))
        XCTAssertEqual(manager.mode, .heatProtection,
            "At exact threshold should trigger heat protection (>= check)")
    }

    func testHeat_normalTemp_noEffect() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0

        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 34.9))
        XCTAssertEqual(manager.mode, .charging)
    }

    func testHeat_disabled_noEffect() {
        settings.heatProtectionEnabled = false
        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 40.0))
        XCTAssertEqual(manager.mode, .charging)
    }

    func testHeat_noTemperatureData_noEffect() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0

        manager.evaluateState(makeBatteryState(percentage: 50, temperature: nil))
        XCTAssertEqual(manager.mode, .charging,
            "No temperature data = can't trigger heat protection")
    }

    func testHeat_hysteresisKeepsInhibited() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0

        // Trigger heat protection
        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 36.0))
        XCTAssertEqual(manager.mode, .heatProtection)

        // Temp drops below threshold — should stay inhibited (5 min hysteresis)
        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 33.0))
        XCTAssertEqual(manager.mode, .heatProtection,
            "Must stay in heat protection during 5-minute hysteresis")
    }

    func testHeat_hysteresisExpires_resumesNormalEvaluation() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0

        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 36.0))
        XCTAssertEqual(manager.mode, .heatProtection)

        // Simulate 5+ minutes passing
        manager.heatProtectionTimer = Date().addingTimeInterval(-301)

        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 33.0))
        XCTAssertEqual(manager.mode, .charging,
            "After 5 min cooldown, should resume normal charging")
    }

    func testHeat_reSpikeResetsHysteresisTimer() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0

        // Initial spike
        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 36.0))

        // 4 minutes pass, temp drops
        manager.heatProtectionTimer = Date().addingTimeInterval(-240)
        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 34.0))
        XCTAssertEqual(manager.mode, .heatProtection, "Still in hysteresis (4 min < 5 min)")

        // Temp spikes again — timer resets
        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 36.0))

        // 3 more minutes pass (7 total, but only 3 since last spike)
        manager.heatProtectionTimer = Date().addingTimeInterval(-180)
        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 34.0))
        XCTAssertEqual(manager.mode, .heatProtection,
            "Re-spike must reset timer — 3 min since last spike, not expired")
    }

    // =========================================================================
    // MARK: - Mode Priority Order
    // =========================================================================
    // Heat protection > Top Up > Calibrating > Discharging > normal limit logic

    func testPriority_heatProtectionOverridesCharging() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0

        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 36.0))
        XCTAssertEqual(manager.mode, .heatProtection)
    }

    func testPriority_heatProtectionOverridesDischarge_stopsDischargeKey() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0

        // Start discharge
        manager.startDischarge()
        XCTAssertEqual(manager.mode, .discharging)
        mock.reset()

        // Heat spike — should stop discharge AND inhibit charging
        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 36.0))
        XCTAssertEqual(manager.mode, .heatProtection)
        XCTAssertTrue(mock.calls.contains(.forceDischarge(enable: false)),
            "Heat protection must clear discharge key — battery should be idle, not draining")
        XCTAssertTrue(mock.calls.contains(.inhibitCharging),
            "Heat protection must also inhibit charging")
    }

    func testPriority_topUpNotOverriddenByLimit() {
        manager.startTopUp()
        manager.evaluateState(makeBatteryState(percentage: 95))
        XCTAssertEqual(manager.mode, .topUp, "Top Up should persist above charge limit")
    }

    func testPriority_calibrationNotOverridden() {
        manager.mode = .calibrating
        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertEqual(manager.mode, .calibrating)
    }

    func testPriority_heatProtectionEvenDuringTopUp() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0

        manager.startTopUp()
        XCTAssertEqual(manager.mode, .topUp)

        // Heat spike during top up — heat protection should take priority
        manager.evaluateState(makeBatteryState(percentage: 90, temperature: 36.0))
        XCTAssertEqual(manager.mode, .heatProtection,
            "Heat protection must override even Top Up mode")
    }

    // =========================================================================
    // MARK: - Top Up
    // =========================================================================

    func testTopUp_staysUntilUnplugged() {
        manager.startTopUp()
        XCTAssertEqual(mock.calls, [.enableCharging])

        manager.evaluateState(makeBatteryState(percentage: 90))
        manager.evaluateState(makeBatteryState(percentage: 100))
        XCTAssertEqual(manager.mode, .topUp)

        // Only ends on unplug
        manager.evaluateState(makeBatteryState(percentage: 100, isPluggedIn: false))
        XCTAssertNotEqual(manager.mode, .topUp)
    }

    func testCancelTopUp_inhibitsAndGoesIdle() {
        manager.startTopUp()
        XCTAssertEqual(manager.mode, .topUp)
        mock.reset()

        // Cancel → inhibit charging as safe default, mode = idle
        // Next poll will re-evaluate to the correct mode
        manager.cancelTopUp()
        XCTAssertEqual(manager.mode, .idle)
        XCTAssertEqual(mock.calls, [.inhibitCharging],
            "Cancel Top Up must inhibit charging as a safe default")
    }

    func testCancelTopUp_nextPollReEvaluatesCorrectly() {
        manager.startTopUp()
        mock.reset()

        manager.cancelTopUp()
        XCTAssertEqual(manager.mode, .idle)
        mock.reset()

        // Next poll: above limit → paused
        manager.evaluateState(makeBatteryState(percentage: 90))
        XCTAssertEqual(manager.mode, .paused,
            "After cancel, next poll above limit should pause")
    }

    func testCancelTopUp_nextPoll_belowLimit_charges() {
        settings.chargeLimit = 90
        manager.startTopUp()
        mock.reset()

        manager.cancelTopUp()
        mock.reset()

        // Next poll: below limit → charge
        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertEqual(manager.mode, .charging,
            "After cancel, next poll below limit should charge")
    }

    func testCancelTopUp_whenNotInTopUp_doesNothing() {
        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertEqual(manager.mode, .charging)
        mock.reset()

        manager.cancelTopUp()
        XCTAssertEqual(manager.mode, .charging,
            "Cancel when not in Top Up should have no effect")
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testCancelTopUp_nextPoll_inSailingRange_sails() {
        settings.sailingModeEnabled = true
        settings.sailingRange = 10  // lower bound = 70

        manager.startTopUp()
        mock.reset()

        manager.cancelTopUp()
        mock.reset()

        // Next poll: in sailing range → sail
        manager.evaluateState(makeBatteryState(percentage: 75))
        XCTAssertEqual(manager.mode, .sailing,
            "After cancel, next poll in sailing range should sail")
    }

    func testTopUp_unplugged_endsTopUp() {
        manager.startTopUp()
        XCTAssertEqual(manager.mode, .topUp)
        mock.reset()

        // Unplug during Top Up — should end Top Up and go to onBattery
        manager.evaluateState(makeBatteryState(percentage: 85, isPluggedIn: false))
        XCTAssertEqual(manager.mode, .onBattery)
    }

    func testTopUp_lostAfterHeatProtection() {
        // This documents CURRENT behavior: Top Up is lost after heat protection.
        // Heat protection overrides topUp → after cooldown, normal logic resumes,
        // mode is no longer .topUp so charging goes to paused/sailing/charging.
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0

        manager.startTopUp()
        XCTAssertEqual(manager.mode, .topUp)

        // Heat spike interrupts top up
        manager.evaluateState(makeBatteryState(percentage: 85, temperature: 36.0))
        XCTAssertEqual(manager.mode, .heatProtection)

        // Cooldown expires
        manager.heatProtectionTimer = Date().addingTimeInterval(-301)
        manager.evaluateState(makeBatteryState(percentage: 85, temperature: 33.0))

        // Top Up is lost — mode goes to paused (85% > 80% limit)
        XCTAssertEqual(manager.mode, .paused,
            "Known behavior: Top Up is lost after heat protection. " +
            "User must restart Top Up manually.")
        XCTAssertNotEqual(manager.mode, .topUp)
    }

    func testTopUp_doubleStart_noExtraEnableCall() {
        manager.startTopUp()
        XCTAssertEqual(mock.calls.count, 1)

        // Starting again while already in topUp — should still work
        manager.startTopUp()
        XCTAssertEqual(mock.calls.count, 2, "Double start sends enableCharging again (idempotent)")
        XCTAssertEqual(manager.mode, .topUp)
    }

    // =========================================================================
    // MARK: - Automatic Discharge
    // =========================================================================

    func testAutoDischarge_triggersWhenAboveLimit() {
        settings.automaticDischarge = true

        manager.evaluateState(makeBatteryState(percentage: 85))
        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertTrue(mock.calls.contains(.inhibitCharging), "Should inhibit first")
        XCTAssertTrue(mock.calls.contains(.forceDischarge(enable: true)), "Then discharge")
    }

    func testAutoDischarge_doesNotTriggerAtLimit() {
        settings.automaticDischarge = true

        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused,
            "At limit (not above) should pause, not discharge")
    }

    func testAutoDischarge_disabled_justPauses() {
        settings.automaticDischarge = false
        manager.evaluateState(makeBatteryState(percentage: 85))
        XCTAssertEqual(manager.mode, .paused)
        XCTAssertFalse(mock.calls.contains(.forceDischarge(enable: true)))
    }

    func testAutoDischarge_stopsAtLimit() {
        settings.automaticDischarge = true

        // Trigger auto-discharge at 85%
        manager.evaluateState(makeBatteryState(percentage: 85))
        XCTAssertEqual(manager.mode, .discharging)
        mock.reset()

        // Battery reaches limit — auto-discharge should stop
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertTrue(mock.calls.contains(.forceDischarge(enable: false)),
            "Auto-discharge must stop when limit is reached")
        XCTAssertEqual(manager.mode, .paused,
            "After auto-discharge stops at limit, should enter paused mode")
    }

    func testAutoDischarge_stopsBelowLimit() {
        settings.automaticDischarge = true

        manager.evaluateState(makeBatteryState(percentage: 85))
        XCTAssertEqual(manager.mode, .discharging)
        mock.reset()

        // Battery overshoots below limit
        manager.evaluateState(makeBatteryState(percentage: 75))
        XCTAssertTrue(mock.calls.contains(.forceDischarge(enable: false)),
            "Auto-discharge must stop when below limit")
        XCTAssertEqual(manager.mode, .charging,
            "After auto-discharge stops below limit, should charge back up")
    }

    func testManualDischarge_stopsAtLimit() {
        settings.automaticDischarge = false

        manager.startDischarge()
        XCTAssertEqual(manager.mode, .discharging)
        mock.reset()

        // Above limit — discharge continues
        manager.evaluateState(makeBatteryState(percentage: 81))
        XCTAssertEqual(manager.mode, .discharging,
            "Discharge should continue while above limit")

        // At limit — discharge must stop (manual or auto, doesn't matter)
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertNotEqual(manager.mode, .discharging,
            "Discharge must stop when reaching the charge limit")
        XCTAssertTrue(mock.calls.contains(.forceDischarge(enable: false)),
            "Must send forceDischarge(false) when limit is reached")
    }

    // =========================================================================
    // MARK: - Charge Limit Changes
    // =========================================================================

    func testLimitLowered_belowCurrentPercentage_pauses() {
        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertEqual(manager.mode, .charging)
        mock.reset()

        settings.chargeLimit = 40
        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertEqual(manager.mode, .paused)
        XCTAssertEqual(mock.calls, [.inhibitCharging])
    }

    func testLimitRaised_aboveCurrentPercentage_charges() {
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)
        mock.reset()

        settings.chargeLimit = 90
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .charging)
        XCTAssertEqual(mock.calls, [.enableCharging])
    }

    // =========================================================================
    // MARK: - Unknown API (no hardware control available)
    // =========================================================================

    func testUnknownAPI_modeStillChanges_butNoSMCWrites() {
        manager.chargingAPI = .unknown

        manager.evaluateState(makeBatteryState(percentage: 50))
        // Mode reflects intent even without hardware control
        XCTAssertEqual(manager.mode, .charging)
        // But no actual SMC writes (guard in enableCharging/inhibitCharging)
        XCTAssertTrue(mock.calls.isEmpty,
            "Unknown API: mode changes for UI, but no SMC writes attempted")
    }

    func testUnknownAPI_startDischarge_blocked() {
        manager.chargingAPI = .unknown
        manager.startDischarge()
        XCTAssertNotEqual(manager.mode, .discharging,
            "startDischarge with unknown API must not set mode to .discharging")
        XCTAssertTrue(mock.calls.isEmpty, "No SMC writes on unknown API")
    }

    func testUnknownAPI_startTopUp_blocked() {
        manager.chargingAPI = .unknown
        manager.startTopUp()
        XCTAssertNotEqual(manager.mode, .topUp,
            "startTopUp with unknown API must not set mode to .topUp")
        XCTAssertTrue(mock.calls.isEmpty, "No SMC writes on unknown API")
    }

    func testUnknownAPI_pauseCharging_blocked() {
        manager.chargingAPI = .unknown
        manager.pauseCharging()
        XCTAssertNotEqual(manager.mode, .paused,
            "pauseCharging with unknown API must not set mode to .paused")
        XCTAssertTrue(mock.calls.isEmpty, "No SMC writes on unknown API")
    }

    func testHelperNotInstalled_startDischarge_blocked() {
        manager.isHelperInstalled = false
        manager.startDischarge()
        XCTAssertNotEqual(manager.mode, .discharging,
            "startDischarge without helper must not set mode to .discharging")
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testHelperNotInstalled_startTopUp_blocked() {
        manager.isHelperInstalled = false
        manager.startTopUp()
        XCTAssertNotEqual(manager.mode, .topUp,
            "startTopUp without helper must not set mode to .topUp")
        XCTAssertTrue(mock.calls.isEmpty)
    }

    // =========================================================================
    // MARK: - Helper Failure Handling
    // =========================================================================
    // Note: mode is set optimistically BEFORE SMC write confirms.
    // On failure, an async Task resets mode to .idle.
    // This is intentional — XPC calls are async in production.

    func testHelperFailure_modeSetOptimistically_thenResetsAsync() {
        mock.shouldFail = true
        manager.evaluateState(makeBatteryState(percentage: 80))

        // Immediately after evaluateState, mode is set optimistically
        XCTAssertEqual(manager.mode, .paused,
            "Mode is set before SMC confirmation (optimistic)")

        // The failure handler fires via Task — verify it runs
        let expectation = expectation(description: "failure resets mode")
        Task { @MainActor in
            // Yield to let the failure Task run
            try? await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(self.manager.mode, .idle,
                "After failure callback, mode should be reset to idle")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // =========================================================================
    // MARK: - Full Realistic Scenarios
    // =========================================================================

    /// Simulates a full day of use: charge → limit → sail → unplug → plug → sail/charge
    func testFullDayScenario() {
        settings.sailingModeEnabled = true
        settings.sailingRange = 10

        // Morning: plugged in at 60% (below sailing range) → charge
        manager.evaluateState(makeBatteryState(percentage: 60))
        XCTAssertEqual(manager.mode, .charging)

        // Charges up to limit
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)

        // Battery slowly sails down
        manager.evaluateState(makeBatteryState(percentage: 75))
        XCTAssertEqual(manager.mode, .sailing)

        manager.evaluateState(makeBatteryState(percentage: 72))
        XCTAssertEqual(manager.mode, .sailing)

        // Meeting: unplug laptop
        manager.evaluateState(makeBatteryState(percentage: 72, isPluggedIn: false))
        XCTAssertEqual(manager.mode, .onBattery)

        // Battery drains during meeting — below sailing range
        manager.evaluateState(makeBatteryState(percentage: 55, isPluggedIn: false))
        XCTAssertEqual(manager.mode, .onBattery)

        // Back at desk: plug in at 55% (below sailing range 70%) → charge
        manager.evaluateState(makeBatteryState(percentage: 55))
        XCTAssertEqual(manager.mode, .charging)

        // Charges back to limit
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)

        // Short break: unplug, use a bit, plug back in still in sailing range
        manager.evaluateState(makeBatteryState(percentage: 76, isPluggedIn: false))
        XCTAssertEqual(manager.mode, .onBattery)
        manager.evaluateState(makeBatteryState(percentage: 74))
        XCTAssertEqual(manager.mode, .sailing,
            "Plug back in within sailing range → sail, don't charge")
    }

    /// User's exact reported scenario: 75%, limit 80%, sailing 10%, plug in → should NOT charge
    func testUserScenario_plugInWithinSailingRange_doesNotCharge() {
        settings.sailingModeEnabled = true
        settings.chargeLimit = 80
        settings.sailingRange = 10  // lower bound = 70

        // Start on battery at 75%
        manager.evaluateState(makeBatteryState(percentage: 75, isPluggedIn: false))
        XCTAssertEqual(manager.mode, .onBattery)
        mock.reset()

        // Plug in charger — 75% is within sailing range (70-80%)
        manager.evaluateState(makeBatteryState(percentage: 75))
        XCTAssertEqual(manager.mode, .sailing,
            "75% is within sailing range 70-80% — must NOT charge, should sail")
        XCTAssertEqual(mock.calls, [.inhibitCharging],
            "Must actively inhibit charging when entering sailing from plug-in")
    }

    /// Simulates a hot day: normal charging interrupted by heat
    func testHotDayScenario() {
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0

        // Start charging
        manager.evaluateState(makeBatteryState(percentage: 50, temperature: 30.0))
        XCTAssertEqual(manager.mode, .charging)

        // Laptop heats up
        manager.evaluateState(makeBatteryState(percentage: 60, temperature: 36.0))
        XCTAssertEqual(manager.mode, .heatProtection)

        // Fan kicks in, temp drops, but hysteresis holds
        manager.evaluateState(makeBatteryState(percentage: 60, temperature: 33.0))
        XCTAssertEqual(manager.mode, .heatProtection)

        // After 5+ minutes of cool temps
        manager.heatProtectionTimer = Date().addingTimeInterval(-301)
        manager.evaluateState(makeBatteryState(percentage: 60, temperature: 33.0))
        XCTAssertEqual(manager.mode, .charging, "Should resume charging after cooldown")
    }

    // =========================================================================
    // MARK: - Startup Guard (uninitialized data)
    // =========================================================================

    func testStartupGuard_uninitializedData_staysIdle() {
        // BatteryState.unknown: percentage=0, isPluggedIn=false, isCharging=false,
        // timeToEmpty=nil, timeToFull=nil — all sentinel values
        manager.evaluateState(.unknown)
        XCTAssertEqual(manager.mode, .idle,
            "Uninitialized data must not change mode from .idle")
        XCTAssertTrue(mock.calls.isEmpty,
            "No SMC calls on uninitialized data")
    }

    func testStartupGuard_zeroPercentWithTimeToEmpty_evaluatesNormally() {
        // A Mac genuinely at 0% on battery would have timeToEmpty populated
        let state = makeBatteryState(
            percentage: 0, isPluggedIn: false, temperature: nil, timeToEmpty: 5
        )
        manager.evaluateState(state)
        XCTAssertEqual(manager.mode, .onBattery,
            "Real zero-percent data with timeToEmpty should evaluate normally")
    }

    func testStartupGuard_pluggedInAtZero_evaluatesNormally() {
        // isPluggedIn=true passes the guard even at 0%
        let state = makeBatteryState(percentage: 0, isPluggedIn: true)
        manager.evaluateState(state)
        XCTAssertEqual(manager.mode, .charging,
            "Plugged in at 0% should pass guard and start charging")
    }

    func testStartupGuard_chargingAtZero_evaluatesNormally() {
        // isCharging=true passes the guard even at 0%
        let state = makeBatteryState(percentage: 0, isCharging: true, isPluggedIn: true)
        manager.evaluateState(state)
        XCTAssertEqual(manager.mode, .charging)
    }

    // =========================================================================
    // MARK: - Charging Verification (system as source of truth)

    func testVerification_pausedButStillCharging_resendsInhibit() {
        // First evaluation: 90% >= 80% limit → inhibit → paused
        manager.evaluateState(makeBatteryState(percentage: 90))
        XCTAssertEqual(manager.mode, .paused)
        let firstInhibitCount = mock.calls.filter { $0 == .inhibitCharging }.count
        XCTAssertEqual(firstInhibitCount, 1)

        // Simulate 16 seconds passing (past the 15s debounce)
        manager.lastInhibitTime = Date().addingTimeInterval(-16)
        mock.clearCalls()
        manager.evaluateState(makeBatteryState(percentage: 90, isCharging: true))
        XCTAssertEqual(manager.mode, .paused)
        let reInhibitCount = mock.calls.filter { $0 == .inhibitCharging }.count
        XCTAssertEqual(reInhibitCount, 1, "Should re-send inhibit when system still reports charging")
    }

    func testVerification_pausedAndNotCharging_doesNotResend() {
        // First evaluation: inhibit
        manager.evaluateState(makeBatteryState(percentage: 90))
        XCTAssertEqual(manager.mode, .paused)

        // Second evaluation: isCharging=false → no re-send needed
        mock.clearCalls()
        manager.evaluateState(makeBatteryState(percentage: 90, isCharging: false))
        XCTAssertEqual(manager.mode, .paused)
        XCTAssertTrue(mock.calls.filter { $0 == .inhibitCharging }.isEmpty,
            "Should NOT re-send inhibit when system confirms not charging")
    }

    func testVerification_stopsResendingAfter3Retries() {
        manager.evaluateState(makeBatteryState(percentage: 90))
        XCTAssertEqual(manager.mode, .paused)

        // Simulate 3 re-send cycles (past debounce each time)
        for i in 1...3 {
            manager.lastInhibitTime = Date().addingTimeInterval(-16)
            mock.clearCalls()
            manager.evaluateState(makeBatteryState(percentage: 90, isCharging: true))
            XCTAssertEqual(mock.calls.filter { $0 == .inhibitCharging }.count, 1,
                "Re-send attempt \(i) should fire")
        }

        // 4th attempt: should NOT re-send (retry limit reached)
        manager.lastInhibitTime = Date().addingTimeInterval(-16)
        mock.clearCalls()
        manager.evaluateState(makeBatteryState(percentage: 90, isCharging: true))
        XCTAssertTrue(mock.calls.filter { $0 == .inhibitCharging }.isEmpty,
            "Should stop re-sending after 3 retries — IOKit lag, not a real failure")
    }

    func testVerification_retryCountResetsWhenIOKitCatchesUp() {
        manager.evaluateState(makeBatteryState(percentage: 90))
        XCTAssertEqual(manager.mode, .paused)

        // Use up 2 retries
        for _ in 1...2 {
            manager.lastInhibitTime = Date().addingTimeInterval(-16)
            manager.evaluateState(makeBatteryState(percentage: 90, isCharging: true))
        }
        XCTAssertEqual(manager.inhibitRetryCount, 2)

        // IOKit catches up (isCharging=false)
        manager.evaluateState(makeBatteryState(percentage: 90, isCharging: false))
        XCTAssertEqual(manager.inhibitRetryCount, 0, "Retry count should reset when IOKit confirms")

        // New inhibit cycle should have fresh retries
        manager.lastInhibitTime = Date().addingTimeInterval(-16)
        mock.clearCalls()
        manager.evaluateState(makeBatteryState(percentage: 90, isCharging: true))
        XCTAssertEqual(mock.calls.filter { $0 == .inhibitCharging }.count, 1,
            "Fresh retry after IOKit reset")
    }

    func testVerification_sailingButStillCharging_resendsInhibit() {
        settings.sailingModeEnabled = true
        settings.sailingRange = 10

        manager.evaluateState(makeBatteryState(percentage: 75))
        XCTAssertEqual(manager.mode, .sailing)

        manager.lastInhibitTime = Date().addingTimeInterval(-16)
        mock.clearCalls()
        manager.evaluateState(makeBatteryState(percentage: 75, isCharging: true))
        XCTAssertEqual(manager.mode, .sailing)
        let reInhibitCount = mock.calls.filter { $0 == .inhibitCharging }.count
        XCTAssertEqual(reInhibitCount, 1, "Should re-send inhibit when system still reports charging in sailing mode")
    }

    // =========================================================================
    // MARK: - MagSafe LED
    // =========================================================================

    func testMagSafeLED_chargingMode_sendsOrange() {
        settings.controlMagSafeLED = true
        manager.helperVersion = HelperConstants.helperVersion
        // LED shows orange in charging mode — reflects intent, not IOKit lag
        manager.evaluateState(makeBatteryState(percentage: 50, isCharging: true))
        XCTAssertEqual(manager.mode, .charging)
        XCTAssertTrue(mock.calls.contains(.setMagSafeLED(color: HelperConstants.ledOrange)),
            "Charging mode should set LED to orange")
    }

    func testMagSafeLED_chargingMode_orangeEvenBeforeIOKitConfirms() {
        settings.controlMagSafeLED = true
        manager.helperVersion = HelperConstants.helperVersion
        // IOKit hasn't confirmed charging yet (isCharging=false), but mode is .charging
        // LED should still be orange — shows intent, not stale IOKit state
        manager.evaluateState(makeBatteryState(percentage: 50, isCharging: false))
        XCTAssertEqual(manager.mode, .charging)
        XCTAssertEqual(manager.lastLEDColor, HelperConstants.ledOrange,
            "Charging mode should show orange LED even before IOKit confirms (intent, not lag)")
    }

    func testMagSafeLED_pausedMode_sendsGreen() {
        settings.controlMagSafeLED = true
        manager.helperVersion = HelperConstants.helperVersion
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)
        XCTAssertTrue(mock.calls.contains(.setMagSafeLED(color: HelperConstants.ledGreen)),
            "Paused mode should set LED to green")
    }

    func testMagSafeLED_onBattery_sendsDefault() {
        settings.controlMagSafeLED = true
        manager.helperVersion = HelperConstants.helperVersion
        manager.evaluateState(makeBatteryState(percentage: 50, isPluggedIn: false))
        XCTAssertEqual(manager.mode, .onBattery)
        XCTAssertTrue(mock.calls.contains(.setMagSafeLED(color: HelperConstants.ledAuto)),
            "On battery should set LED to system default")
    }

    func testMagSafeLED_disabled_noCalls() {
        settings.controlMagSafeLED = false
        manager.helperVersion = HelperConstants.helperVersion
        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertEqual(manager.mode, .charging)
        XCTAssertFalse(mock.calls.contains(where: {
            if case .setMagSafeLED = $0 { return true }
            return false
        }), "LED control disabled — no setMagSafeLED calls")
    }

    func testMagSafeLED_topUp_sendsOrange() {
        settings.controlMagSafeLED = true
        manager.helperVersion = HelperConstants.helperVersion
        // Start top up, then evaluate with IOKit confirming charging
        manager.startTopUp()
        manager.evaluateState(makeBatteryState(percentage: 50, isCharging: true))
        XCTAssertEqual(manager.lastLEDColor, HelperConstants.ledOrange,
            "Top Up with IOKit isCharging=true should have LED orange")
    }

    func testMagSafeLED_sailing_sendsGreen() {
        settings.controlMagSafeLED = true
        manager.helperVersion = HelperConstants.helperVersion
        settings.sailingModeEnabled = true
        settings.sailingRange = 10

        manager.evaluateState(makeBatteryState(percentage: 75))
        XCTAssertEqual(manager.mode, .sailing)
        XCTAssertTrue(mock.calls.contains(.setMagSafeLED(color: HelperConstants.ledGreen)),
            "Sailing mode should set LED to green")
    }

    func testMagSafeLED_pausedMode_offWhenInactive() {
        settings.controlMagSafeLED = true
        settings.magSafeLEDOffWhenInactive = true
        manager.helperVersion = HelperConstants.helperVersion
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)
        XCTAssertTrue(mock.calls.contains(.setMagSafeLED(color: HelperConstants.ledOff)),
            "Paused mode with offWhenInactive should set LED off")
    }

    func testMagSafeLED_sailing_offWhenInactive() {
        settings.controlMagSafeLED = true
        settings.magSafeLEDOffWhenInactive = true
        manager.helperVersion = HelperConstants.helperVersion
        settings.sailingModeEnabled = true
        settings.sailingRange = 10

        manager.evaluateState(makeBatteryState(percentage: 75))
        XCTAssertEqual(manager.mode, .sailing)
        XCTAssertTrue(mock.calls.contains(.setMagSafeLED(color: HelperConstants.ledOff)),
            "Sailing mode with offWhenInactive should set LED off")
    }

    func testMagSafeLED_discharging_sendsOrange() {
        settings.controlMagSafeLED = true
        manager.helperVersion = HelperConstants.helperVersion
        manager.startDischarge()
        XCTAssertEqual(manager.mode, .discharging)
        XCTAssertTrue(mock.calls.contains(.setMagSafeLED(color: HelperConstants.ledOrange)),
            "Discharging mode should set LED to orange")
    }

    func testMagSafeLED_oldHelper_noCalls() {
        settings.controlMagSafeLED = true
        manager.helperVersion = "1.0.0"  // Old helper without LED support
        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertEqual(manager.mode, .charging)
        XCTAssertFalse(mock.calls.contains(where: {
            if case .setMagSafeLED = $0 { return true }
            return false
        }), "Old helper (1.0.0) must not receive setMagSafeLED calls")
    }

    func testMagSafeLED_noHelperVersion_noCalls() {
        settings.controlMagSafeLED = true
        // helperVersion is nil (not yet queried)
        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertEqual(manager.mode, .charging)
        XCTAssertFalse(mock.calls.contains(where: {
            if case .setMagSafeLED = $0 { return true }
            return false
        }), "Before version is known, no LED calls should be made")
    }

    func testMagSafeLED_multiDigitVersion_sendsLED() {
        settings.controlMagSafeLED = true
        manager.helperVersion = "1.10.0"  // Would fail with lexicographic string compare
        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertEqual(manager.mode, .charging)
        XCTAssertTrue(mock.calls.contains(where: {
            if case .setMagSafeLED = $0 { return true }
            return false
        }), "Version 1.10.0 >= 1.1.0 — LED calls must be made (semantic compare)")
    }

    func testMagSafeLED_reconnect_resetsStaleCacheAndResends() {
        settings.controlMagSafeLED = true
        manager.helperVersion = HelperConstants.helperVersion

        // Set LED to green (paused mode, IOKit not charging)
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertEqual(manager.mode, .paused)
        XCTAssertEqual(manager.lastLEDColor, HelperConstants.ledGreen)
        mock.clearCalls()

        // Simulate helper reconnect: reset LED cache as connectToHelper does
        manager.lastLEDColor = nil

        // Re-evaluate — same state, but cache is cleared so LED should be re-sent
        manager.evaluateState(makeBatteryState(percentage: 80))
        XCTAssertTrue(mock.calls.contains(.setMagSafeLED(color: HelperConstants.ledGreen)),
            "After cache reset (simulating reconnect), LED should be re-sent")
    }

    // =========================================================================
    // MARK: - Hardware Battery Percentage
    // =========================================================================

    func testHardwarePercentage_usedForLimitComparison() {
        // macOS=78%, hw=81%, limit=80% → hw says above limit → paused
        settings.useHardwareBatteryPercentage = true
        manager.evaluateState(makeBatteryState(percentage: 78, hardwarePercentage: 81))
        XCTAssertEqual(manager.mode, .paused, "Hardware % above limit should pause")
    }

    func testHardwarePercentage_settingDisabled_usesMacOS() {
        // Same data but setting off → macOS 78% < 80% → charging
        settings.useHardwareBatteryPercentage = false
        manager.evaluateState(makeBatteryState(percentage: 78, hardwarePercentage: 81))
        XCTAssertEqual(manager.mode, .charging, "With HW% disabled, macOS % below limit should charge")
    }

    func testHardwarePercentage_sailingRangeUsesHardware() {
        settings.useHardwareBatteryPercentage = true
        settings.sailingModeEnabled = true
        settings.chargeLimit = 80
        settings.sailingRange = 10  // lower bound = 70

        // macOS=68%, hw=72% → hw is in sailing range (70-80)
        manager.evaluateState(makeBatteryState(percentage: 68, hardwarePercentage: 72))
        XCTAssertEqual(manager.mode, .sailing, "Hardware % in sailing range should sail")
    }

    func testHardwarePercentage_autoDischargeUsesHardware() {
        settings.useHardwareBatteryPercentage = true
        settings.automaticDischarge = true
        settings.chargeLimit = 80

        // Start discharge: hw=85% > 80% → auto-discharge starts
        manager.evaluateState(makeBatteryState(percentage: 78, hardwarePercentage: 85))
        XCTAssertEqual(manager.mode, .discharging, "Auto-discharge should trigger based on hw%")

        // Discharge reaches limit: hw=80% <= 80% → stops
        mock.clearCalls()
        manager.evaluateState(makeBatteryState(percentage: 76, hardwarePercentage: 80))
        XCTAssertNotEqual(manager.mode, .discharging, "Auto-discharge should stop when hw% reaches limit")
    }
}

// MARK: - Version Comparison Tests

final class VersionComparisonTests: XCTestCase {

    func testEqual() {
        XCTAssertTrue("1.1.0".isVersionAtLeast("1.1.0"))
    }

    func testHigherMinor() {
        XCTAssertTrue("1.2.0".isVersionAtLeast("1.1.0"))
    }

    func testMultiDigitMinor() {
        XCTAssertTrue("1.10.0".isVersionAtLeast("1.2.0"),
            "Numeric compare: 10 > 2, must not use lexicographic")
    }

    func testHigherMajor() {
        XCTAssertTrue("2.0.0".isVersionAtLeast("1.99.0"))
    }

    func testLowerVersion() {
        XCTAssertFalse("1.0.0".isVersionAtLeast("1.1.0"))
    }

    func testMuchLowerVersion() {
        XCTAssertFalse("0.9.0".isVersionAtLeast("1.0.0"))
    }

    func testHigherPatch() {
        XCTAssertTrue("1.1.1".isVersionAtLeast("1.1.0"))
    }
}
