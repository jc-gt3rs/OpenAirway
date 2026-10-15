//
//  SMCConvertTests.m
//
//  Unit tests for the pure SMC byte<->value conversions in SMCConvert.h.
//  These compile the same static-inline code the helper uses, so they verify
//  the exact arithmetic that gets written to fan hardware. No live SMC needed.
//
//  Written in Objective-C so it can #import the C header directly (the header
//  lives in the helper target, which is not linked into the app the Swift test
//  bundle hosts).
//

#import <XCTest/XCTest.h>
#import "../com.airway.helper/SMCClient/SMCConvert.h"

@interface SMCConvertTests : XCTestCase
@end

@implementation SMCConvertTests

// MARK: - Big-endian byte helpers

- (void)testBytesToU16BE {
    XCTAssertEqual(SMCBytesToU16BE(0x27, 0x10), 0x2710);   // 10000
    XCTAssertEqual(SMCBytesToU16BE(0x00, 0x00), 0);
    XCTAssertEqual(SMCBytesToU16BE(0xFF, 0xFF), 0xFFFF);
}

- (void)testU16BEToBytes_roundTrips {
    uint8_t hi = 0, lo = 0;
    SMCU16BEToBytes(0x2710, &hi, &lo);
    XCTAssertEqual(hi, 0x27);
    XCTAssertEqual(lo, 0x10);
    // Round-trip through both helpers.
    XCTAssertEqual(SMCBytesToU16BE(hi, lo), 0x2710);
}

// MARK: - fpe2 (unsigned 14.2 fixed-point) — fan RPM

- (void)testDecodeFPE2 {
    XCTAssertEqualWithAccuracy(SMCDecodeFPE2(10000), 2500.0, 0.0001); // 10000/4
    XCTAssertEqualWithAccuracy(SMCDecodeFPE2(0), 0.0, 0.0001);
    XCTAssertEqualWithAccuracy(SMCDecodeFPE2(0xFFFF), 16383.75, 0.0001);
}

- (void)testEncodeFPE2 {
    XCTAssertEqual(SMCEncodeFPE2(2500.0), 10000); // 2500*4
    XCTAssertEqual(SMCEncodeFPE2(0.0), 0);
}

- (void)testEncodeFPE2_clampsOutOfRange {
    // Negative RPM must never wrap into a huge value written to the fan.
    XCTAssertEqual(SMCEncodeFPE2(-100.0), 0);
    // Above the representable range clamps to max rather than overflowing.
    XCTAssertEqual(SMCEncodeFPE2(20000.0), 0xFFFF); // 20000*4=80000 -> clamp
}

- (void)testFPE2_encodeDecode_roundTrip {
    // Values on a 0.25 grid round-trip exactly.
    for (double rpm = 0.0; rpm <= 6500.0; rpm += 250.0) {
        uint16_t raw = SMCEncodeFPE2(rpm);
        XCTAssertEqualWithAccuracy(SMCDecodeFPE2(raw), rpm, 0.0001,
                                   @"fpe2 round-trip failed for %.2f", rpm);
    }
}

// MARK: - sp78 (signed 8.8 fixed-point) — temperature

- (void)testDecodeSP78 {
    XCTAssertEqualWithAccuracy(SMCDecodeSP78(6528), 25.5, 0.0001);  // 6528/256
    XCTAssertEqualWithAccuracy(SMCDecodeSP78(0), 0.0, 0.0001);
    XCTAssertEqualWithAccuracy(SMCDecodeSP78(-256), -1.0, 0.0001);  // signed
}

- (void)testEncodeSP78 {
    XCTAssertEqual(SMCEncodeSP78(25.5), 6528);
    XCTAssertEqual(SMCEncodeSP78(-1.0), -256);
}

- (void)testEncodeSP78_clampsOutOfRange {
    XCTAssertEqual(SMCEncodeSP78(200.0), 32767);    // 200*256 > INT16_MAX
    XCTAssertEqual(SMCEncodeSP78(-200.0), -32768);  // below INT16_MIN
}

- (void)testSP78_signednessViaU16Reinterpret {
    // Mirrors how the wrapper reads sp78: bytes -> u16 -> reinterpret as int16.
    uint16_t rawU = SMCBytesToU16BE(0xFF, 0x00); // 0xFF00
    XCTAssertEqualWithAccuracy(SMCDecodeSP78((int16_t)rawU), -1.0, 0.0001);
}

// MARK: - flt (IEEE-754 single precision)

- (void)testFLT_encodeDecode_roundTrip {
    uint8_t bytes[4];
    SMCEncodeFLT(3456.0, bytes);
    XCTAssertEqualWithAccuracy(SMCDecodeFLT(bytes), 3456.0, 0.001);

    SMCEncodeFLT(0.0, bytes);
    XCTAssertEqualWithAccuracy(SMCDecodeFLT(bytes), 0.0, 0.001);
}

