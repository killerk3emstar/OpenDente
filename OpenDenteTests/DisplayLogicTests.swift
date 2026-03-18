import XCTest
@testable import OpenDente

final class DisplayLogicTests: XCTestCase {

    // MARK: - formatMinutes

    func testFormatMinutes_hoursAndMinutes() {
        XCTAssertEqual(BatteryState.formatMinutes(150), "2h 30m")
    }

    func testFormatMinutes_exactHour() {
        XCTAssertEqual(BatteryState.formatMinutes(60), "1h 0m")
    }

    func testFormatMinutes_minutesOnly() {
        XCTAssertEqual(BatteryState.formatMinutes(45), "45m")
    }

    func testFormatMinutes_oneMinute() {
        XCTAssertEqual(BatteryState.formatMinutes(1), "1m")
    }

    func testFormatMinutes_zero() {
        XCTAssertEqual(BatteryState.formatMinutes(0), "0m")
    }

    // MARK: - timeRemainingDisplay: Charging

    func testCharging_estimatesTimeToLimit() {
        // 50% → 80%, timeToFull (to 100%) = 120min
        // Expected: 120 * (80-50) / (100-50) = 72min = "1h 12m"
        let result = ChargingMode.charging.timeRemainingDisplay(
            chargeLimit: 80, percentage: 50, timeToFull: 120, timeToEmpty: nil
        )
        XCTAssertEqual(result?.label, "Time to 80%")
        XCTAssertEqual(result?.value, "1h 12m")
    }

    func testCharging_showsCalculatingWhenNoData() {
        let result = ChargingMode.charging.timeRemainingDisplay(
            chargeLimit: 80, percentage: 50, timeToFull: nil, timeToEmpty: nil
        )
        XCTAssertEqual(result?.label, "Time to 80%")
        XCTAssertEqual(result?.value, "Calculating…")
    }

    func testCharging_showsCalculatingWhenTimeToFullZero() {
        let result = ChargingMode.charging.timeRemainingDisplay(
            chargeLimit: 80, percentage: 50, timeToFull: 0, timeToEmpty: nil
        )
        XCTAssertEqual(result?.value, "Calculating…")
    }

    func testCharging_showsCalculatingWhenTimeToFullTooLarge() {
        let result = ChargingMode.charging.timeRemainingDisplay(
            chargeLimit: 80, percentage: 50, timeToFull: 7000, timeToEmpty: nil
        )
        XCTAssertEqual(result?.value, "Calculating…")
    }

    func testCharging_showsReachedWhenAtLimit() {
        let result = ChargingMode.charging.timeRemainingDisplay(
            chargeLimit: 80, percentage: 80, timeToFull: 60, timeToEmpty: nil
        )
        XCTAssertEqual(result?.label, "Time to 80%")
        XCTAssertEqual(result?.value, "Reached")
    }

    func testCharging_showsReachedWhenAboveLimit() {
        let result = ChargingMode.charging.timeRemainingDisplay(
            chargeLimit: 80, percentage: 85, timeToFull: 30, timeToEmpty: nil
        )
        XCTAssertEqual(result?.value, "Reached")
    }

    func testCharging_nearLimit_showsMinimumOneMinute() {
        // 79% → 80%, timeToFull = 60min → 60 * 1/21 ≈ 2.8 → 2, but max(1, ...) guarantees ≥ 1
        let result = ChargingMode.charging.timeRemainingDisplay(
            chargeLimit: 80, percentage: 79, timeToFull: 10, timeToEmpty: nil
        )
        XCTAssertNotNil(result)
        XCTAssertNotEqual(result?.value, "Calculating…")
        XCTAssertNotEqual(result?.value, "0m")
    }

    func testCharging_at100Percent_showsCalculating() {
        // Edge case: percentage = 100 but mode is .charging (shouldn't happen, but defensively)
        // remaining = 100 - 100 = 0 → guard catches it
        let result = ChargingMode.charging.timeRemainingDisplay(
            chargeLimit: 100, percentage: 100, timeToFull: 0, timeToEmpty: nil
        )
        XCTAssertEqual(result?.value, "Reached")
    }

