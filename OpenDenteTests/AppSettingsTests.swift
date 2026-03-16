import XCTest
@testable import OpenDente

@MainActor
final class AppSettingsTests: XCTestCase {

    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        settings = AppSettings.shared
    }

    override func tearDown() {
        // Restore defaults
        settings.chargeLimit = 80
        settings.sailingRange = 10
        super.tearDown()
    }

    // MARK: - Charge Limit Validation

    func testChargeLimit_defaultIs80() {
        UserDefaults.standard.removeObject(forKey: "chargeLimit")
        XCTAssertEqual(settings.chargeLimit, 80)
    }

    func testChargeLimit_clampsToMin20() {
        settings.chargeLimit = 5
        XCTAssertEqual(settings.chargeLimit, 20)
    }

    func testChargeLimit_clampsToMax100() {
        settings.chargeLimit = 150
        XCTAssertEqual(settings.chargeLimit, 100)
    }

    func testChargeLimit_acceptsValidValues() {
        for value in [20, 50, 80, 100] {
            settings.chargeLimit = value
            XCTAssertEqual(settings.chargeLimit, value)
        }
    }

    func testChargeLimit_negativeClampsToMin() {
        settings.chargeLimit = -10
        XCTAssertEqual(settings.chargeLimit, 20)
    }

    // MARK: - Sailing Range Validation

    func testSailingRange_defaultIs10() {
        UserDefaults.standard.removeObject(forKey: "sailingRange")
        XCTAssertEqual(settings.sailingRange, 10)
    }

    func testSailingRange_clampsToMin2() {
        settings.sailingRange = 0
        XCTAssertEqual(settings.sailingRange, 2)
    }

    func testSailingRange_clampsToMax25() {
        settings.sailingRange = 50
        XCTAssertEqual(settings.sailingRange, 25)
    }

    // MARK: - Sailing Lower Bound

    func testSailingLowerBound_calculated() {
        settings.chargeLimit = 80
        settings.sailingRange = 10
        XCTAssertEqual(settings.sailingLowerBound, 70)
    }

    func testSailingLowerBound_neverNegative() {
        settings.chargeLimit = 20
        settings.sailingRange = 25
        XCTAssertGreaterThanOrEqual(settings.sailingLowerBound, 0,
            "Sailing lower bound must never be negative")
    }

    func testSailingLowerBound_alwaysLessThanLimit() {
        for limit in stride(from: 20, through: 100, by: 5) {
            settings.chargeLimit = limit
            settings.sailingRange = 10
            XCTAssertLessThan(settings.sailingLowerBound, settings.chargeLimit,
                "Lower bound must be less than limit (limit=\(limit))")
        }
    }
}