// MARK: - ioft (IOKit 16.16 fixed-point, 8-byte) — M5 sensors
//
// ThermalForge documents 8-byte `ioft` values on M5 hardware where earlier
// chips used 4-byte `flt `. Airway read those as 0.0 before this decoder
// existed, which is why an M5 reported no usable fan/temperature values.

- (void)testDecodeIOFT_readsLittleEndian1616FixedPoint {
    // 90.5 C -> integer 90 (0x005A) in the high half, .5 (0x8000) in the low.
    // Stored little-endian, so the low half's bytes come first.
    uint8_t bytes[8] = {0x00, 0x80, 0x5A, 0x00, 0, 0, 0, 0};
    XCTAssertEqualWithAccuracy(SMCDecodeIOFT(bytes), 90.5, 0.0001);
}

- (void)testDecodeIOFT_zero {
    uint8_t bytes[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    XCTAssertEqualWithAccuracy(SMCDecodeIOFT(bytes), 0.0, 0.0001);
}

- (void)testDecodeIOFT_ignoresTrailingMetadataBytes {
    // Only the first 4 of the 8 bytes carry the value; the rest is metadata
    // and must not perturb the result.
    uint8_t bytes[8] = {0x00, 0x00, 0x2C, 0x01, 0xDE, 0xAD, 0xBE, 0xEF};
    XCTAssertEqualWithAccuracy(SMCDecodeIOFT(bytes), 300.0, 0.0001);
}

// MARK: - SMCDecodeValue — type-first, size-fallback dispatch

- (void)testDecodeValue_dispatchesOnKnownTypes {
    uint8_t fpe2[2] = {0x27, 0x10};                    // 10000/4 = 2500 RPM
    XCTAssertEqualWithAccuracy(
        SMCDecodeValue(SMCKeyToUInt32Const("fpe2"), fpe2, 2), 2500.0, 0.001);

    uint8_t sp78[2] = {0x19, 0x80};                    // 0x1980/256 = 25.5 C
    XCTAssertEqualWithAccuracy(
        SMCDecodeValue(SMCKeyToUInt32Const("sp78"), sp78, 2), 25.5, 0.001);

    uint8_t flt[4];
    SMCEncodeFLT(3456.0, flt);
    XCTAssertEqualWithAccuracy(
        SMCDecodeValue(SMCKeyToUInt32Const("flt "), flt, 4), 3456.0, 0.001);

    uint8_t ioft[8] = {0x00, 0x00, 0x5A, 0x00, 0, 0, 0, 0};
    XCTAssertEqualWithAccuracy(
        SMCDecodeValue(SMCKeyToUInt32Const("ioft"), ioft, 8), 90.0, 0.001);
}

- (void)testDecodeValue_fallsBackToSizeForUnknownType {
    // An unrecognised type code must still decode by width rather than
    // silently returning 0 — that silent 0 is what broke M5 fan detection.
    uint32_t unknown = SMCKeyToUInt32Const("zzzz");

    uint8_t eight[8] = {0x00, 0x00, 0x5A, 0x00, 0, 0, 0, 0};
    XCTAssertEqualWithAccuracy(SMCDecodeValue(unknown, eight, 8), 90.0, 0.001);

    uint8_t four[4];
    SMCEncodeFLT(1234.0, four);
    XCTAssertEqualWithAccuracy(SMCDecodeValue(unknown, four, 4), 1234.0, 0.001);

    uint8_t two[2] = {0x27, 0x10};
    XCTAssertEqualWithAccuracy(SMCDecodeValue(unknown, two, 2), 2500.0, 0.001);
}

- (void)testDecodeValue_returnsZeroForUndecodableWidth {
    uint8_t one[1] = {0x05};
    XCTAssertEqualWithAccuracy(
        SMCDecodeValue(SMCKeyToUInt32Const("zzzz"), one, 1), 0.0, 0.0001);
}

- (void)testEncodeIOFT_roundTripsThroughDecode {
    uint8_t bytes[8];
    memset(bytes, 0xAA, sizeof(bytes));
    SMCEncodeIOFT(4200.25, bytes);
    XCTAssertEqualWithAccuracy(SMCDecodeIOFT(bytes), 4200.25, 0.0001);
}

- (void)testEncodeIOFT_clampsNegativeToZero {
    uint8_t bytes[8];
    SMCEncodeIOFT(-50.0, bytes);
    XCTAssertEqualWithAccuracy(SMCDecodeIOFT(bytes), 0.0, 0.0001);
}

@end
