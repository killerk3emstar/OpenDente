import XCTest
@testable import OpenDente

/// Tests for PowerFlowView visual state logic.
/// Ensures the display never lies — shows only measured data, never derived values.
final class PowerFlowViewTests: XCTestCase {

    // MARK: - Visual State: Charging

    func testCharging_withMeasuredBatteryPower_showsChargingBars() {
        let state = makeState(isCharging: true, isPluggedIn: true, batteryPower: 45.0, systemPower: 15.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .charging)
        XCTAssertEqual(visual, .pluggedInCharging)
    }

    func testCharging_trickleCharge_showsTrickle() {
        // Battery power near zero but IOKit says charging
        let state = makeState(isCharging: true, isPluggedIn: true, batteryPower: 0.05, systemPower: 14.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .charging)
        XCTAssertEqual(visual, .pluggedInTrickleCharging)
    }

    func testCharging_noBatteryPowerData_showsTrickle() {
        let state = makeState(isCharging: true, isPluggedIn: true, batteryPower: nil, systemPower: 14.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .charging)
        XCTAssertEqual(visual, .pluggedInTrickleCharging)
    }

    func testTopUp_withPower_showsCharging() {
        let state = makeState(isCharging: true, isPluggedIn: true, batteryPower: 30.0, systemPower: 15.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .topUp)
        XCTAssertEqual(visual, .pluggedInCharging)
    }

    // MARK: - Visual State: Paused / Sailing / Heat Protection

    func testPaused_noBatteryBar() {
        let state = makeState(isCharging: false, isPluggedIn: true, batteryPower: 0.0, systemPower: 14.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .paused)
        XCTAssertEqual(visual, .pluggedInPaused)
    }

    func testSailing_noBatteryBar() {
        let state = makeState(isCharging: false, isPluggedIn: true, batteryPower: nil, systemPower: 14.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .sailing)
        XCTAssertEqual(visual, .pluggedInPaused)
    }

    func testHeatProtection_noBatteryBar() {
        let state = makeState(isCharging: false, isPluggedIn: true, batteryPower: 0.02, systemPower: 14.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .heatProtection)
        XCTAssertEqual(visual, .pluggedInPaused)
    }

    // MARK: - Visual State: Transitional

    func testStopping_inhibitedButStillCharging() {
        // Mode says paused but IOKit still reports charging (hardware lag)
        let state = makeState(isCharging: true, isPluggedIn: true, batteryPower: 8.0, systemPower: 14.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .paused)
        XCTAssertEqual(visual, .pluggedInStopping)
    }

    func testStopping_sailingButStillCharging() {
        let state = makeState(isCharging: true, isPluggedIn: true, batteryPower: 5.0, systemPower: 14.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .sailing)
        XCTAssertEqual(visual, .pluggedInStopping)
    }

    func testStopping_heatProtectionButStillCharging() {
        let state = makeState(isCharging: true, isPluggedIn: true, batteryPower: 3.0, systemPower: 14.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .heatProtection)
        XCTAssertEqual(visual, .pluggedInStopping)
    }

    func testStarting_chargingModeButIOKitNotYetConfirmed() {
        let state = makeState(isCharging: false, isPluggedIn: true, batteryPower: 0.0, systemPower: 14.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .charging)
        XCTAssertEqual(visual, .pluggedInStarting)
    }

    // MARK: - Visual State: Peak Load

    func testPeakLoad_batterySupplementingAdapter() {
        // System draws more than adapter provides — battery draining while plugged in
        let state = makeState(isCharging: false, isPluggedIn: true, batteryPower: -18.0, systemPower: 85.0, adapterPower: 67.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .charging)
        XCTAssertEqual(visual, .peakLoad)
    }

    func testPeakLoad_smallDrain_ignoredBelowThreshold() {
        // Battery draining slightly (< 0.1W) — noise, not peak load
        let state = makeState(isCharging: false, isPluggedIn: true, batteryPower: -0.05, systemPower: 14.0, adapterPower: 67.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .charging)
        // Below threshold → treated as starting (mode=charging, not charging yet)
        XCTAssertEqual(visual, .pluggedInStarting)
    }

    func testPeakLoad_notTriggeredDuringInhibitedModes() {
        // Battery draining while paused → not peak load, it's just paused state
        // (battery may show small negative due to measurement noise)
        let state = makeState(isCharging: false, isPluggedIn: true, batteryPower: -0.5, systemPower: 14.0, adapterPower: 67.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .paused)
        XCTAssertEqual(visual, .pluggedInPaused)
    }

    // MARK: - Visual State: On Battery

    func testOnBattery_showsBatteryView() {
        let state = makeState(isCharging: false, isPluggedIn: false, batteryPower: -12.0, systemPower: 12.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .onBattery)
        XCTAssertEqual(visual, .onBattery)
    }

