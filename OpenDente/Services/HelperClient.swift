import Foundation
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "HelperClient")

/// XPC client that communicates with the privileged helper daemon.
/// Not @MainActor — XPC callbacks arrive on background threads.
/// All @Published updates are dispatched to main.
final class HelperClient: @unchecked Sendable {

    static let shared = HelperClient()

    private var connection: NSXPCConnection?
    private var heartbeatTimer: Timer?
    private let lock = NSLock()
    private var isIntentionalDisconnect = false
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 5
    private static let reconnectDelays: [TimeInterval] = [1, 2, 5, 10, 30]

    /// Called when the helper process restarts (after crash/interruption) or after
    /// successful reconnection. ChargingManager uses this to resync charging state.
    var onHelperRestarted: (() -> Void)?

    // MARK: - Connection

    /// Establish XPC connection to the helper daemon.
    /// Safe to call multiple times — disconnects existing connection first.
    @MainActor
    func connect() {
        // Disconnect existing connection to avoid leaking XPC connections
        lock.lock()
        let existing = connection
        connection = nil
        isIntentionalDisconnect = false
        reconnectAttempts = 0
        lock.unlock()
        if existing != nil {
            stopHeartbeat()
            existing?.invalidate()
        }

        let conn = NSXPCConnection(
            machServiceName: HelperConstants.machServiceName,
            options: .privileged
        )
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)

        conn.invalidationHandler = { [weak self] in
            guard let self else { return }
            log.warning("XPC connection invalidated")
            self.lock.lock()
            self.connection = nil
            let intentional = self.isIntentionalDisconnect
            self.lock.unlock()

            guard !intentional else { return }

            // Connection permanently lost — attempt reconnection with backoff.
            // The helper is launchd-managed, so it should restart automatically.
            Task { @MainActor in
                self.stopHeartbeat()
                self.scheduleReconnect()
            }
        }

        conn.interruptionHandler = { [weak self] in
            guard let self else { return }
            // Helper process crashed but launchd will restart it.
            // The NSXPCConnection remains valid — new messages are queued
            // and delivered when the helper comes back.
            // We must resync because the fresh helper lost its in-memory state.
            log.warning("XPC connection interrupted — helper crashed, will auto-reconnect")
            Task { @MainActor in
                self.onHelperRestarted?()
            }
        }

