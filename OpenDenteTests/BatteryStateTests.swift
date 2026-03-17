import XCTest
@testable import OpenDente

final class BatteryStateTests: XCTestCase {

    // MARK: - Health Percentage

    func testHealthPercentage_normalBattery() {
        let state = BatteryState(
            percentage: 80, hardwarePercentage: nil, isCharging: false, isPluggedIn: true,
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
            percentage: 100, hardwarePercentage: nil, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: 5100, designCapacity: 5000, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertEqual(state.healthPercentage!, 102.0, accuracy: 0.1)
    }

    func testHealthPercentage_nilWhenMissingData() {
        let state = BatteryState(
            percentage: 50, hardwarePercentage: nil, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertNil(state.healthPercentage)
    }

    func testHealthPercentage_nilWhenDesignCapacityZero() {
        let state = BatteryState(
            percentage: 50, hardwarePercentage: nil, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: 5000, designCapacity: 0, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertNil(state.healthPercentage)
    }

    // MARK: - Power Source

    // MARK: - Effective Percentage

    func testEffectivePercentage_usesHardwareWhenEnabled() {
        let state = makeBatteryState(percentage: 78, hardwarePercentage: 81)
        XCTAssertEqual(state.effectivePercentage(useHardware: true), 81)
    }

    func testEffectivePercentage_fallsBackWhenHardwareNil() {
        let state = makeBatteryState(percentage: 78, hardwarePercentage: nil)
        XCTAssertEqual(state.effectivePercentage(useHardware: true), 78)
    }

    func testEffectivePercentage_usesMacOSWhenDisabled() {
        let state = makeBatteryState(percentage: 78, hardwarePercentage: 81)
        XCTAssertEqual(state.effectivePercentage(useHardware: false), 78)
    }

    // MARK: - Power Source

    func testIsOnBattery() {
        let pluggedIn = BatteryState(
            percentage: 50, hardwarePercentage: nil, isCharging: false, isPluggedIn: true,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertFalse(pluggedIn.isOnBattery)

        let onBattery = BatteryState(
            percentage: 50, hardwarePercentage: nil, isCharging: false, isPluggedIn: false,
            currentCapacity: nil, maxCapacity: nil, designCapacity: nil, cycleCount: nil,
            temperature: nil, voltage: nil, amperage: nil,
            systemPower: nil, adapterPower: nil, batteryPower: nil,
            timeToEmpty: nil, timeToFull: nil
        )
        XCTAssertTrue(onBattery.isOnBattery)
    }
}
