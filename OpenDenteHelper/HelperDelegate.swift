import Foundation
import os.log
import Security

private let log = Logger(subsystem: HelperConstants.machServiceName, category: "Delegate")

/// XPC listener delegate and protocol implementation.
/// Verifies callers via code signing, performs SMC writes, manages state.
final class HelperDelegate: NSObject, NSXPCListenerDelegate, HelperProtocol {

    private let smc = SMCService.shared
    private let watchdog: Watchdog
    private let lock = NSLock()

    /// Detected charging API for this Mac
    private var chargingAPI: SMCChargingAPI = .unknown

    /// Whether any XPC client is currently connected (accessed under lock)
    private var hasActiveClient = false

    init(watchdog: Watchdog) {
        self.watchdog = watchdog
        super.init()
        openSMC()
        detectChargingAPI()
    }

    // MARK: - SMC Setup

    private func openSMC() {
        do {
            try smc.open()
            log.info("SMC connection opened")
        } catch {
            log.error("Failed to open SMC: \(error.localizedDescription)")
        }
    }

    private func detectChargingAPI() {
        if smc.keyExists("CHTE") {
            chargingAPI = .tahoe
            log.info("Detected Tahoe charging API (CHTE/CHIE)")
        } else if smc.keyExists("CH0B") {
            chargingAPI = .legacy
            log.info("Detected legacy charging API (CH0B/CH0C)")
        } else {
            chargingAPI = .unknown
            log.info("No charging control keys detected")
        }
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        NSLog("[HelperDelegate] shouldAcceptNewConnection from pid \(connection.processIdentifier)")

        // Verify the caller is our app
        guard verifyCaller(connection) else {
            NSLog("[HelperDelegate] REJECTED connection from pid \(connection.processIdentifier)")
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self

        connection.invalidationHandler = { [weak self] in
            NSLog("[HelperDelegate] XPC connection invalidated (app quit or crashed)")
            self?.handleClientDisconnect()
        }

        connection.interruptionHandler = {
            NSLog("[HelperDelegate] XPC connection interrupted (transient)")
        }

        connection.resume()
        lock.lock()
        hasActiveClient = true
        lock.unlock()
        watchdog.receivedHeartbeat()
        NSLog("[HelperDelegate] ACCEPTED connection from pid \(connection.processIdentifier)")
        return true
    }

    // MARK: - Caller Verification

    private func verifyCaller(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier

        #if DEBUG
        // In debug builds, skip SecCode verification — Xcode debug signing
        // doesn't always pass identifier checks reliably.
        NSLog("[HelperDelegate] DEBUG: accepting connection from pid \(pid) without SecCode check")
        return true
        #else
        // Production: code signature verification
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let secCode = code else {
            log.error("Failed to get SecCode for pid \(pid)")
            return false
        }

        // For distribution, add team ID: and anchor apple generic and certificate leaf[subject.CN] = "Developer ID Application: ..."
        let requirementStr = "identifier \"\(HelperConstants.appBundleID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementStr as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else {
            log.error("Failed to create security requirement")
            return false
        }

        let result = SecCodeCheckValidity(secCode, [], req)
        if result != errSecSuccess {
            log.warning("Caller verification failed for pid \(pid): \(result)")
            return false
        }
        return true
        #endif
    }

    // MARK: - Client Disconnect

    private func handleClientDisconnect() {
        lock.lock()
        hasActiveClient = false
        lock.unlock()

        // If charging was inhibited when the app disconnected, reset immediately
        if HelperState.wasChargingInhibited() {
            log.warning("Client disconnected while charging inhibited — resetting to safe defaults")
            resetChargingDirect()
        }
    }

    // MARK: - HelperProtocol

    func enableCharging(reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard chargingAPI != .unknown else {
            reply(false, "No charging API detected")
            return
        }

        do {
            switch chargingAPI {
            case .legacy:
                try smc.writeKey("CH0B", bytes: [0x00])
                try smc.writeKey("CH0C", bytes: [0x00])
            case .tahoe:
                try smc.writeKey("CHTE", bytes: [0x00, 0x00, 0x00, 0x00])
            case .unknown:
                break
            }
            HelperState.write(.normal)
            log.info("Charging enabled")
            reply(true, nil)
        } catch {
            log.error("Failed to enable charging: \(error.localizedDescription)")
            reply(false, error.localizedDescription)
        }
    }

