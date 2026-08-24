import XCTest
@testable import ZephyrKit

/// The SMC hands back raw bytes with a four-character type tag and no other
/// context. Getting a decoder wrong does not throw — it quietly reports a
/// plausible-looking wrong temperature, which is the worst kind of bug for an
/// app that then drives the fans from it.
final class SMCDecodingTests: XCTestCase {

    func testDecodesLittleEndianFloats() {
        // 3800.0 as float32, little-endian — the byte pattern a real F0Tg returns.
        let bytes: [UInt8] = [0x00, 0x80, 0x6d, 0x45]
        guard case .float(let value) = SMC.decode(type: "flt ", bytes: bytes) else {
            return XCTFail("expected a float")
        }
        XCTAssertEqual(value, 3800, accuracy: 0.01)
    }

    func testDecodesUnsignedIntegersBigEndian() {
        XCTAssertEqual(SMC.decode(type: "ui8 ", bytes: [0x2a]).double, 42)
        XCTAssertEqual(SMC.decode(type: "ui16", bytes: [0x01, 0x00]).double, 256)
        XCTAssertEqual(SMC.decode(type: "ui32", bytes: [0x00, 0x00, 0x08, 0x04]).double, 2052)
    }

    func testDecodesSignedIntegers() {
        XCTAssertEqual(SMC.decode(type: "si8 ", bytes: [0xff]).double, -1)
        XCTAssertEqual(SMC.decode(type: "si16", bytes: [0xff, 0xff]).double, -1)
        XCTAssertEqual(SMC.decode(type: "si16", bytes: [0x00, 0x40]).double, 64)
    }

    /// sp78 is the classic Intel temperature encoding: signed, 8 fractional bits.
    func testDecodesSP78Temperatures() {
        XCTAssertEqual(SMC.decode(type: "sp78", bytes: [0x32, 0x80]).double ?? 0, 50.5, accuracy: 0.001)
        XCTAssertEqual(SMC.decode(type: "sp78", bytes: [0xff, 0x00]).double ?? 0, -1, accuracy: 0.001)
    }

    /// fpe2 is how Intel Macs report fan RPM: unsigned, 2 fractional bits.
    func testDecodesFPE2FanSpeeds() {
        XCTAssertEqual(SMC.decode(type: "fpe2", bytes: [0x0f, 0xa0]).double ?? 0, 1000, accuracy: 0.001)
    }

    func testDecodesFlags() {
        XCTAssertEqual(SMC.decode(type: "flag", bytes: [0x01]).double, 1)
        XCTAssertEqual(SMC.decode(type: "flag", bytes: [0x00]).double, 0)
    }

    func testUnknownTypesStayRawRatherThanGuessing() {
        guard case .raw(let bytes) = SMC.decode(type: "{fds", bytes: [0x01, 0x02]) else {
            return XCTFail("expected raw bytes")
        }
        XCTAssertEqual(bytes, [0x01, 0x02])
    }

    func testShortBuffersDoNotCrashTheDecoder() {
        XCTAssertNotNil(SMC.decode(type: "flt ", bytes: []))
        XCTAssertNotNil(SMC.decode(type: "sp78", bytes: [0x01]))
        XCTAssertNotNil(SMC.decode(type: "fpe2", bytes: []))
    }

    // MARK: Encoding

    func testFloatEncodingRoundTrips() {
        guard let encoded = SMC.encode(type: "flt ", size: 4, value: 3200) else {
            return XCTFail("expected an encoding")
        }
        XCTAssertEqual(SMC.decode(type: "flt ", bytes: encoded).double ?? 0, 3200, accuracy: 0.01)
    }

    func testFPE2EncodingRoundTrips() {
        guard let encoded = SMC.encode(type: "fpe2", size: 2, value: 1200) else {
            return XCTFail("expected an encoding")
        }
        XCTAssertEqual(SMC.decode(type: "fpe2", bytes: encoded).double ?? 0, 1200, accuracy: 0.5)
    }

    func testIntegerEncodingClampsInsteadOfOverflowing() {
        XCTAssertEqual(SMC.encode(type: "ui8 ", size: 1, value: 99_999), [255])
        XCTAssertEqual(SMC.encode(type: "ui8 ", size: 1, value: -50), [0])
    }

    func testUnsupportedTypesRefuseToEncode() {
        XCTAssertNil(SMC.encode(type: "{fds", size: 16, value: 1))
    }

    func testFourCCRoundTrips() {
        XCTAssertEqual(SMC.string(fromFourCC: SMC.fourCC("F0Tg")), "F0Tg")
        XCTAssertEqual(SMC.string(fromFourCC: SMC.fourCC("#KEY")), "#KEY")
    }
}
