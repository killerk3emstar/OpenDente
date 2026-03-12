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

    // MARK: - Connection

    /// Establish XPC connection to the helper daemon
    @MainActor
    func connect() {
        let conn = NSXPCConnection(
            machServiceName: HelperConstants.machServiceName,
            options: .privileged
        )
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)

        conn.invalidationHandler = { [weak self] in
            log.info("XPC connection invalidated")
            self?.lock.lock()
            self?.connection = nil
            self?.lock.unlock()
        }

        conn.interruptionHandler = {
            log.warning("XPC connection interrupted (transient)")
        }

        conn.resume()
        lock.lock()
        connection = conn
        lock.unlock()
        startHeartbeat()
        log.info("Connected to helper")
    }

    /// Disconnect from the helper
    @MainActor
    func disconnect() {
        stopHeartbeat()
        lock.lock()
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.invalidate()
        log.info("Disconnected from helper")
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
            helper.suspendWatchdog { _ in }
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

    /// Synchronous reset with timeout — for use during app termination
    nonisolated func resetToDefaultsSync(timeout: TimeInterval = 2.0) {
        let semaphore = DispatchSemaphore(value: 0)
        withProxy { helper in
            helper.resetToDefaults { _, _ in
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    // MARK: - Private

    private func withProxy(block: @escaping (HelperProtocol) -> Void) {
        lock.lock()
        // Auto-reconnect if connection was invalidated (helper restart)
        if connection == nil {
            let conn = NSXPCConnection(
                machServiceName: HelperConstants.machServiceName,
                options: .privileged
            )
            conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            conn.invalidationHandler = { [weak self] in
                log.info("XPC connection invalidated")
                self?.lock.lock()
                self?.connection = nil
                self?.lock.unlock()
            }
            conn.interruptionHandler = {
                log.warning("XPC connection interrupted (transient)")
            }
            conn.resume()
            connection = conn
            log.info("Auto-reconnected to helper")
        }
        let conn = connection
        lock.unlock()

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
