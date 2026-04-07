import Foundation
import IOKit.pwr_mgt
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "SleepAssertion")

/// Protocol for sleep assertion operations. Enables testing without real IOPMAssertion.
@MainActor
protocol SleepAssertionControl: AnyObject {
    func preventSleep(reason: String) -> Bool
    func allowSleep()
    var isPreventingSleep: Bool { get }
}

/// Manages IOPMAssertions to prevent system idle sleep.
/// Used by "Disable Sleep until Charge Limit" feature.
///
/// IOPMAssertions are process-scoped — macOS releases them automatically
/// if the process exits or crashes. Explicit release is still good practice.
@MainActor
final class SleepAssertionManager: SleepAssertionControl {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isPreventingSleep = false

    func preventSleep(reason: String) -> Bool {
        guard !isPreventingSleep else { return true }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            isPreventingSleep = true
            log.notice("Sleep assertion created: \(reason, privacy: .public)")
            return true
        }
        log.error("Failed to create sleep assertion: \(result, privacy: .public)")
        return false
    }

    func allowSleep() {
        guard isPreventingSleep else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isPreventingSleep = false
        log.notice("Sleep assertion released")
    }

    deinit {
        // Safety: release if still held (process exit would also release, but be explicit)
        if isPreventingSleep {
            IOPMAssertionRelease(assertionID)
        }
    }
}
