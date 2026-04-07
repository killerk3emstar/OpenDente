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

    /// Whether this Mac has a MagSafe LED controllable via ACLC
    private var hasMagSafeLED = false

    /// Whether any XPC client is currently connected (accessed under lock)
    private var hasActiveClient = false

    /// Synced from app — if true, helper inhibits charging independently on sleep.
    /// Accessed under lock (written by XPC, read by IOKit sleep callback).
    private var stopChargingWhenSleeping = false

    /// LED color to set when inhibiting charging on sleep (0xFF = don't touch LED).
    /// Synced from app alongside stopChargingWhenSleeping.
    private var sleepLEDColor: UInt8 = 0xFF

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
            log.error("Failed to open SMC: \(error.localizedDescription, privacy: .public)")
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

        // Check for MagSafe LED control (not all Macs have MagSafe)
        hasMagSafeLED = smc.keyExists("ACLC")
        log.info("MagSafe LED (ACLC): \(self.hasMagSafeLED ? "available" : "not found", privacy: .public)")

        // Diagnostic: log all charging-related key availability with current values
        let diagnosticKeys = ["CHTE", "CHIE", "CH0B", "CH0C", "CH0I", "CH0J", "ACLC"]
        for key in diagnosticKeys {
            if let info = smc.keyInfo(key) {
                if let value = smc.readKeyOptional(key) {
                    let hex = hexString(value.bytes)
                    log.info("SMC key \(key, privacy: .public): type=\(info.type, privacy: .public) size=\(info.size, privacy: .public) value=[\(hex, privacy: .public)]")
                } else {
                    log.info("SMC key \(key, privacy: .public): type=\(info.type, privacy: .public) size=\(info.size, privacy: .public) value=<unreadable>")
                }
            } else {
                log.info("SMC key \(key, privacy: .public): not found")
            }
        }
    }

    // MARK: - Verification

    /// Format bytes array as hex string for logging (e.g. "01 00 00 00")
    private func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Read back the charging key after a write to confirm it took effect.
    /// `expected` = true means we expect charging to be inhibited.
    private func verifyChargingKey(expected inhibited: Bool) {
        switch chargingAPI {
        case .legacy:
            if let val = smc.readKeyOptional("CH0B") {
                let allHex = hexString(val.bytes)
                let byte = val.uint8Value ?? 0
                let ok = inhibited ? (byte == 0x02) : (byte == 0x00)
                if ok {
                    log.info("CH0B readback OK: [\(allHex, privacy: .public)]")
                } else {
                    let expected = inhibited ? "02" : "00"
                    log.error("CH0B readback MISMATCH: [\(allHex, privacy: .public)], expected [\(expected, privacy: .public)]")
                }
            } else {
                log.warning("CH0B readback failed: key not readable")
            }
        case .tahoe:
            if let val = smc.readKeyOptional("CHTE") {
                let allHex = hexString(val.bytes)
                let byte0 = val.uint8Value ?? 0xFF
                let ok = inhibited ? (byte0 == 0x01) : (byte0 == 0x00)
                if ok {
                    log.info("CHTE readback OK: [\(allHex, privacy: .public)]")
                } else {
                    let expected = inhibited ? "01 00 00 00" : "00 00 00 00"
                    log.error("CHTE readback MISMATCH: [\(allHex, privacy: .public)], expected [\(expected, privacy: .public)]")
                }
            } else {
                log.warning("CHTE readback failed: key not readable")
            }
        case .unknown:
            break
        }
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        log.info("shouldAcceptNewConnection from pid \(connection.processIdentifier, privacy: .public)")

        // Verify the caller is our app
        guard verifyCaller(connection) else {
            log.warning("REJECTED connection from pid \(connection.processIdentifier, privacy: .public)")
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self

        connection.invalidationHandler = { [weak self] in
            log.info("XPC connection invalidated (app quit or crashed)")
            self?.handleClientDisconnect()
        }

        connection.interruptionHandler = {
            log.info("XPC connection interrupted (transient)")
        }

        connection.resume()
        lock.lock()
        hasActiveClient = true
        lock.unlock()
        watchdog.receivedHeartbeat()
        log.info("ACCEPTED connection from pid \(connection.processIdentifier, privacy: .public)")
        return true
    }

    // MARK: - Caller Verification

    private func verifyCaller(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier

        #if DEBUG
        // In debug builds, skip SecCode verification — Xcode debug signing
        // doesn't always pass identifier checks reliably.
        log.debug("DEBUG: accepting connection from pid \(pid, privacy: .public) without SecCode check")
        return true
        #else
        // Production: code signature verification
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let secCode = code else {
            log.error("Failed to get SecCode for pid \(pid, privacy: .public)")
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
            log.warning("Caller verification failed for pid \(pid, privacy: .public): \(result, privacy: .public)")
            return false
        }
        return true
        #endif
    }

    // MARK: - Client Disconnect

    private func handleClientDisconnect() {
        lock.lock()
        let state = HelperState.read()
        hasActiveClient = false
        lock.unlock()

        log.info("Client disconnected (last state: \(state?.rawValue ?? "none", privacy: .public))")

        // If charging was inhibited when the app disconnected, reset immediately
        if state == .inhibited {
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
                log.info("Writing CH0B: [00], CH0C: [00]")
                try smc.writeKey("CH0B", bytes: [0x00])
                try smc.writeKey("CH0C", bytes: [0x00])
            case .tahoe:
                log.info("Writing CHTE: [00 00 00 00]")
                try smc.writeKey("CHTE", bytes: [0x00, 0x00, 0x00, 0x00])
            case .unknown:
                break
            }
            verifyChargingKey(expected: false)
            HelperState.write(.normal)
            log.info("Charging enabled")
            reply(true, nil)
        } catch {
            log.error("Failed to enable charging: \(error.localizedDescription, privacy: .public)")
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
                log.info("Writing CH0B: [02], CH0C: [02]")
                try smc.writeKey("CH0B", bytes: [0x02])
                try smc.writeKey("CH0C", bytes: [0x02])
            case .tahoe:
                log.info("Writing CHTE: [01 00 00 00]")
                try smc.writeKey("CHTE", bytes: [0x01, 0x00, 0x00, 0x00])
            case .unknown:
                break
            }
            // Read-back verification: confirm the write took effect
            verifyChargingKey(expected: true)
            HelperState.write(.inhibited)
            log.info("Charging inhibited")
            reply(true, nil)
        } catch {
            log.error("Failed to inhibit charging: \(error.localizedDescription, privacy: .public)")
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
                let byte: UInt8 = enable ? 0x01 : 0x00
                log.info("Writing CH0I: [\(self.hexString([byte]), privacy: .public)]")
                try smc.writeKey("CH0I", bytes: [byte])
            case .tahoe:
                let byte: UInt8 = enable ? 0x08 : 0x00
                log.info("Writing CHIE: [\(self.hexString([byte]), privacy: .public)]")
                try smc.writeKey("CHIE", bytes: [byte])
            case .unknown:
                break
            }
            if enable {
                // Enabling discharge — also inhibit charging
                switch chargingAPI {
                case .legacy:
                    log.info("Writing CH0B: [02], CH0C: [02] (discharge + inhibit)")
                    try smc.writeKey("CH0B", bytes: [0x02])
                    try smc.writeKey("CH0C", bytes: [0x02])
                case .tahoe:
                    log.info("Writing CHTE: [01 00 00 00] (discharge + inhibit)")
                    try smc.writeKey("CHTE", bytes: [0x01, 0x00, 0x00, 0x00])
                case .unknown:
                    break
                }
                HelperState.write(.inhibited)
            }
            // Disabling discharge: only the discharge key is toggled (above).
            // Charging keys are left as-is — ChargingManager's evaluateState
            // sends enableCharging() or inhibitCharging() immediately after,
            // avoiding a wasted enable→inhibit round-trip at the charge limit.
            log.info("Force discharge: \(enable, privacy: .public)")
            reply(true, nil)
        } catch {
            log.error("Failed to set discharge: \(error.localizedDescription, privacy: .public)")
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

    func syncSleepSettings(stopChargingWhenSleeping: Bool, sleepLEDColor: UInt8, reply: @escaping (Bool) -> Void) {
        lock.lock()
        self.stopChargingWhenSleeping = stopChargingWhenSleeping
        self.sleepLEDColor = sleepLEDColor
        lock.unlock()
        let hex = String(sleepLEDColor, radix: 16, uppercase: true)
        log.info("Sleep settings synced: stopChargingWhenSleeping=\(stopChargingWhenSleeping, privacy: .public), sleepLED=0x\(hex, privacy: .public)")
        reply(true)
    }

    func setMagSafeLED(color: UInt8, reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard hasMagSafeLED else {
            reply(false, "No MagSafe LED (ACLC key not found)")
            return
        }

        do {
            try smc.writeKey("ACLC", bytes: [color])
            let hex = String(color, radix: 16, uppercase: true)
            log.info("MagSafe LED set to 0x\(hex, privacy: .public)")
            reply(true, nil)
        } catch {
            log.error("Failed to set MagSafe LED: \(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - Sleep Defense-in-Depth

    /// Called from IOKit sleep callback. If the app synced stopChargingWhenSleeping=true,
    /// inhibit charging independently — backup in case app's XPC call didn't complete
    /// before macOS suspended the app process.
    func inhibitChargingOnSleep() {
        lock.lock()
        let sleepSetting = stopChargingWhenSleeping
        let api = chargingAPI
        let ledColor = sleepLEDColor
        let hasLED = hasMagSafeLED
        lock.unlock()

        guard sleepSetting && api != .unknown else {
            log.info("Sleep callback: skipped (stopChargingWhenSleeping=\(sleepSetting, privacy: .public), api=\(String(describing: api), privacy: .public))")
            return
        }

        lock.lock()
        defer { lock.unlock() }

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
            // Update LED to reflect inhibited state (visible with lid closed).
            // 0xFF = don't touch LED (controlMagSafeLED is off).
            if hasLED && ledColor != 0xFF {
                try smc.writeKey("ACLC", bytes: [ledColor])
                let hex = String(ledColor, radix: 16, uppercase: true)
                log.info("Sleep callback: LED set to 0x\(hex, privacy: .public)")
            }
            HelperState.write(.inhibited)
            log.info("Sleep callback: inhibited charging (defense-in-depth)")
        } catch {
            log.error("Sleep callback: failed to inhibit charging: \(error.localizedDescription, privacy: .public)")
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

            // Reset MagSafe LED to system default if available
            if hasMagSafeLED {
                try smc.writeKey("ACLC", bytes: [HelperConstants.ledAuto])
            }

            HelperState.clear()
            log.info("Reset to defaults (charging enabled, discharge off, LED default)")
        } catch {
            log.error("Failed to reset to defaults: \(error.localizedDescription, privacy: .public)")
        }
    }
}
