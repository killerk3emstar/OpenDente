import XCTest
@testable import OpenDente

final class BatteryStateTests: XCTestCase {

    // MARK: - Health Percentage

    func testHealthPercentage_normalBattery() {
        let state = BatteryState(
            percentage: 80, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: 4500, designCapacity: 5000, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertEqual(state.healthPercentage!, 90.0, accuracy: 0.1)
    }

    func testHealthPercentage_newBatteryCanExceed100() {
        // New batteries can report slightly above design capacity — this is real data, not a bug
        let state = BatteryState(
            percentage: 100, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: 5100, designCapacity: 5000, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertEqual(state.healthPercentage!, 102.0, accuracy: 0.1)
    }

    func testHealthPercentage_nilWhenMissingData() {
        let state = BatteryState(
            percentage: 50, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertNil(state.healthPercentage)
    }

    func testHealthPercentage_nilWhenDesignCapacityZero() {
        let state = BatteryState(
            percentage: 50, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: 5000, designCapacity: 0, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertNil(state.healthPercentage)
    }

    // MARK: - Time Remaining Formatting

    func testTimeRemaining_hoursAndMinutes() {
        let state = BatteryState(
            percentage: 50, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: 150, timeToFull: nil
        )
        XCTAssertEqual(state.timeRemainingFormatted, "2h 30m")
    }

    func testTimeRemaining_minutesOnly() {
        let state = BatteryState(
            percentage: 90, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: 45, timeToFull: nil
        )
        XCTAssertEqual(state.timeRemainingFormatted, "45m")
    }

    func testTimeRemaining_charging_usesTimeToFull() {
        let state = BatteryState(
            percentage: 50, isCharging: true, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: nil, timeToFull: 60
        )
        XCTAssertEqual(state.timeRemainingFormatted, "1h 0m")
    }

    func testTimeRemaining_nilWhenNegative() {
        let state = BatteryState(
            percentage: 50, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: -1, timeToFull: nil
        )
        XCTAssertNil(state.timeRemainingFormatted)
    }

    func testTimeRemaining_nilWhenUnreasonablyLarge() {
        let state = BatteryState(
            percentage: 50, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: 7000, timeToFull: nil
        )
        XCTAssertNil(state.timeRemainingFormatted)
    }

    // MARK: - Power Source

    func testIsOnBattery() {
        let pluggedIn = BatteryState(
            percentage: 50, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertFalse(pluggedIn.isOnBattery)

        let onBattery = BatteryState(
            percentage: 50, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertTrue(onBattery.isOnBattery)
    }
}
