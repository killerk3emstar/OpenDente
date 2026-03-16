import XCTest
@testable import OpenDente

/// Tests for SMCValue byte-to-value conversions.
/// These are critical — wrong conversions mean wrong temperature/power readings,
/// which could lead to incorrect charging decisions.
final class SMCValueTests: XCTestCase {

    // MARK: - sp78 (signed 7.8 fixed point, divide Int16 by 256)
    // Used for: system power (PSTR), temperatures on some Macs

    func testSP78_zeroDegreesIsZero() {
        let val = makeValue(dataType: "sp78", bytes: [0x00, 0x00])
        XCTAssertEqual(val.sp78Value, 0.0)
    }

    func testSP78_positiveTemperature() {
        // 25.5°C = 25.5 * 256 = 6528 = 0x1980
        // Little-endian: [0x80, 0x19]
        let val = makeValue(dataType: "sp78", bytes: [0x80, 0x19])
        XCTAssertEqual(val.sp78Value!, 25.5, accuracy: 0.01)
    }

    func testSP78_negativeValue() {
        // -1.0 = -256 as Int16 = 0xFF00
        // Little-endian: [0x00, 0xFF]
        let val = makeValue(dataType: "sp78", bytes: [0x00, 0xFF])
        XCTAssertEqual(val.sp78Value!, -1.0, accuracy: 0.01)
    }

    func testSP78_fractionalPrecision() {
        // 0.5°C = 128 = 0x0080
        // Little-endian: [0x80, 0x00]
        let val = makeValue(dataType: "sp78", bytes: [0x80, 0x00])
        XCTAssertEqual(val.sp78Value!, 0.5, accuracy: 0.01)
    }

    func testSP78_tooFewBytes() {
        let val = makeValue(dataType: "sp78", bytes: [0x80], dataSize: 1)
        XCTAssertNil(val.sp78Value)
    }

    // MARK: - sp96 (signed 9.6 fixed point, divide Int16 by 64)
    // Used for: DC-in/adapter power (PDTR)

    func testSP96_zeroPowerIsZero() {
        let val = makeValue(dataType: "sp96", bytes: [0x00, 0x00])
        XCTAssertEqual(val.sp96Value, 0.0)
    }

    func testSP96_typicalAdapterPower() {
        // 67W adapter: 67.0 * 64 = 4288 = 0x10C0
        // Little-endian: [0xC0, 0x10]
        let val = makeValue(dataType: "sp96", bytes: [0xC0, 0x10])
        XCTAssertEqual(val.sp96Value!, 67.0, accuracy: 0.1)
    }

    func testSP96_negativePower() {
        // -5.0W = -320 as Int16 = 0xFEC0
        // Little-endian: [0xC0, 0xFE]
        let val = makeValue(dataType: "sp96", bytes: [0xC0, 0xFE])
        XCTAssertEqual(val.sp96Value!, -5.0, accuracy: 0.1)
    }

    // MARK: - Float (32-bit IEEE 754, little-endian on ARM)
    // Used for: temperatures (TB0T on Apple Silicon)

    func testFloat_roomTemperature() {
        let expected: Float = 35.0
        let bits = expected.bitPattern
        let bytes = bitsToLE(bits)
        let val = makeValue(dataType: "flt ", bytes: bytes, dataSize: 4)
        XCTAssertEqual(val.floatValue!, expected, accuracy: 0.001)
    }

    func testFloat_bodyTemperature() {
        let expected: Float = 36.6
        let bits = expected.bitPattern
        let bytes = bitsToLE(bits)
        let val = makeValue(dataType: "flt ", bytes: bytes, dataSize: 4)
        XCTAssertEqual(val.floatValue!, expected, accuracy: 0.01)
    }

    func testFloat_zero() {
        let val = makeValue(dataType: "flt ", bytes: [0, 0, 0, 0], dataSize: 4)
        XCTAssertEqual(val.floatValue!, 0.0, accuracy: 0.001)
    }

    func testFloat_tooFewBytes() {
        let val = makeValue(dataType: "flt ", bytes: [0, 0, 0], dataSize: 3)
        XCTAssertNil(val.floatValue)
    }

    // MARK: - UInt16 (little-endian)
    // Used for: voltage (B0AV), cycle count (B0CT), capacity

    func testUInt16_typicalVoltageRaw() {
        // 12543mV = 0x30FF → LE: [0xFF, 0x30]
        let val = makeValue(dataType: "ui16", bytes: [0xFF, 0x30])
        XCTAssertEqual(val.uint16Value, 0x30FF)
    }

    func testUInt16_zero() {
        let val = makeValue(dataType: "ui16", bytes: [0x00, 0x00])
        XCTAssertEqual(val.uint16Value, 0)
    }

    func testUInt16_maxValue() {
        let val = makeValue(dataType: "ui16", bytes: [0xFF, 0xFF])
        XCTAssertEqual(val.uint16Value, 65535)
    }

    // MARK: - Int16 (little-endian, signed)
    // Used for: amperage (B0AC)

    func testInt16_positiveCharging() {
        // +1500mA = 0x05DC → LE: [0xDC, 0x05]
        let val = makeValue(dataType: "si16", bytes: [0xDC, 0x05])
        XCTAssertEqual(val.int16Value, 1500)
    }

    func testInt16_negativeDischarging() {
        // -1500mA = 0xFA24 (two's complement) → LE: [0x24, 0xFA]
        let raw = Int16(-1500)
        let u = UInt16(bitPattern: raw)
        let bytes: [UInt8] = [UInt8(u & 0xFF), UInt8(u >> 8)]
        let val = makeValue(dataType: "si16", bytes: bytes)
        XCTAssertEqual(val.int16Value, -1500)
    }

    // MARK: - UInt32 (little-endian)

    func testUInt32_value() {
        // 0x01020304 → LE: [0x04, 0x03, 0x02, 0x01]
        let val = makeValue(dataType: "ui32", bytes: [0x04, 0x03, 0x02, 0x01], dataSize: 4)
        XCTAssertEqual(val.uint32Value, 0x01020304)
    }

    // MARK: - UInt8

    func testUInt8_chargingInhibitFlag() {
        // CH0B charging inhibit: 0x02
        let val = makeValue(dataType: "ui8 ", bytes: [0x02], dataSize: 1)
        XCTAssertEqual(val.uint8Value, 0x02)
    }

    // MARK: - Edge Cases

    func testEmptyBytesReturnsNil() {
        let val = SMCValue(key: "TEST", dataSize: 0, dataType: "ui16", bytes: [])
        XCTAssertNil(val.uint16Value)
        XCTAssertNil(val.int16Value)
        XCTAssertNil(val.sp78Value)
    }

    // MARK: - Helpers

    private func makeValue(dataType: String, bytes: [UInt8], dataSize: UInt32? = nil) -> SMCValue {
        SMCValue(
            key: "TEST",
            dataSize: dataSize ?? UInt32(bytes.count),
            dataType: dataType,
            bytes: bytes
        )
    }

    private func bitsToLE(_ bits: UInt32) -> [UInt8] {
        [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
         UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
    }
}