    func testCharging_labelIncludesActualLimit() {
        let result60 = ChargingMode.charging.timeRemainingDisplay(
            chargeLimit: 60, percentage: 30, timeToFull: 120, timeToEmpty: nil
        )
        XCTAssertEqual(result60?.label, "Time to 60%")

        let result100 = ChargingMode.charging.timeRemainingDisplay(
            chargeLimit: 100, percentage: 30, timeToFull: 120, timeToEmpty: nil
        )
        XCTAssertEqual(result100?.label, "Time to 100%")
    }

    // MARK: - timeRemainingDisplay: Top Up

    func testTopUp_showsTimeToFull() {
        let result = ChargingMode.topUp.timeRemainingDisplay(
            chargeLimit: 80, percentage: 85, timeToFull: 30, timeToEmpty: nil
        )
        XCTAssertEqual(result?.label, "Time to Full")
        XCTAssertEqual(result?.value, "30m")
    }

    func testTopUp_showsChargedAt100() {
        let result = ChargingMode.topUp.timeRemainingDisplay(
            chargeLimit: 80, percentage: 100, timeToFull: 0, timeToEmpty: nil
        )
        XCTAssertEqual(result?.label, "Time to Full")
        XCTAssertEqual(result?.value, "Charged")
    }

    func testTopUp_showsCalculatingWhenNoData() {
        let result = ChargingMode.topUp.timeRemainingDisplay(
            chargeLimit: 80, percentage: 85, timeToFull: nil, timeToEmpty: nil
        )
        XCTAssertEqual(result?.value, "Calculating…")
    }

    // MARK: - timeRemainingDisplay: Discharging / On Battery

    func testDischarging_showsTimeToEmpty() {
        let result = ChargingMode.discharging.timeRemainingDisplay(
            chargeLimit: 80, percentage: 50, timeToFull: nil, timeToEmpty: 150
        )
        XCTAssertEqual(result?.label, "Time Remaining")
        XCTAssertEqual(result?.value, "2h 30m")
    }

    func testOnBattery_showsTimeToEmpty() {
        let result = ChargingMode.onBattery.timeRemainingDisplay(
            chargeLimit: 80, percentage: 50, timeToFull: nil, timeToEmpty: 45
        )
        XCTAssertEqual(result?.label, "Time Remaining")
        XCTAssertEqual(result?.value, "45m")
    }

    func testDischarging_showsCalculatingWhenNoData() {
        let result = ChargingMode.discharging.timeRemainingDisplay(
            chargeLimit: 80, percentage: 50, timeToFull: nil, timeToEmpty: nil
        )
        XCTAssertEqual(result?.value, "Calculating…")
    }

    func testOnBattery_showsCalculatingWhenTimeToEmptyTooLarge() {
        let result = ChargingMode.onBattery.timeRemainingDisplay(
            chargeLimit: 80, percentage: 50, timeToFull: nil, timeToEmpty: 7000
        )
        XCTAssertEqual(result?.value, "Calculating…")
    }

    // MARK: - timeRemainingDisplay: Paused / Sailing / Heat Protection

    func testPaused_showsDash() {
        let result = ChargingMode.paused.timeRemainingDisplay(
            chargeLimit: 80, percentage: 80, timeToFull: nil, timeToEmpty: nil
        )
        XCTAssertEqual(result?.label, "Time Remaining")
        XCTAssertEqual(result?.value, "–")
    }

    func testSailing_showsDash() {
        let result = ChargingMode.sailing.timeRemainingDisplay(
            chargeLimit: 80, percentage: 75, timeToFull: nil, timeToEmpty: nil
        )
        XCTAssertEqual(result?.value, "–")
    }

    func testHeatProtection_showsPaused() {
        let result = ChargingMode.heatProtection.timeRemainingDisplay(
            chargeLimit: 80, percentage: 50, timeToFull: nil, timeToEmpty: nil
        )
        XCTAssertEqual(result?.label, "Time Remaining")
        XCTAssertEqual(result?.value, "Paused")
    }

    // MARK: - timeRemainingDisplay: Idle / Calibrating (hidden)

    func testIdle_returnsNil() {
        let result = ChargingMode.idle.timeRemainingDisplay(
            chargeLimit: 80, percentage: 50, timeToFull: nil, timeToEmpty: nil
        )
        XCTAssertNil(result)
    }

