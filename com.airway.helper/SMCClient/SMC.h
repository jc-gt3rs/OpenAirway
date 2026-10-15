//
//  SMC.h
//  
//
//  Created by John Cris Antor on 6/11/2026.
//

#ifndef SMC_H
#define SMC_H

#include <IOKit/IOKitLib.h>
#include <stdint.h>

typedef struct {
    char major, minor, build;
    char reserved[1];
    UInt16 release;
} SMCKeyData_vers_t;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    UInt32 key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    UInt8 bytes[32];
} SMCKeyData_t;

typedef struct {
    UInt32 key;
    UInt32 dataType;
    /// Width in bytes the SMC reports for this key. Needed because newer chip
    /// generations use type codes we may not recognise, and the width is the
    /// stable way to decode them (see SMCDecodeValue in SMCConvert.h).
    UInt32 dataSize;
    UInt8 bytes[32];
} SMCVal_t;

typedef enum {
    kSMCSuccess = 0,
    kSMCError = 1,
    kSMCKeyNotFound = 0x84
} SMCResult_t;

io_connect_t SMCOpen(void);
kern_return_t SMCClose(io_connect_t conn);
kern_return_t SMCReadKey(io_connect_t conn, const char *key, SMCVal_t *val);
/// Writes a value to the SMC.
///
/// `outFirmwareResult`, when non-NULL, receives the SMC firmware's own result
/// byte. IOKit can return `kIOReturnSuccess` for a write the firmware then
/// refuses, so this byte is the only in-band signal that a write was rejected.
/// It is reported rather than folded into the return value because the exact
/// non-zero codes vary by chip generation, and treating every one of them as
/// fatal would break machines that control fans correctly today. Callers use
/// it for diagnostics and gate real decisions on reading the value back.
kern_return_t SMCWriteKey(io_connect_t conn, SMCVal_t writeVal, UInt8 *outFirmwareResult);
UInt32 SMCKeyToUInt32(const char *key);

#endif
