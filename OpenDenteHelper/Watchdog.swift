import Foundation
import os.log

private let log = Logger(subsystem: HelperConstants.machServiceName, category: "Watchdog")

/// Heartbeat watchdog timer. If the app doesn't send a heartbeat within the
/// timeout window and charging is inhibited, the helper resets to safe defaults.
///
/// The watchdog is suspended during system sleep to prevent false triggers.
/// Primary crash detection is via NSXPCConnection.invalidationHandler (instant).
/// This watchdog is a secondary backup.
final class Watchdog {
    private var timer: DispatchSourceTimer?
    private var lastHeartbeat: Date = Date()
    private var isSuspended = false
    private let queue = DispatchQueue(label: "com.opendente.helper.watchdog")
    private let resetAction: () -> Void

    init(resetAction: @escaping () -> Void) {
        self.resetAction = resetAction
    }

    deinit {
        // DispatchSourceTimer crashes if deallocated while suspended.
        // Resume before cancel to prevent "BUG IN CLIENT OF LIBDISPATCH".
        if isSuspended {
            timer?.resume()
        }
        timer?.cancel()
        timer = nil
    }

    /// Start the watchdog timer
    func start() {
        queue.async { [weak self] in
            self?.startTimer()
        }
    }

    /// Record a heartbeat from the app
    func receivedHeartbeat() {
        queue.async { [weak self] in
            self?.lastHeartbeat = Date()
            log.debug("Heartbeat received")
        }
    }

    /// Suspend the watchdog (e.g. during system sleep)
    func suspend() {
        queue.async { [weak self] in
            guard let self, !self.isSuspended else { return }
            self.isSuspended = true
            self.timer?.suspend()
            log.info("Watchdog suspended")
        }
    }

    /// Resume the watchdog (e.g. after system wake)
    func resume() {
        queue.async { [weak self] in
            guard let self, self.isSuspended else { return }
            self.isSuspended = false
            self.lastHeartbeat = Date() // Reset so we don't immediately fire
            self.timer?.resume()
            log.info("Watchdog resumed")
        }
    }

    /// Stop and clean up the watchdog
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.isSuspended {
                self.timer?.resume() // Must resume before cancelling
            }
            self.timer?.cancel()
            self.timer = nil
            log.info("Watchdog stopped")
        }
    }

    // MARK: - Private

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + HelperConstants.watchdogCheckInterval,
            repeating: HelperConstants.watchdogCheckInterval
        )
        timer.setEventHandler { [weak self] in
            self?.check()
        }
        self.timer = timer
        timer.resume()
        log.info("Watchdog started (timeout: \(HelperConstants.watchdogTimeout)s)")
    }

    private func check() {
        let elapsed = Date().timeIntervalSince(lastHeartbeat)

        if elapsed > 60 {
            log.info("Heartbeat gap: \(Int(elapsed))s since last heartbeat")
        }

        guard elapsed > HelperConstants.watchdogTimeout else { return }
        guard HelperState.wasChargingInhibited() else {
            log.debug("Watchdog: timeout but charging not inhibited, ignoring")
            return
        }

        log.warning("Watchdog fired: no heartbeat for \(Int(elapsed))s, resetting charging")
        resetAction()
    }
}