    func testForceDischarge_showsOnBatteryView() {
        // Force discharge = virtual unplug — same view as on battery
        let state = makeState(isCharging: false, isPluggedIn: true, batteryPower: -15.0, systemPower: 15.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .discharging)
        XCTAssertEqual(visual, .onBattery)
    }

    func testForceDischarge_evenWhenPluggedIn_showsOnBattery() {
        let state = makeState(isCharging: false, isPluggedIn: true, batteryPower: nil, systemPower: 10.0)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .discharging)
        XCTAssertEqual(visual, .onBattery)
    }

    // MARK: - Visual State: No Power Data

    func testNoPowerData_showsFallback() {
        let state = makeState(isCharging: false, isPluggedIn: true, batteryPower: nil, systemPower: nil, adapterPower: nil)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .paused)
        XCTAssertEqual(visual, .noPowerData)
    }

    func testNoPowerData_onBattery_showsFallback() {
        let state = makeState(isCharging: false, isPluggedIn: false, batteryPower: nil, systemPower: nil, adapterPower: nil)
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .onBattery)
        XCTAssertEqual(visual, .noPowerData)
    }

    // MARK: - Battery Source Icon

    func testBatteryIcon_fullCharge() {
        XCTAssertEqual(PowerFlowView.batterySourceIcon(percentage: 100), "battery.100percent")
        XCTAssertEqual(PowerFlowView.batterySourceIcon(percentage: 88), "battery.100percent")
    }

    func testBatteryIcon_75percent() {
        XCTAssertEqual(PowerFlowView.batterySourceIcon(percentage: 87), "battery.75percent")
        XCTAssertEqual(PowerFlowView.batterySourceIcon(percentage: 63), "battery.75percent")
    }

    func testBatteryIcon_50percent() {
        XCTAssertEqual(PowerFlowView.batterySourceIcon(percentage: 62), "battery.50percent")
        XCTAssertEqual(PowerFlowView.batterySourceIcon(percentage: 38), "battery.50percent")
    }

    func testBatteryIcon_25percent() {
        XCTAssertEqual(PowerFlowView.batterySourceIcon(percentage: 37), "battery.25percent")
        XCTAssertEqual(PowerFlowView.batterySourceIcon(percentage: 13), "battery.25percent")
    }

    func testBatteryIcon_empty() {
        XCTAssertEqual(PowerFlowView.batterySourceIcon(percentage: 12), "battery.0percent")
        XCTAssertEqual(PowerFlowView.batterySourceIcon(percentage: 0), "battery.0percent")
    }

    // MARK: - Key Invariant: Never Derived Math

    /// The old code computed batteryChargingPower = adapter - system.
    /// Verify that the visual state logic uses batteryPower directly and doesn't
    /// care about the relationship between adapter and system power.
    func testChargingState_independentOfAdapterMinusSystem() {
        // Adapter 67W, system 15W, battery 45W → "missing" 7W is conversion loss
        // The view should show 45W battery power (measured), NOT 67-15=52W (derived)
        let state = makeState(
            isCharging: true, isPluggedIn: true,
            batteryPower: 45.0, systemPower: 15.0, adapterPower: 67.0
        )
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .charging)
        XCTAssertEqual(visual, .pluggedInCharging)
        // The actual value shown (45W) is tested via the batteryPower property,
        // not via adapter - system. No derived computation exists in the view.
    }

    /// Peak load detection based on measured battery power, not adapter vs system comparison.
    func testPeakLoad_basedOnMeasuredBatteryDrain() {
        // Even if adapter > system (by numbers), if battery says it's draining, trust it
        let state = makeState(
            isCharging: false, isPluggedIn: true,
            batteryPower: -5.0, systemPower: 14.0, adapterPower: 67.0
        )
        let visual = PowerFlowView.resolveVisualState(battery: state, mode: .charging)
        XCTAssertEqual(visual, .peakLoad, "Peak load should be detected from batteryPower, not from adapter vs system")
    }

    // MARK: - Helpers

    private func makeState(
        percentage: Int = 50,
        isCharging: Bool,
        isPluggedIn: Bool,
        batteryPower: Double?,
        systemPower: Double? = 14.0,
        adapterPower: Double? = 67.0
    ) -> BatteryState {
        BatteryState(
            percentage: percentage,
            hardwarePercentage: nil,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            currentCapacity: nil,
            maxCapacity: nil,
            designCapacity: nil,
            cycleCount: nil,
            temperature: nil,
            voltage: nil,
            amperage: nil,
            systemPower: systemPower,
            adapterPower: adapterPower,
            adapterInfo: nil,
            batteryPower: batteryPower,
            notChargingReason: nil,
            chargerInhibitReason: nil,
            timeToEmpty: nil,
            timeToFull: nil
        )
    }
}
