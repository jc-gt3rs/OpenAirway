//
//  SMCConvert.h
//
//  Pure, side-effect-free conversions between the SMC's fixed-point / float
//  byte encodings and Double RPM/temperature values. Extracted from
//  SMCWrapperObjC so the arithmetic can be unit-tested without live hardware.
//
//  The SMC stores multi-byte numeric values big-endian. Fan speeds are usually
//  `fpe2` (unsigned 14.2 fixed-point) or `flt ` (IEEE-754 float); temperatures
//  are usually `sp78` (signed 8.8 fixed-point) or `flt `.
//
//  These are `static inline` so both the helper target and the test target can
//  compile the *same* code — the tests exercise exactly what ships.
//

#ifndef SMCConvert_h
#define SMCConvert_h

#include <stdint.h>
#include <string.h>

// MARK: - Big-endian byte <-> word helpers

/// Combine the two big-endian bytes the SMC stores into a 16-bit word.
static inline uint16_t SMCBytesToU16BE(uint8_t hi, uint8_t lo) {
    return (uint16_t)(((uint16_t)hi << 8) | (uint16_t)lo);
}

/// Split a 16-bit word into the two big-endian bytes the SMC expects.
static inline void SMCU16BEToBytes(uint16_t value, uint8_t *hi, uint8_t *lo) {
    *hi = (uint8_t)((value >> 8) & 0xFF);
    *lo = (uint8_t)(value & 0xFF);
}

// MARK: - fpe2 (unsigned 14.2 fixed-point)

/// Decode an `fpe2` raw word to its real value: raw / 4.
static inline double SMCDecodeFPE2(uint16_t raw) {
    return (double)raw / 4.0;
}

/// Encode a value into an `fpe2` raw word (value * 4), clamped to the
/// representable unsigned 16-bit range so a negative or absurd RPM can never
/// wrap around into a bogus low/high value written to the fan.
static inline uint16_t SMCEncodeFPE2(double value) {
    double scaled = value * 4.0;
    if (scaled < 0.0) scaled = 0.0;
    if (scaled > 65535.0) scaled = 65535.0;
    return (uint16_t)scaled;
}

// MARK: - sp78 (signed 8.8 fixed-point)

/// Decode an `sp78` raw word to its real value: raw / 256.
static inline double SMCDecodeSP78(int16_t raw) {
    return (double)raw / 256.0;
}

/// Encode a value into an `sp78` raw word (value * 256), clamped to the signed
/// 16-bit range.
static inline int16_t SMCEncodeSP78(double value) {
    double scaled = value * 256.0;
    if (scaled > 32767.0) scaled = 32767.0;
    if (scaled < -32768.0) scaled = -32768.0;
    return (int16_t)scaled;
}

// MARK: - flt (IEEE-754 single precision)

/// Decode a 4-byte little-endian `flt ` value (as the SMC stores it in bytes).
static inline double SMCDecodeFLT(const uint8_t bytes[4]) {
    float f;
    memcpy(&f, bytes, sizeof(f));
    return (double)f;
}

/// Encode a value into 4 `flt ` bytes.
static inline void SMCEncodeFLT(double value, uint8_t outBytes[4]) {
    float f = (float)value;
    memcpy(outBytes, &f, sizeof(f));
}

// MARK: - Four-char key codes

/// Pack a 4-character SMC key into the big-endian UInt32 the SMC expects.
/// Duplicated here (rather than in SMC.c) so the pure conversion layer — and
/// the unit tests that compile only this header — can name data types like
/// `"flt "` without linking the IOKit-backed SMC client.
static inline uint32_t SMCKeyToUInt32Const(const char *key) {
    uint32_t result = 0;
    for (int i = 0; i < 4; i++) {
        result = (result << 8) + (uint8_t)key[i];
    }
    return result;
}

// MARK: - ioft (IOKit 16.16 fixed-point, 8 bytes)

/// Decode an `ioft` value: a little-endian uint32 in 16.16 fixed point, where
/// the high half is the integer part and the low half the fraction. The key's
/// remaining 4 bytes are metadata and carry no part of the value.
///
/// M5 hardware reports sensors that earlier chips exposed as 4-byte `flt ` in
/// this 8-byte form. Without this decoder they read as 0, which is why an M5
/// saw no usable fan speeds or temperatures.
static inline double SMCDecodeIOFT(const uint8_t bytes[8]) {
    uint32_t raw = 0;
    memcpy(&raw, bytes, sizeof(raw));   // little-endian on every Mac we ship to
    double integer = (double)(raw >> 16);
    double fraction = (double)(raw & 0xFFFF) / 65536.0;
    return integer + fraction;
}

/// Encode a value into the first 4 bytes of an `ioft` field, clamped to the
/// representable 16.16 range. The trailing 4 metadata bytes are deliberately
/// left untouched so a read-modify-write preserves whatever the device put
/// there.
static inline void SMCEncodeIOFT(double value, uint8_t outBytes[8]) {
    if (value < 0.0) value = 0.0;
    if (value > 65535.99998) value = 65535.99998;
    uint32_t integer = (uint32_t)value;
    uint32_t fraction = (uint32_t)((value - (double)integer) * 65536.0 + 0.5);
    if (fraction > 0xFFFF) { fraction = 0xFFFF; }
    uint32_t raw = (integer << 16) | fraction;
    memcpy(outBytes, &raw, sizeof(raw));
}

// MARK: - Type-first, width-fallback dispatch

/// Decode an SMC value using its declared `dataType`, falling back to its
/// byte width when the type code is one we don't recognise.
///
/// The fallback matters: Apple has introduced new type codes with each chip
/// generation, and a type-only decoder silently returns 0 for anything new —
/// indistinguishable from a genuinely-zero reading. Widths, by contrast, are
/// stable: 8 bytes is `ioft`, 4 is an IEEE float, 2 is the classic fixed-point
/// word.
static inline double SMCDecodeValue(uint32_t dataType, const uint8_t *bytes, uint32_t size) {
    if (dataType == SMCKeyToUInt32Const("fpe2")) {
        return SMCDecodeFPE2(SMCBytesToU16BE(bytes[0], bytes[1]));
    }
    if (dataType == SMCKeyToUInt32Const("sp78")) {
        return SMCDecodeSP78((int16_t)SMCBytesToU16BE(bytes[0], bytes[1]));
    }
    if (dataType == SMCKeyToUInt32Const("flt ")) {
        return SMCDecodeFLT(bytes);
    }
    if (dataType == SMCKeyToUInt32Const("ioft")) {
        return SMCDecodeIOFT(bytes);
    }

    switch (size) {
        case 8: return SMCDecodeIOFT(bytes);
        case 4: return SMCDecodeFLT(bytes);
        case 2: return SMCDecodeFPE2(SMCBytesToU16BE(bytes[0], bytes[1]));
        default: return 0.0;
    }
}

#endif /* SMCConvert_h */