        conn.resume()
        lock.lock()
        connection = conn
        lock.unlock()
        startHeartbeat()
        log.info("Connected to helper")
    }

    /// Disconnect from the helper (intentional — suppresses auto-reconnect)
    @MainActor
    func disconnect() {
        stopHeartbeat()
        lock.lock()
        isIntentionalDisconnect = true
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.invalidate()
        log.info("Disconnected from helper")
    }

    // MARK: - Auto-Reconnect

    @MainActor
    private func scheduleReconnect() {
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            log.error("XPC reconnect failed after \(Self.maxReconnectAttempts) attempts — helper may need reinstallation")
            return
        }

        let delay = Self.reconnectDelays[min(reconnectAttempts, Self.reconnectDelays.count - 1)]
        reconnectAttempts += 1
        log.info("Scheduling XPC reconnect \(self.reconnectAttempts)/\(Self.maxReconnectAttempts) in \(delay)s")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            self.lock.lock()
            let needsReconnect = self.connection == nil && !self.isIntentionalDisconnect
            self.lock.unlock()

            guard needsReconnect else { return }

            log.info("XPC reconnect: attempting...")
            self.connect()
            self.onHelperRestarted?()
        }
    }

    // MARK: - Heartbeat

    @MainActor
    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: HelperConstants.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            self?.sendHeartbeat()
        }
    }

    @MainActor
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    func sendHeartbeat() {
        withProxy { helper in
            helper.heartbeat { success in
                if !success {
                    log.warning("Heartbeat failed")
                }
            }
        }
    }

    // MARK: - Protocol Methods

    func enableCharging(completion: (@Sendable (Bool, String?) -> Void)? = nil) {
        withProxy { helper in
            helper.enableCharging { success, error in
                if let error {
                    log.error("enableCharging failed: \(error)")
                }
                if let completion {
                    DispatchQueue.main.async { completion(success, error) }
                }
            }
        }
    }

    func inhibitCharging(completion: (@Sendable (Bool, String?) -> Void)? = nil) {
        withProxy { helper in
            helper.inhibitCharging { success, error in
                if let error {
                    log.error("inhibitCharging failed: \(error)")
                }
                if let completion {
                    DispatchQueue.main.async { completion(success, error) }
                }
            }
        }
    }

    func forceDischarge(enable: Bool, completion: (@Sendable (Bool, String?) -> Void)? = nil) {
        withProxy { helper in
            helper.forceDischarge(enable: enable) { success, error in
                if let error {
                    log.error("forceDischarge failed: \(error)")
                }
                if let completion {
                    DispatchQueue.main.async { completion(success, error) }
                }
            }
        }
    }

    func resetToDefaults(completion: (@Sendable (Bool, String?) -> Void)? = nil) {
        withProxy { helper in
            helper.resetToDefaults { success, error in
                if let error {
                    log.error("resetToDefaults failed: \(error)")
                }
                if let completion {
                    DispatchQueue.main.async { completion(success, error) }
                }
            }
        }
    }

    func suspendWatchdog() {
        withProxy { helper in
            helper.suspendWatchdog { success in
                if !success {
                    log.warning("suspendWatchdog failed")
                }
            }
        }
    }

    func getVersion(completion: @escaping @Sendable (String) -> Void) {
        withProxy { helper in
            helper.getVersion { version in
                DispatchQueue.main.async { completion(version) }
            }
        }
    }

    func getChargingAPI(completion: @escaping @Sendable (String) -> Void) {
        withProxy { helper in
            helper.getChargingAPI { api in
                DispatchQueue.main.async { completion(api) }
            }
        }
    }

    func syncSleepSettings(stopChargingWhenSleeping: Bool, sleepLEDColor: UInt8) {
        withProxy { helper in
            helper.syncSleepSettings(stopChargingWhenSleeping: stopChargingWhenSleeping, sleepLEDColor: sleepLEDColor) { success in
                if !success {
                    log.warning("syncSleepSettings failed")
                }
            }
        }
    }

    func setMagSafeLED(color: UInt8, completion: (@Sendable (Bool, String?) -> Void)? = nil) {
        withProxy { helper in
            helper.setMagSafeLED(color: color) { success, error in
                if let error {
                    log.debug("setMagSafeLED failed: \(error)")
                }
                if let completion {
                    DispatchQueue.main.async { completion(success, error) }
                }
            }
        }
    }

    /// Synchronous reset with timeout — for use during app termination
    nonisolated func resetToDefaultsSync(timeout: TimeInterval = 2.0) {
        let semaphore = DispatchSemaphore(value: 0)
        withProxy { helper in
            helper.resetToDefaults { _, _ in
                semaphore.signal()
            }
        }
        let result = semaphore.wait(timeout: .now() + timeout)
        if result == .timedOut {
            log.warning("resetToDefaultsSync timed out after \(timeout)s — helper may not have reset")
        }
    }

    // MARK: - Private

    private func withProxy(block: @escaping (HelperProtocol) -> Void) {
        lock.lock()
        let conn = connection
        lock.unlock()

        // No connection — caller must call connect() first via connectToHelper()
        guard let conn else { return }

        let helper = conn.remoteObjectProxyWithErrorHandler { error in
            log.error("XPC proxy error: \(error.localizedDescription)")
        }

        guard let proxy = helper as? HelperProtocol else {
            log.error("Failed to get HelperProtocol proxy")
            return
        }

        block(proxy)
    }
}

