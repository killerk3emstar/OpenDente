import XCTest
@testable import OpenDente

private final class FakeNativeBackend: NativeChargeBackend {
    var state = NativeChargeSnapshot(limit: 90, enabled: true)
    var failRestore = false
    var ignoreApply = false
    func snapshot() throws -> NativeChargeSnapshot { state }
    func apply(_ limit: Int) throws {
        if !ignoreApply { state = NativeChargeSnapshot(limit: limit, enabled: limit != 100) }
    }
    func restore(_ snapshot: NativeChargeSnapshot) throws {
        if failRestore { throw NativeChargeSession.Failure.verificationFailed }
        state = snapshot
    }
}

final class NativeChargeSessionTests: XCTestCase {
    private var directory: URL!
    private var backend: FakeNativeBackend!
    private var session: NativeChargeSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        backend = FakeNativeBackend()
        session = NativeChargeSession(backend: backend, recoveryURL: directory.appendingPathComponent("original.json"),
            supportedLimits: [80, 85, 90, 95, 100])
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testRepeatedChangesRestoreOriginalAcrossHelperRestart() throws {
        try session.apply(80)
        try session.apply(85)
        let restarted = NativeChargeSession(backend: backend, recoveryURL: session.recoveryURL,
            supportedLimits: session.supportedLimits)
        try restarted.restore()
        XCTAssertEqual(backend.state, NativeChargeSnapshot(limit: 90, enabled: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.recoveryURL.path))
    }

    func testOriginallyDisabledLimitRestoredAfterTopUp() throws {
        backend.state = NativeChargeSnapshot(limit: 95, enabled: false)
        try session.apply(80)
        try session.apply(100)
        XCTAssertFalse(backend.state.enabled)
        try session.restore()
        XCTAssertEqual(backend.state, NativeChargeSnapshot(limit: 95, enabled: false))
    }

    func testUnsupportedLimitNeverChangesNativeSettings() {
        XCTAssertThrowsError(try session.apply(50))
        XCTAssertEqual(backend.state.limit, 90)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.recoveryURL.path))
    }

    func testFailedRestoreKeepsRecoveryFileForRetry() throws {
        try session.apply(80)
        backend.failRestore = true
        XCTAssertThrowsError(try session.restore())
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.recoveryURL.path))
        backend.failRestore = false
        try session.restore()
        XCTAssertEqual(backend.state.limit, 90)
    }

    func testUnacceptedSettingIsReportedAndOriginalRetained() {
        backend.ignoreApply = true
        XCTAssertThrowsError(try session.apply(80))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.recoveryURL.path))
    }

    func testCorruptRecoveryFileDoesNotChangeNativeSettings() throws {
        try Data("invalid".utf8).write(to: session.recoveryURL)
        XCTAssertThrowsError(try session.restore())
        XCTAssertEqual(backend.state.limit, 90)
        XCTAssertThrowsError(try session.apply(80))
        XCTAssertEqual(backend.state.limit, 90)
    }

    func testSnappingUsesOnlyAdvertisedLimits() {
        XCTAssertEqual(NativeChargePolicy.nearestLimit(50, supported: [80, 85, 90, 95, 100]), 80)
        XCTAssertEqual(NativeChargePolicy.nearestLimit(88, supported: [80, 85, 90, 95, 100]), 90)
        XCTAssertNil(NativeChargePolicy.nearestLimit(80, supported: []))
    }

    func testNoChangeWhenOriginalCannotBeSaved() throws {
        let unavailable = directory.appendingPathComponent("missing/original.json")
        let session = NativeChargeSession(backend: backend, recoveryURL: unavailable, supportedLimits: [80, 100])
        XCTAssertThrowsError(try session.apply(80))
        XCTAssertEqual(backend.state, NativeChargeSnapshot(limit: 90, enabled: true))
    }
}

@MainActor
final class NativeChargingManagerTests: XCTestCase {
    private func makeManager() -> (ChargingManager, MockChargingControl, AppSettings) {
        let name = "com.opendente.tests.native.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: name)!)
        let mock = MockChargingControl()
        let manager = ChargingManager(settings: settings, helper: mock, battery: .shared,
            sleepAssertion: MockSleepAssertionControl())
        manager.chargingAPI = .native
        manager.isHelperInstalled = true
        manager.helperVersion = "1.4.0"
        manager.nativeSupportedLimits = [80, 85, 90, 95, 100]
        settings.controlMagSafeLED = false
        return (manager, mock, settings)
    }

    func testNativeLimitIsConfiguredOnBatteryWithoutLegacyWrites() async {
        let (manager, mock, _) = makeManager()
        let state = makeBatteryState(percentage: 85, isCharging: false, isPluggedIn: false)
        manager.evaluateState(state)
        await Task.yield()
        manager.evaluateState(state)
        XCTAssertEqual(mock.calls, [.setNativeChargeLimit(80)])
        XCTAssertEqual(manager.mode, .onBattery)
    }

    func testNativeModeRejectsManualDischargeAndPause() {
        let (manager, mock, _) = makeManager()
        manager.startDischarge()
        manager.pauseCharging()
        XCTAssertTrue(mock.calls.isEmpty)
        XCTAssertFalse(PopoverView.canDischarge(isPluggedIn: true, percentage: 90, chargeLimit: 80,
            isHelperInstalled: true, chargingAPI: .native))
    }

    func testTopUpDisablesLimitThenRestoresConfiguredTarget() async {
        let (manager, mock, _) = makeManager()
        let state = makeBatteryState(percentage: 90, isPluggedIn: true)
        manager.mode = .topUp
        manager.evaluateState(state)
        await Task.yield()
        manager.evaluateState(state)
        XCTAssertEqual(manager.mode, .topUp)
        XCTAssertEqual(mock.calls, [.setNativeChargeLimit(100)])
        manager.mode = .idle
        manager.evaluateState(state)
        await Task.yield()
        manager.evaluateState(state)
        XCTAssertEqual(mock.calls, [.setNativeChargeLimit(100), .setNativeChargeLimit(80)])
        XCTAssertEqual(manager.mode, .paused)
    }

    func testNativeFailureIsVisible() async {
        let (manager, mock, _) = makeManager()
        mock.shouldFail = true
        manager.evaluateState(makeBatteryState(percentage: 85))
        await Task.yield()
        XCTAssertEqual(manager.nativeControlError, "mock failure")
        XCTAssertEqual(manager.mode, .idle)
    }

    func testOldHelperDoesNotReceiveNewProtocolMethod() {
        let (manager, mock, _) = makeManager()
        manager.helperVersion = "1.3.0"
        manager.evaluateState(makeBatteryState(percentage: 85, isPluggedIn: true))
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testUnsupportedSavedTargetIsNotSilentlyApplied() {
        let (manager, mock, settings) = makeManager()
        settings.chargeLimit = 50
        manager.evaluateState(makeBatteryState(percentage: 85, isPluggedIn: true))
        XCTAssertTrue(mock.calls.isEmpty)
        XCTAssertNotNil(manager.nativeControlError)
        manager.setChargeLimit(50)
        XCTAssertEqual(settings.chargeLimit, 80)
    }

    func testSleepDoesNotIssueLegacyInhibitInNativeMode() {
        let (manager, mock, settings) = makeManager()
        settings.stopChargingWhenSleeping = true
        manager.mode = .charging
        mock.clearCalls()
        manager.handleWillSleep()
        XCTAssertTrue(mock.calls.isEmpty)
    }
}
