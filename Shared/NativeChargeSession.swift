import Foundation

struct NativeChargeSnapshot: Codable, Equatable {
    let limit: Int
    let enabled: Bool
}

protocol NativeChargeBackend {
    func snapshot() throws -> NativeChargeSnapshot
    func apply(_ limit: Int) throws
    func restore(_ snapshot: NativeChargeSnapshot) throws
}

struct PowerUIChargeBackend: NativeChargeBackend {
    let client: ODNativeChargeClient

    func snapshot() throws -> NativeChargeSnapshot {
        let state = try client.state()
        guard let limit = state["limit"]?.intValue, let enabled = state["enabled"]?.boolValue else {
            throw NativeChargeSession.Failure.invalidState
        }
        return NativeChargeSnapshot(limit: limit, enabled: enabled)
    }

    func apply(_ limit: Int) throws { try client.setLimit(limit) }
    func restore(_ snapshot: NativeChargeSnapshot) throws {
        try client.restoreLimit(snapshot.limit, enabled: snapshot.enabled)
    }
}

/// Owned by the helper under its operation lock. Persist before the first change
/// so quit, watchdog recovery, and helper restart restore the user's macOS setting.
final class NativeChargeSession {
    enum Failure: LocalizedError {
        case invalidState, unsupportedLimit, verificationFailed
        var errorDescription: String? {
            switch self {
            case .invalidState: return "Invalid native charge-limit recovery state"
            case .unsupportedLimit: return "This Mac does not support that native charge limit"
            case .verificationFailed: return "macOS did not accept the native charge limit"
            }
        }
    }

    let backend: NativeChargeBackend
    let recoveryURL: URL
    let supportedLimits: [Int]

    init(backend: NativeChargeBackend, recoveryURL: URL, supportedLimits: [Int]) {
        self.backend = backend
        self.recoveryURL = recoveryURL
        self.supportedLimits = supportedLimits
    }

    func apply(_ limit: Int) throws {
        guard supportedLimits.contains(limit) else { throw Failure.unsupportedLimit }
        if !FileManager.default.fileExists(atPath: recoveryURL.path) {
            let original = try backend.snapshot()
            guard (1...100).contains(original.limit) else { throw Failure.invalidState }
            let data = try JSONEncoder().encode(original)
            try data.write(to: recoveryURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryURL.path)
        }
        // A damaged recovery file must never authorize another change.
        let original = try JSONDecoder().decode(NativeChargeSnapshot.self, from: Data(contentsOf: recoveryURL))
        guard (1...100).contains(original.limit) else { throw Failure.invalidState }
        try backend.apply(limit)
        let state = try backend.snapshot()
        guard limit == 100 ? !state.enabled : state.enabled && state.limit == limit else {
            throw Failure.verificationFailed
        }
    }

    func restore() throws {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return }
        let original = try JSONDecoder().decode(NativeChargeSnapshot.self, from: Data(contentsOf: recoveryURL))
        guard (1...100).contains(original.limit) else { throw Failure.invalidState }
        try backend.restore(original)
        guard try backend.snapshot() == original else { throw Failure.verificationFailed }
        try FileManager.default.removeItem(at: recoveryURL)
    }
}
