import XCTest
@testable import OpenDente

@MainActor
final class PollingIntervalTests: XCTestCase {

    func testPollingInterval_isFixed2s() {
        XCTAssertEqual(BatteryService.pollingInterval, 2)
    }
}