    func testCalibrating_returnsNil() {
        let result = ChargingMode.calibrating.timeRemainingDisplay(
            chargeLimit: 80, percentage: 50, timeToFull: nil, timeToEmpty: nil
        )
        XCTAssertNil(result)
    }

    // MARK: - batteryIconName

    func testIcon_chargingMode_showsBolt() {
        let icon = ChargingMode.charging.batteryIconName(percentage: 50, isCharging: false)
        XCTAssertEqual(icon, "battery.100percent.bolt")
    }

    func testIcon_topUpMode_showsBolt() {
        let icon = ChargingMode.topUp.batteryIconName(percentage: 50, isCharging: false)
        XCTAssertEqual(icon, "battery.100percent.bolt")
    }

    func testIcon_isCharging_showsBoltRegardlessOfMode() {
        let icon = ChargingMode.paused.batteryIconName(percentage: 50, isCharging: true)
        XCTAssertEqual(icon, "battery.100percent.bolt")
    }

    func testIcon_paused_notCharging_showsPercentageBased() {
        XCTAssertEqual(
            ChargingMode.paused.batteryIconName(percentage: 100, isCharging: false),
            "battery.100percent"
        )
        XCTAssertEqual(
            ChargingMode.paused.batteryIconName(percentage: 88, isCharging: false),
            "battery.100percent"
        )
        XCTAssertEqual(
            ChargingMode.paused.batteryIconName(percentage: 87, isCharging: false),
            "battery.75percent"
        )
        XCTAssertEqual(
            ChargingMode.paused.batteryIconName(percentage: 63, isCharging: false),
            "battery.75percent"
        )
        XCTAssertEqual(
            ChargingMode.paused.batteryIconName(percentage: 62, isCharging: false),
            "battery.50percent"
        )
        XCTAssertEqual(
            ChargingMode.paused.batteryIconName(percentage: 38, isCharging: false),
            "battery.50percent"
        )
        XCTAssertEqual(
            ChargingMode.paused.batteryIconName(percentage: 37, isCharging: false),
            "battery.25percent"
        )
        XCTAssertEqual(
            ChargingMode.paused.batteryIconName(percentage: 13, isCharging: false),
            "battery.25percent"
        )
        XCTAssertEqual(
            ChargingMode.paused.batteryIconName(percentage: 12, isCharging: false),
            "battery.0percent"
        )
        XCTAssertEqual(
            ChargingMode.paused.batteryIconName(percentage: 0, isCharging: false),
            "battery.0percent"
        )
    }

    func testIcon_onBattery_showsPercentageBased() {
        let icon = ChargingMode.onBattery.batteryIconName(percentage: 50, isCharging: false)
        XCTAssertEqual(icon, "battery.50percent")
    }

    // MARK: - canDischarge

    func testCanDischarge_pluggedInAboveLimit_true() {
        XCTAssertTrue(
            PopoverView.canDischarge(isPluggedIn: true, percentage: 85, chargeLimit: 80, isHelperInstalled: true, chargingAPI: .legacy)
        )
    }

    func testCanDischarge_notPluggedIn_false() {
        XCTAssertFalse(
            PopoverView.canDischarge(isPluggedIn: false, percentage: 85, chargeLimit: 80, isHelperInstalled: true, chargingAPI: .legacy)
        )
    }

    func testCanDischarge_atOrBelowLimit_false() {
        XCTAssertFalse(
            PopoverView.canDischarge(isPluggedIn: true, percentage: 80, chargeLimit: 80, isHelperInstalled: true, chargingAPI: .legacy)
        )
        XCTAssertFalse(
            PopoverView.canDischarge(isPluggedIn: true, percentage: 75, chargeLimit: 80, isHelperInstalled: true, chargingAPI: .legacy)
        )
    }

    func testCanDischarge_noHelper_false() {
        XCTAssertFalse(
            PopoverView.canDischarge(isPluggedIn: true, percentage: 85, chargeLimit: 80, isHelperInstalled: false, chargingAPI: .legacy)
        )
    }

    func testCanDischarge_unknownAPI_false() {
        XCTAssertFalse(
            PopoverView.canDischarge(isPluggedIn: true, percentage: 85, chargeLimit: 80, isHelperInstalled: true, chargingAPI: .unknown),
            "Unknown charging API must prevent discharge — no SMC keys to write"
        )
    }
}