    func inhibitCharging(reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard chargingAPI != .unknown else {
            reply(false, "No charging API detected")
            return
        }

        do {
            switch chargingAPI {
            case .legacy:
                try smc.writeKey("CH0B", bytes: [0x02])
                try smc.writeKey("CH0C", bytes: [0x02])
            case .tahoe:
                try smc.writeKey("CHTE", bytes: [0x01, 0x00, 0x00, 0x00])
            case .unknown:
                break
            }
            HelperState.write(.inhibited)
            log.info("Charging inhibited")
            reply(true, nil)
        } catch {
            log.error("Failed to inhibit charging: \(error.localizedDescription)")
            reply(false, error.localizedDescription)
        }
    }

    func forceDischarge(enable: Bool, reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard chargingAPI != .unknown else {
            reply(false, "No charging API detected")
            return
        }

        do {
            switch chargingAPI {
            case .legacy:
                try smc.writeKey("CH0I", bytes: [enable ? 0x01 : 0x00])
            case .tahoe:
                try smc.writeKey("CHIE", bytes: [enable ? 0x08 : 0x00])
            case .unknown:
                break
            }
            // If enabling discharge, also inhibit charging
            if enable {
                switch chargingAPI {
                case .legacy:
                    try smc.writeKey("CH0B", bytes: [0x02])
                    try smc.writeKey("CH0C", bytes: [0x02])
                case .tahoe:
                    try smc.writeKey("CHTE", bytes: [0x01, 0x00, 0x00, 0x00])
                case .unknown:
                    break
                }
                HelperState.write(.inhibited)
            } else {
                // Discharge stopped — clear inhibited state so crash recovery
                // doesn't do an unnecessary reset
                HelperState.write(.normal)
            }
            log.info("Force discharge: \(enable)")
            reply(true, nil)
        } catch {
            log.error("Failed to set discharge: \(error.localizedDescription)")
            reply(false, error.localizedDescription)
        }
    }

    func resetToDefaults(reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        resetChargingDirectLocked()
        reply(true, nil)
    }

    func heartbeat(reply: @escaping (Bool) -> Void) {
        watchdog.receivedHeartbeat()
        reply(true)
    }

    func suspendWatchdog(reply: @escaping (Bool) -> Void) {
        watchdog.suspend()
        reply(true)
    }

    func getVersion(reply: @escaping (String) -> Void) {
        reply(HelperConstants.helperVersion)
    }

    func getChargingAPI(reply: @escaping (String) -> Void) {
        switch chargingAPI {
        case .legacy:  reply("legacy")
        case .tahoe:   reply("tahoe")
        case .unknown: reply("unknown")
        }
    }

    // MARK: - Direct Reset (for signal handlers and crash recovery)

    /// Reset charging without going through XPC. Used by signal handlers and crash recovery.
    /// Acquires its own lock.
    func resetChargingDirect() {
        lock.lock()
        defer { lock.unlock() }
        resetChargingDirectLocked()
    }

    /// Reset charging — caller must already hold lock
    private func resetChargingDirectLocked() {
        guard chargingAPI != .unknown else { return }

        do {
            // Stop discharge
            switch chargingAPI {
            case .legacy:
                try smc.writeKey("CH0I", bytes: [0x00])
            case .tahoe:
                try smc.writeKey("CHIE", bytes: [0x00])
            case .unknown:
                break
            }

            // Enable charging
            switch chargingAPI {
            case .legacy:
                try smc.writeKey("CH0B", bytes: [0x00])
                try smc.writeKey("CH0C", bytes: [0x00])
            case .tahoe:
                try smc.writeKey("CHTE", bytes: [0x00, 0x00, 0x00, 0x00])
            case .unknown:
                break
            }

            HelperState.clear()
            log.info("Reset to defaults (charging enabled, discharge off)")
        } catch {
            log.error("Failed to reset to defaults: \(error.localizedDescription)")
        }
    }
}
