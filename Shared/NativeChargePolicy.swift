import Foundation

enum NativeChargePolicy {
    static func supportedLimits() -> [Int] {
        guard let client = ODNativeChargeClient.makeClient(), let values = try? client.limits() else { return [] }
        return values.map(\.intValue).sorted()
    }

    static func nearestLimit(_ requested: Int, supported: [Int]) -> Int? {
        supported.min { abs($0 - requested) == abs($1 - requested) ? $0 < $1 : abs($0 - requested) < abs($1 - requested) }
    }
}
