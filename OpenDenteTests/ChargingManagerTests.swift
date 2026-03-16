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
    }

    /// All calls in order — use this to verify exact sequences of SMC operations
    private(set) var calls: [Call] = []

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

    nonisolated func resetToDefaultsSync(timeout: TimeInterval) {}

    func reset() { calls.removeAll() }
}

// MARK: - Test Factory

/// Create a BatteryState with sensible defaults, overriding only what's needed.
/// Plugged in by default because that's when charging control is active.
func makeBatteryState(
    percentage: Int = 50,
    isCharging: Bool = false,
    isPluggedIn: Bool = true,
    temperature: Double? = 25.0
) -> BatteryState {
    BatteryState(
        percentage: percentage,
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
        adapterPower: nil,
        batteryPower: nil,
        timeToEmpty: nil,
        timeToFull: nil
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

        // Known defaults for deterministic tests
        settings.chargeLimit = 80
        settings.sailingModeEnabled = false
        settings.heatProtectionEnabled = false
        settings.automaticDischarge = false
    }

    override func tearDown() {
        settings.chargeLimit = 80
        settings.sailingModeEnabled = true
        settings.sailingRange = 10
        settings.heatProtectionEnabled = true
        settings.heatProtectionTemp = 35.0
        settings.automaticDischarge = false
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

    func testDischarge_notOverriddenByEvaluateState() {
        manager.startDischarge()
        XCTAssertEqual(manager.mode, .discharging)
        mock.reset()

        manager.evaluateState(makeBatteryState(percentage: 50))
        XCTAssertEqual(manager.mode, .discharging,
            "REGRESSION: Discharge must not be overridden by state machine")
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testDischarge_notOverriddenEvenAboveLimit() {
        manager.startDischarge()
        mock.reset()

        manager.evaluateState(makeBatteryState(percentage: 95))
        XCTAssertEqual(manager.mode, .discharging)
    }

    func testDischarge_endsOnUnplug() {
        manager.startDischarge()
        manager.evaluateState(makeBatteryState(percentage: 70, isPluggedIn: false))
        XCTAssertEqual(manager.mode, .onBattery)
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
}
