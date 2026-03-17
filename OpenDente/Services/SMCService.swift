import Foundation
import IOKit
import os.log

private let smcLog = Logger(subsystem: "com.opendente.app", category: "SMC")

// MARK: - SMC Constants

private let kSMCKeySize = 4
private let kSMCReadKey: UInt8 = 5
private let kSMCWriteKey: UInt8 = 6
private let kSMCGetKeyFromIndex: UInt8 = 8
private let kSMCGetKeyInfo: UInt8 = 9
private let kKernelIndexSMC: UInt32 = 2

// MARK: - SMC Data Structures (must match kernel layout, total 80 bytes)

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // Match C struct padding: sizeof(SMCKeyInfoData) == 12 in C due to UInt32 alignment
    private var _pad0: UInt8 = 0
    private var _pad1: UInt8 = 0
    private var _pad2: UInt8 = 0
}

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCParamStruct {
    var key: UInt32 = 0               // 0-3
    var vers: SMCVersion = SMCVersion() // 4-9 (+2 auto-pad = 12)
    var pLimitData: SMCPLimitData = SMCPLimitData() // 12-27
    var keyInfo: SMCKeyInfoData = SMCKeyInfoData()  // 28-39 (12 bytes with padding)
    var result: UInt8 = 0             // 40
    var status: UInt8 = 0             // 41
    var data8: UInt8 = 0              // 42 (+1 auto-pad = 44)
    var data32: UInt32 = 0            // 44-47
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) // 48-79
    // Total: 80 bytes
}

// MARK: - SMC Value Types

/// Represents a value read from SMC
struct SMCValue {
    let key: String
    let dataSize: UInt32
    let dataType: String
    var bytes: [UInt8]

    // NOTE: Apple Silicon SMC stores everything in native LITTLE-ENDIAN byte order

    var uint8Value: UInt8? {
        guard dataSize >= 1 else { return nil }
        return bytes[0]
    }

    var uint16Value: UInt16? {
        guard dataSize >= 2 else { return nil }
        // Little-endian: LSB first (Apple Silicon SMC)
        return UInt16(bytes[1]) << 8 | UInt16(bytes[0])
    }

    /// Big-endian read for keys that use reverse byte order (e.g. B0RM)
    var uint16BigEndian: UInt16? {
        guard dataSize >= 2 else { return nil }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    var int16Value: Int16? {
        guard let u = uint16Value else { return nil }
        return Int16(bitPattern: u)
    }

    var uint32Value: UInt32? {
        guard dataSize >= 4 else { return nil }
        return UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 |
               UInt32(bytes[1]) << 8  | UInt32(bytes[0])
    }

    var int32Value: Int32? {
        guard let u = uint32Value else { return nil }
        return Int32(bitPattern: u)
    }

    /// sp78 = signed 7.8 fixed point (divide Int16 by 256)
    var sp78Value: Double? {
        guard let raw = int16Value else { return nil }
        return Double(raw) / 256.0
    }

    /// sp96 = signed 9.6 fixed point (divide Int16 by 64)
    var sp96Value: Double? {
        guard let raw = int16Value else { return nil }
        return Double(raw) / 64.0
    }

    /// flt = 32-bit IEEE 754 float (little-endian on ARM)
    var floatValue: Float? {
        guard dataSize >= 4 else { return nil }
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 |
                   UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return Float(bitPattern: bits)
    }
}

// MARK: - SMC Errors

enum SMCError: LocalizedError {
    case driverNotFound
    case failedToOpen(kern_return_t)
    case keyNotFound(String)
    case readFailed(String, UInt8)
    case writeFailed(String, UInt8)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .driverNotFound:        return "AppleSMC driver not found"
        case .failedToOpen(let kr):  return "Failed to open SMC connection: \(kr)"
        case .keyNotFound(let key):  return "SMC key not found: \(key)"
        case .readFailed(let key, let code): return "SMC read failed for \(key): result=\(code)"
        case .writeFailed(let key, let code): return "SMC write failed for \(key): result=\(code)"
        case .notConnected:          return "SMC not connected"
        }
    }
}

// MARK: - SMC Service

/// Low-level SMC access via IOKit. Reading works without root. Writing requires root.
final class SMCService: @unchecked Sendable {

    static let shared = SMCService()

    private var connection: io_connect_t = 0
    private var isOpen = false
    private let lock = NSLock()

    deinit {
        close()
    }

    // MARK: - Connection

