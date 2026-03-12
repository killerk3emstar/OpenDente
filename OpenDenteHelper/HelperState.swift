import Foundation
import os.log

private let log = Logger(subsystem: HelperConstants.machServiceName, category: "State")

/// Atomic state file for crash recovery.
/// On restart, the helper checks this file — if charging was inhibited when
/// the helper last crashed/exited, it re-enables charging immediately.
enum HelperState {
    private static let dir = HelperConstants.stateDirectory
    private static let path = HelperConstants.stateFilePath

    enum ChargingState: String {
        case normal = "normal"
        case inhibited = "inhibited"
    }

    /// Ensure the state directory exists with root-only permissions (0700)
    static func ensureDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            do {
                try fm.createDirectory(
                    atPath: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                log.info("Created state directory: \(dir)")
            } catch {
                log.error("Failed to create state directory: \(error.localizedDescription)")
            }
        }
    }

    /// Write the current charging state atomically
    static func write(_ state: ChargingState) {
        ensureDirectory()
        do {
            try state.rawValue.write(
                toFile: path,
                atomically: true,
                encoding: .utf8
            )
            log.debug("State written: \(state.rawValue)")
        } catch {
            log.error("Failed to write state: \(error.localizedDescription)")
        }
    }

    /// Read the last known charging state (returns nil if file doesn't exist)
    static func read() -> ChargingState? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return ChargingState(rawValue: contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Check if the helper previously had charging inhibited (crash recovery)
    static func wasChargingInhibited() -> Bool {
        read() == .inhibited
    }

    /// Clear the state file (set to normal)
    static func clear() {
        write(.normal)
    }
}
