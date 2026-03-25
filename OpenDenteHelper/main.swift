import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os.log

private let log = Logger(subsystem: HelperConstants.machServiceName, category: "Main")

log.info("OpenDente Helper v\(HelperConstants.helperVersion) starting")

// MARK: - Watchdog + Delegate

// Create the delegate first — it handles SMC and XPC
// Watchdog reset action calls back into the delegate
// nonisolated(unsafe) because these are accessed from C callbacks
nonisolated(unsafe) var delegate: HelperDelegate!
nonisolated(unsafe) var watchdog: Watchdog!
nonisolated(unsafe) var sleepRootPort: io_connect_t = 0

watchdog = Watchdog { delegate.resetChargingDirect() }
delegate = HelperDelegate(watchdog: watchdog)

// MARK: - Crash Recovery (Layer 2)

// If previous instance had charging inhibited (crash), reset immediately
if HelperState.wasChargingInhibited() {
    log.warning("Previous instance had charging inhibited — resetting to safe defaults")
    delegate.resetChargingDirect()
}

// MARK: - Signal Handlers (Layer 1)

// Use DispatchSource for safe signal handling (allows Foundation/SMC calls)
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    log.info("SIGTERM received — resetting charging to safe defaults")
    delegate.resetChargingDirect()
    watchdog.stop()
    log.info("Helper exiting cleanly")
    exit(0)
}
sigtermSource.resume()

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    log.info("SIGINT received — resetting charging to safe defaults")
    delegate.resetChargingDirect()
    watchdog.stop()
    log.info("Helper exiting cleanly")
    exit(0)
}
sigintSource.resume()

// MARK: - Sleep/Wake Notifications (IOKit)

// Daemons can't use NSWorkspace — use IORegisterForSystemPower instead
var notifyPortRef: IONotificationPortRef?
var notifierObject: io_object_t = 0

func sleepWakeCallback(
    refCon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) {
    switch messageType {
    case 0xe0000240, // kIOMessageCanSystemSleep (idle sleep)
         0xe0000280: // kIOMessageSystemWillSleep (forced sleep)
        log.info("System will sleep — suspending watchdog")
        watchdog.suspend()
        // Defense-in-depth: inhibit charging if app synced the setting.
        // Runs in kernel power transition context — fires even if app's XPC
        // call didn't complete before macOS suspended the app process.
        delegate.inhibitChargingOnSleep()
        // Allow sleep to proceed
        let arg = Int(Int(bitPattern: messageArgument))
        IOAllowPowerChange(sleepRootPort, arg)

    case 0xe0000300: // kIOMessageSystemHasPoweredOn
        log.info("System woke up — resuming watchdog")
        watchdog.resume()

    default:
        break
    }
}

sleepRootPort = IORegisterForSystemPower(nil, &notifyPortRef, sleepWakeCallback, &notifierObject)
if sleepRootPort == 0 {
    log.error("Failed to register for sleep/wake notifications")
} else if let port = notifyPortRef {
    // Use dispatch queue instead of CFRunLoop (compatible with dispatchMain())
    IONotificationPortSetDispatchQueue(port, .main)
    log.info("Registered for sleep/wake notifications")
}

// MARK: - XPC Listener

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
log.info("XPC listener started on \(HelperConstants.machServiceName)")

// Start the watchdog
watchdog.start()

// MARK: - Run

dispatchMain()