    func open() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isOpen else { return }

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != IO_OBJECT_NULL else {
            throw SMCError.driverNotFound
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            throw SMCError.failedToOpen(result)
        }
        isOpen = true
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }

        if isOpen {
            IOServiceClose(connection)
            connection = 0
            isOpen = false
        }
    }

    // MARK: - Read

    /// Read an SMC key and return the raw value
    func readKey(_ key: String) throws -> SMCValue {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { throw SMCError.notConnected }

        // Step 1: Get key info (data size and type)
        var input = SMCParamStruct()
        input.key = fourCharCode(from: key)
        input.data8 = kSMCGetKeyInfo

        let output = try callSMC(input: input)
        let dataSize = output.keyInfo.dataSize
        let dataType = output.keyInfo.dataType

        guard dataSize > 0 else {
            throw SMCError.keyNotFound(key)
        }

        // Step 2: Read the actual bytes
        var readInput = SMCParamStruct()
        readInput.key = fourCharCode(from: key)
        readInput.keyInfo.dataSize = dataSize
        readInput.data8 = kSMCReadKey

        let readOutput = try callSMC(input: readInput)

        // Extract bytes from the tuple
        let allBytes = bytesArray(from: readOutput.bytes, count: Int(dataSize))

        return SMCValue(
            key: key,
            dataSize: dataSize,
            dataType: fourCharString(from: dataType),
            bytes: allBytes
        )
    }

    /// Try to read a key, returning nil if it doesn't exist
    func readKeyOptional(_ key: String) -> SMCValue? {
        try? readKey(key)
    }

    // MARK: - Write

    /// Write a value to an SMC key. Requires root privileges.
    func writeKey(_ key: String, bytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { throw SMCError.notConnected }

        // First get key info for the data size
        var infoInput = SMCParamStruct()
        infoInput.key = fourCharCode(from: key)
        infoInput.data8 = kSMCGetKeyInfo
        let infoOutput = try callSMC(input: infoInput)

        // Now write
        var writeInput = SMCParamStruct()
        writeInput.key = fourCharCode(from: key)
        writeInput.keyInfo.dataSize = infoOutput.keyInfo.dataSize
        writeInput.data8 = kSMCWriteKey

        // Copy bytes into the tuple
        writeInput.bytes = bytesToTuple(bytes)

        let writeOutput = try callSMC(input: writeInput)
        if writeOutput.result != 0 {
            throw SMCError.writeFailed(key, writeOutput.result)
        }
    }

    // MARK: - Convenience Readers

    func readUInt8(_ key: String) -> UInt8? {
        readKeyOptional(key)?.uint8Value
    }

    func readUInt16(_ key: String) -> UInt16? {
        readKeyOptional(key)?.uint16Value
    }

    func readInt16(_ key: String) -> Int16? {
        readKeyOptional(key)?.int16Value
    }

    func readUInt32(_ key: String) -> UInt32? {
        readKeyOptional(key)?.uint32Value
    }

    func readInt32(_ key: String) -> Int32? {
        readKeyOptional(key)?.int32Value
    }

    func readSP78(_ key: String) -> Double? {
        readKeyOptional(key)?.sp78Value
    }

    func readSP96(_ key: String) -> Double? {
        readKeyOptional(key)?.sp96Value
    }

    /// Check if a key exists and is readable
    func keyExists(_ key: String) -> Bool {
        readKeyOptional(key) != nil
    }

    // MARK: - Private

    private func callSMC(input: SMCParamStruct) throws -> SMCParamStruct {
        var inputData = input
        var outputData = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let keyStr = fourCharString(from: input.key)

        let result = IOConnectCallStructMethod(
            connection,
            kKernelIndexSMC,
            &inputData,
            inputSize,
            &outputData,
            &outputSize
        )

        if result != KERN_SUCCESS {
            smcLog.error("IOConnectCallStructMethod failed: kern_return=\(result) (0x\(String(result, radix: 16))) key=\(keyStr) cmd=\(input.data8)")
            throw SMCError.readFailed(keyStr, UInt8(result & 0xFF))
        }

        if outputData.result != 0 {
            smcLog.error("SMC result error: result=\(outputData.result) key=\(keyStr) cmd=\(input.data8)")
            throw SMCError.readFailed(keyStr, outputData.result)
        }

        return outputData
    }

    // MARK: - Encoding Helpers

    private func fourCharCode(from string: String) -> UInt32 {
        var code: UInt32 = 0
        for (i, char) in string.utf8.prefix(4).enumerated() {
            code |= UInt32(char) << (24 - i * 8)
        }
        return code
    }

    private func fourCharString(from code: UInt32) -> String {
        let chars: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: chars, encoding: .ascii) ?? "????"
    }

    private func bytesArray(from tuple: SMCBytes, count: Int) -> [UInt8] {
        var t = tuple
        return withUnsafeBytes(of: &t) { ptr in
            Array(ptr.prefix(count))
        }
    }

    private func bytesToTuple(_ bytes: [UInt8]) -> SMCBytes {
        var tuple: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        withUnsafeMutableBytes(of: &tuple) { ptr in
            for (i, byte) in bytes.prefix(32).enumerated() {
                ptr[i] = byte
            }
        }
        return tuple
    }
}
