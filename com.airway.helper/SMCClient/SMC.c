//
//  SMC.c
//  
//
//  Created by John Cris Antor on 6/11/2026.
//

#include "SMC.h"
#include <string.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES  5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

UInt32 SMCKeyToUInt32(const char *key) {
    UInt32 result = 0;
    for (int i = 0; i < 4; i++) {
        result = (result << 8) + (UInt8)key[i];
    }
    return result;
}

io_connect_t SMCOpen(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                         IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) {
        return 0;
    }

    io_connect_t conn;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);

    if (result != kIOReturnSuccess) {
        return 0;
    }
    return conn;
}

kern_return_t SMCClose(io_connect_t conn) {
    return IOServiceClose(conn);
}

static kern_return_t SMCCall(io_connect_t conn, int index, SMCKeyData_t *input, SMCKeyData_t *output) {
    size_t inputSize = sizeof(SMCKeyData_t);
    size_t outputSize = sizeof(SMCKeyData_t);

    return IOConnectCallStructMethod(conn, index, input, inputSize, output, &outputSize);
}

static kern_return_t SMCGetKeyInfo(io_connect_t conn, UInt32 key, SMCKeyData_keyInfo_t *info) {
    SMCKeyData_t inputStruct;
    SMCKeyData_t outputStruct;

    memset(&inputStruct, 0, sizeof(SMCKeyData_t));
    memset(&outputStruct, 0, sizeof(SMCKeyData_t));

    inputStruct.key = key;
    inputStruct.data8 = SMC_CMD_READ_KEYINFO;

    kern_return_t result = SMCCall(conn, KERNEL_INDEX_SMC, &inputStruct, &outputStruct);
    if (result != kIOReturnSuccess) {
        return result;
    }

    *info = outputStruct.keyInfo;
    return kIOReturnSuccess;
}

kern_return_t SMCReadKey(io_connect_t conn, const char *key, SMCVal_t *val) {
    SMCKeyData_t inputStruct;
    SMCKeyData_t outputStruct;

    memset(&inputStruct, 0, sizeof(SMCKeyData_t));
    memset(&outputStruct, 0, sizeof(SMCKeyData_t));
    memset(val, 0, sizeof(SMCVal_t));

    UInt32 key32 = SMCKeyToUInt32(key);
    val->key = key32;
    inputStruct.key = key32;

    kern_return_t result = SMCGetKeyInfo(conn, key32, &inputStruct.keyInfo);
    if (result != kIOReturnSuccess) {
        return result;
    }

    val->dataType = inputStruct.keyInfo.dataType;
    val->dataSize = inputStruct.keyInfo.dataSize;
    if (val->dataSize == 0 || val->dataSize > sizeof(val->bytes)) {
        // A zero or nonsensical width means the key isn't really readable on
        // this hardware. Reporting it as "not found" keeps callers from
        // decoding uninitialised bytes.
        return kIOReturnNotFound;
    }
    inputStruct.data8 = SMC_CMD_READ_BYTES;

    result = SMCCall(conn, KERNEL_INDEX_SMC, &inputStruct, &outputStruct);
    if (result != kIOReturnSuccess) {
        return result;
    }

    memcpy(val->bytes, outputStruct.bytes, sizeof(outputStruct.bytes));
    return kIOReturnSuccess;
}

kern_return_t SMCWriteKey(io_connect_t conn, SMCVal_t writeVal, UInt8 *outFirmwareResult) {
    SMCKeyData_t inputStruct;
    SMCKeyData_t outputStruct;

    if (outFirmwareResult) *outFirmwareResult = 0;

    memset(&inputStruct, 0, sizeof(SMCKeyData_t));
    memset(&outputStruct, 0, sizeof(SMCKeyData_t));

    kern_return_t result = SMCGetKeyInfo(conn, writeVal.key, &inputStruct.keyInfo);
    if (result != kIOReturnSuccess) {
        return result;
    }

    inputStruct.key = writeVal.key;
    inputStruct.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(inputStruct.bytes, writeVal.bytes, sizeof(writeVal.bytes));

    result = SMCCall(conn, KERNEL_INDEX_SMC, &inputStruct, &outputStruct);
    if (outFirmwareResult) *outFirmwareResult = (UInt8)outputStruct.result;
    return result;
}
