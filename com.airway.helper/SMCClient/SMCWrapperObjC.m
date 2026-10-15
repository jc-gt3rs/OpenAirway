#import "SMCWrapperObjC.h"
#import "SMC.h"
#import "SMCConvert.h"
#import <unistd.h>

NSString * const SMCWrapperErrorDomain = @"SMCErrorDomain";

@interface SMCWrapperObjC ()
@property (nonatomic, assign) io_connect_t connection;
/// Detected once per connection: "F%dmd" (M5+) or "F%dMd" (M1–M4), or nil when
/// neither exists. Probing is three IOKit round-trips, and it used to run on
/// every single speed change.
@property (nonatomic, copy, nullable) NSString *cachedModeKeyFormat;
@property (nonatomic, assign) BOOL modeKeyFormatProbed;
@end

@implementation SMCWrapperObjC

- (instancetype)init {
    return [self initWithError:nil];
}

- (nullable instancetype)initWithError:(NSError **)error {
    self = [super init];
    if (self) {
        _connection = SMCOpen();
        NSLog(@"[SMCWrapperObjC] initWithError called, connection: %d", _connection);
        if (_connection == 0) {
            if (error) *error = [NSError errorWithDomain:SMCWrapperErrorDomain code:SMCWrapperErrorConnectionFailed userInfo:@{NSLocalizedDescriptionKey: @"Could not open connection to AppleSMC."}];
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    if (_connection != 0) {
        SMCClose(_connection);
    }
}

- (NSInteger)fanCount {
    SMCVal_t val;
    kern_return_t result = SMCReadKey(self.connection, "FNum", &val);
    if (result != kIOReturnSuccess) {
        NSLog(@"[SMCWrapperObjC] FNum unreadable (result: %d)", result);
        return -1;
    }
    return val.bytes[0];
}

- (double)readFloatKey:(const char *)key {
    SMCVal_t val;
    kern_return_t result = SMCReadKey(self.connection, key, &val);
    if (result != kIOReturnSuccess) {
        return 0.0;
    }
    // Decode by declared type, falling back to the value's width. The width
    // fallback is what makes M5 work: it reports sensors as 8-byte `ioft`
    // where earlier chips used 4-byte `flt `, and a type-only decoder returned
    // a silent 0 for every one of them.
    return SMCDecodeValue(val.dataType, val.bytes, val.dataSize);
}

- (BOOL)writeFloatKey:(const char *)key value:(double)value error:(NSError **)error {
    // Read the key first to discover its native data type and width, and to
    // preserve any bytes we don't own. We modify in place on the readVal so the
    // SMC gets exactly the format it expects.
    SMCVal_t readVal;
    kern_return_t readResult = SMCReadKey(self.connection, key, &readVal);

    if (readResult != kIOReturnSuccess) {
        NSLog(@"[SMCWrapperObjC] writeFloatKey: Cannot read key '%s' to detect format (result: %d). Attempting fpe2 fallback.", key, readResult);
        // Construct a fallback write with fpe2 encoding
        SMCVal_t writeVal;
        memset(&writeVal, 0, sizeof(writeVal));
        writeVal.key = SMCKeyToUInt32(key);
        writeVal.dataType = SMCKeyToUInt32("fpe2");
        writeVal.dataSize = 2;
        SMCU16BEToBytes(SMCEncodeFPE2(value), &writeVal.bytes[0], &writeVal.bytes[1]);
        UInt8 firmwareResult = 0;
        kern_return_t result = SMCWriteKey(self.connection, writeVal, &firmwareResult);
        if (result != kIOReturnSuccess) {
            if (error) *error = [NSError errorWithDomain:SMCWrapperErrorDomain code:SMCWrapperErrorWriteFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write %s (fpe2 fallback, read failed)", key]}];
            return NO;
        }
        return YES;
    }

    // Encode the value into readVal.bytes using the native data type. Writing
    // back the same struct preserves key, dataType, width, and any bytes the
    // device owns.
    if (readVal.dataType == SMCKeyToUInt32Const("flt ")) {
        SMCEncodeFLT(value, readVal.bytes);
        NSLog(@"[SMCWrapperObjC] writeFloatKey: '%s' type=flt, value=%.1f", key, value);
    } else if (readVal.dataType == SMCKeyToUInt32Const("ioft")) {
        SMCEncodeIOFT(value, readVal.bytes);
        NSLog(@"[SMCWrapperObjC] writeFloatKey: '%s' type=ioft, value=%.1f", key, value);
    } else if (readVal.dataType == SMCKeyToUInt32Const("fpe2")) {
        SMCU16BEToBytes(SMCEncodeFPE2(value), &readVal.bytes[0], &readVal.bytes[1]);
        NSLog(@"[SMCWrapperObjC] writeFloatKey: '%s' type=fpe2, value=%.1f", key, value);
    } else if (readVal.dataType == SMCKeyToUInt32Const("sp78")) {
        SMCU16BEToBytes((uint16_t)SMCEncodeSP78(value), &readVal.bytes[0], &readVal.bytes[1]);
        NSLog(@"[SMCWrapperObjC] writeFloatKey: '%s' type=sp78, value=%.1f", key, value);
    } else {
        // Unrecognised type code — encode by width, mirroring how
        // SMCDecodeValue reads it back. Blindly assuming fpe2 here used to
        // stuff a 2-byte big-endian word into the front of an 8-byte ioft
        // field, which the SMC read as garbage.
        NSLog(@"[SMCWrapperObjC] writeFloatKey: '%s' has unknown dataType 0x%08X (size %u), encoding by width",
              key, readVal.dataType, readVal.dataSize);
        switch (readVal.dataSize) {
            case 8: SMCEncodeIOFT(value, readVal.bytes); break;
            case 4: SMCEncodeFLT(value, readVal.bytes); break;
            case 2: SMCU16BEToBytes(SMCEncodeFPE2(value), &readVal.bytes[0], &readVal.bytes[1]); break;
            default:
                if (error) {
                    *error = [NSError errorWithDomain:SMCWrapperErrorDomain code:SMCWrapperErrorKeyUnavailable
                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Key %s has an unsupported %u-byte format", key, readVal.dataSize]}];
                }
                return NO;
        }
    }

    UInt8 firmwareResult = 0;
    kern_return_t result = SMCWriteKey(self.connection, readVal, &firmwareResult);
    if (result != kIOReturnSuccess) {
        NSLog(@"[SMCWrapperObjC] writeFloatKey: SMCWriteKey failed for '%s' (result: %d)", key, result);
        if (error) *error = [NSError errorWithDomain:SMCWrapperErrorDomain code:SMCWrapperErrorWriteFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write %s", key]}];
        return NO;
    }
    if (firmwareResult != 0) {
        NSLog(@"[SMCWrapperObjC] writeFloatKey: '%s' accepted by IOKit but SMC firmware returned result=%d", key, firmwareResult);
    }
    return YES;
}

- (double)fanSpeedForIndex:(NSInteger)index {
    char key[5];
    snprintf(key, sizeof(key), "F%dAc", (int)index);
    return [self readFloatKey:key];
}

- (double)fanMinSpeedForIndex:(NSInteger)index {
    char key[5];
    snprintf(key, sizeof(key), "F%dMn", (int)index);
    return [self readFloatKey:key];
}

- (double)fanMaxSpeedForIndex:(NSInteger)index {
    char key[5];
    snprintf(key, sizeof(key), "F%dMx", (int)index);
    return [self readFloatKey:key];
}

- (double)systemTemperature {
    // Probe temperature sensors in priority order and return the hottest sane
    // reading. Ignore values <10C / >150C — those are sleeping or unsupported
    // keys (e.g. returning 2.0).
    //
    // This returns the PEAK rather than the first hit because the thermal
    // safety override keys off it: a machine whose P-cores are at 95C while
    // the first-listed sensor reads 60C still needs the override.
    static const char *keys[] = {
        // Apple Silicon SoC / CPU-die sensors that already work broadly.
        "Te05", "Tp01", "Tp05", "Tp09", "Tp0T",
        // Additional P-core cluster die sensors — broaden coverage across
        // M1/M2/M3/M4/M5 variants where the leading keys aren't present.
        "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0b",
        // M5 aggregate CPU/GPU sensors (key names verified by ThermalForge on
        // Mac17,x, where they are reported as 8-byte `ioft`).
        "TCDX", "TCHP", "TCMb", "TGDX",
        // Intel fallback (older / non-Apple-Silicon).
        "TC0D", "TC0P",
    };
    int numKeys = sizeof(keys) / sizeof(keys[0]);

    double peak = 0.0;
    for (int i = 0; i < numKeys; i++) {
        double temp = [self readFloatKey:keys[i]];
        if (temp > 10.0 && temp < 150.0 && temp > peak) {
            peak = temp;
        }
    }
    return peak;
}

- (BOOL)setFanTargetSpeedForIndex:(NSInteger)index rpm:(double)rpm error:(NSError **)error {
    char key[5];
    snprintf(key, sizeof(key), "F%dTg", (int)index);
    return [self writeFloatKey:key value:rpm error:error];
}

/// Writes `value` into byte 0 of an existing key, preserving the rest of the
/// value the device reported. Returns NO when the key isn't present.
- (BOOL)writeByteZero:(uint8_t)value toKey:(const char *)key firmwareResult:(UInt8 *)outFirmwareResult {
    SMCVal_t val;
    if (SMCReadKey(self.connection, key, &val) != kIOReturnSuccess) {
        return NO;
    }
    val.bytes[0] = value;
    return SMCWriteKey(self.connection, val, outFirmwareResult) == kIOReturnSuccess;
}

/// Writes `value` to a fan's mode key and does not return until a read-back
/// confirms it, or `deadline` passes.
///
/// The SMC rejects mode-key writes that arrive while it is still settling, and
/// it reports those rejections as success — IOKit returns `kIOReturnSuccess`
/// and the firmware result byte stays 0, yet the value never changes. Verified
/// retry is the only reliable way to move this key. Observed on an M2 Max: the
/// first write is rejected and the second, 100ms later, succeeds.
///
/// Returns NO when the key is absent, or when the value never took hold.
- (BOOL)writeModeKeyValue:(uint8_t)value
                 forIndex:(NSInteger)index
                 deadline:(NSDate *)deadline {
    NSString *format = [self detectModeKeyFormat];
    if (!format) { return NO; }

    char mdKey[5];
    snprintf(mdKey, sizeof(mdKey), [format UTF8String], (int)index);

    int attempt = 0;
    do {
        SMCVal_t mdVal;
        if (SMCReadKey(self.connection, mdKey, &mdVal) != kIOReturnSuccess) {
            NSLog(@"[SMCWrapperObjC] %s not readable — cannot write mode %d", mdKey, value);
            return NO;
        }
        if (mdVal.bytes[0] == value) {
            if (attempt > 0) {
                NSLog(@"[SMCWrapperObjC] %s = %d confirmed (attempt %d)", mdKey, value, attempt);
            }
            return YES;
        }

        mdVal.bytes[0] = value;
        UInt8 firmwareResult = 0;
        SMCWriteKey(self.connection, mdVal, &firmwareResult);
        attempt++;
        usleep(100 * 1000);
    } while ([deadline timeIntervalSinceNow] > 0);

    NSLog(@"[SMCWrapperObjC] %s never accepted %d within the budget (%d attempts)", mdKey, value, attempt);
    return NO;
}

/// Budget for releasing a fan back to system control. Shorter than the acquire
/// budget: releasing is not something the user waits on a spinner for, but it
/// must still get more than one shot at the key.
static const NSTimeInterval kAirwayReleaseBudgetSeconds = 2.0;

- (BOOL)setManualMode:(BOOL)enabled fanCount:(NSInteger)fanCount error:(NSError **)error {
    BOOL success = NO;

    NSString *format = [self detectModeKeyFormat];
    if (format) {
        for (int i = 0; i < fanCount; i++) {
            char key[5];
            snprintf(key, sizeof(key), [format UTF8String], i);
            if ([self writeByteZero:(enabled ? 1 : 0) toKey:key firmwareResult:NULL]) {
                success = YES;
            }
        }
    }

    // Legacy Intel style (FS! ). Absent on Apple Silicon, where the write
    // simply fails and leaves `success` decided by the mode key above.
    UInt16 mask = 0;
    if (enabled) {
        for (int i = 0; i < fanCount; i++) {
            mask |= (1 << i);
        }
    }

    SMCVal_t val;
    memset(&val, 0, sizeof(val));
    val.key = SMCKeyToUInt32("FS! ");
    val.dataType = SMCKeyToUInt32("ui16");
    val.dataSize = 2;
    val.bytes[0] = (mask >> 8) & 0xFF;
    val.bytes[1] = mask & 0xFF;

    if (SMCWriteKey(self.connection, val, NULL) == kIOReturnSuccess) {
        success = YES;
    }

    return success;
}

- (BOOL)setForceBitForFanIndex:(NSInteger)index enabled:(BOOL)enabled error:(NSError **)error {
    // Step 1: Read current FS!  bitmask
    SMCVal_t readVal;
    kern_return_t readResult = SMCReadKey(self.connection, "FS! ", &readVal);

    UInt16 currentMask = 0;
    if (readResult == kIOReturnSuccess) {
        currentMask = ((UInt16)readVal.bytes[0] << 8) | (UInt16)readVal.bytes[1];
        NSLog(@"[SMCWrapperObjC] Read FS!  current mask: 0x%04X", currentMask);
    } else {
        NSLog(@"[SMCWrapperObjC] Could not read FS! , starting with mask 0x0000 (result: %d)", readResult);
    }

    // Step 2: Flip the manual control bit for this fan index
    if (enabled) {
        currentMask |= (1 << index);
    } else {
        currentMask &= ~(1 << index);
    }

    NSLog(@"[SMCWrapperObjC] Writing FS!  new mask: 0x%04X (fan %ld %s)", currentMask, (long)index, enabled ? "FORCE_ON" : "FORCE_OFF");

    // Step 3: Write the updated mask back to FS!
    SMCVal_t writeVal;
    if (readResult == kIOReturnSuccess) {
        writeVal = readVal;
    } else {
        memset(&writeVal, 0, sizeof(writeVal));
        writeVal.key = SMCKeyToUInt32("FS! ");
        writeVal.dataType = SMCKeyToUInt32("ui16");
        writeVal.dataSize = 2;
    }
    writeVal.bytes[0] = (currentMask >> 8) & 0xFF;
    writeVal.bytes[1] = currentMask & 0xFF;

    kern_return_t writeResult = SMCWriteKey(self.connection, writeVal, NULL);
    BOOL fsWritten = (writeResult == kIOReturnSuccess);
    if (!fsWritten) {
        NSLog(@"[SMCWrapperObjC] FS!  unavailable for fan %ld (result: %d) — Apple Silicon uses the per-fan mode key instead", (long)index, writeResult);
    }

    // Per-fan mode key — the authoritative control on Apple Silicon.
    BOOL modeWritten = NO;
    NSString *format = [self detectModeKeyFormat];
    if (format) {
        char mdKey[5];
        snprintf(mdKey, sizeof(mdKey), [format UTF8String], (int)index);
        UInt8 firmwareResult = 0;
        modeWritten = [self writeByteZero:(enabled ? 1 : 0) toKey:mdKey firmwareResult:&firmwareResult];
        NSLog(@"[SMCWrapperObjC] %s set to %d (written: %d, firmware result: %d)", mdKey, enabled ? 1 : 0, modeWritten, firmwareResult);
    }

    if (!fsWritten && !modeWritten) {
        if (error) {
            *error = [NSError errorWithDomain:SMCWrapperErrorDomain code:SMCWrapperErrorKeyUnavailable
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"No writable fan control key for fan %ld", (long)index]}];
        }
        return NO;
    }
    return YES;
}

- (BOOL)isFanUnderManualControlForIndex:(NSInteger)index {
    // A fan is under manual/forced override if EITHER signal says so. Neither
    // is reliable alone: on some hardware the FS!  force bit is the indicator,
    // on others FS!  reads 0 (or is absent entirely, as on M5) while the
    // per-fan mode key holds the manual state.
    BOOL manual = NO;

    // Signal 1: FS!  force bitmask — a set bit for this fan means forced.
    UInt16 mask = 0;
    BOOL fsReadable = NO;
    SMCVal_t fsVal;
    if (SMCReadKey(self.connection, "FS! ", &fsVal) == kIOReturnSuccess) {
        fsReadable = YES;
        mask = ((UInt16)fsVal.bytes[0] << 8) | (UInt16)fsVal.bytes[1];
        if (mask & (1 << index)) manual = YES;
    }

    // Signal 2: per-fan mode key. This is NOT a boolean — Airway itself only
    // ever writes 0 (released) or 1 (manual override). But thermalmonitord
    // writes its OWN value of 3 ("System Mode") when it reclaims/holds control.
    // Treating "!= 0" as manual misread that 3 as an Airway override,
    // permanently pinning the UI to Manual/Max even after control was
    // correctly released. Only an exact match of 1 means Airway holds this fan.
    int modeKeyVal = -1;
    if (!manual) {
        NSString *format = [self detectModeKeyFormat];
        if (format) {
            char mdKey[5];
            snprintf(mdKey, sizeof(mdKey), [format UTF8String], (int)index);
            SMCVal_t mdVal;
            if (SMCReadKey(self.connection, mdKey, &mdVal) == kIOReturnSuccess) {
                modeKeyVal = mdVal.bytes[0];
                if (mdVal.bytes[0] == 1) manual = YES;
            }
        }
    }

    NSLog(@"[SMCWrapperObjC] isFanUnderManualControl fan %ld: FS!(readable=%d mask=0x%04X) modeKey=%d -> %s",
          (long)index, fsReadable, mask, modeKeyVal, manual ? "MANUAL" : "SYSTEM");
    return manual;
}

- (BOOL)clearAllForceBitsWithError:(NSError **)error {
    NSLog(@"[SMCWrapperObjC] Clearing all FS!  force bits (returning to system control)");

    // Restore Ftst=0 to re-enable thermalmonitord control
    [self disableFtstUnlockWithError:nil];

    // Clear FS!  entirely — read first to preserve native format
    SMCVal_t readVal;
    kern_return_t readResult = SMCReadKey(self.connection, "FS! ", &readVal);

    if (readResult == kIOReturnSuccess) {
        SMCVal_t writeVal = readVal;
        writeVal.bytes[0] = 0;
        writeVal.bytes[1] = 0;
        kern_return_t result = SMCWriteKey(self.connection, writeVal, NULL);
        if (result != kIOReturnSuccess) {
            NSLog(@"[SMCWrapperObjC] Failed to clear FS!  (result: %d)", result);
        }
    } else {
        // FS!  doesn't exist on this hardware (M5+). The per-fan mode keys
        // below are the real release mechanism, so this is not a failure.
        NSLog(@"[SMCWrapperObjC] FS!  absent (result: %d) — releasing via per-fan mode keys only", readResult);
    }

    // Clear the per-fan mode keys — the authoritative release on Apple Silicon.
    // Verified with retry; see writeModeKeyValue: for why a blind write loses.
    NSString *format = [self detectModeKeyFormat];
    NSInteger count = [self fanCount];
    BOOL releasedAny = NO;
    if (format && count > 0) {
        // Share one budget across the fans so a machine with several of them
        // can't stall the caller.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kAirwayReleaseBudgetSeconds * (double)count];
        for (NSInteger i = 0; i < count; i++) {
            if ([self writeModeKeyValue:0 forIndex:i deadline:deadline]) {
                releasedAny = YES;
            }
        }
    }

    if (readResult != kIOReturnSuccess && !releasedAny) {
        if (error) {
            *error = [NSError errorWithDomain:SMCWrapperErrorDomain code:SMCWrapperErrorKeyUnavailable
                userInfo:@{NSLocalizedDescriptionKey: @"No writable fan control key — cannot return fans to system control"}];
        }
        return NO;
    }

    return YES;
}

#pragma mark - Ftst Diagnostic Unlock (Apple Silicon M3/M4)

- (BOOL)enableFtstUnlockWithError:(NSError **)error {
    // Write Ftst=1 to signal thermalmonitord to yield fan control.
    // On M5+ where Ftst is absent, SMCReadKey will fail and we skip — direct mode writes work there.
    UInt8 firmwareResult = 0;
    if (![self writeByteZero:1 toKey:"Ftst" firmwareResult:&firmwareResult]) {
        NSLog(@"[SMCWrapperObjC] Ftst not writable — likely M5+ or Intel, skipping unlock");
        return YES; // Not an error — Ftst is optional
    }
    NSLog(@"[SMCWrapperObjC] Ftst=1 written (firmware result: %d)", firmwareResult);
    return YES;
}

- (BOOL)disableFtstUnlockWithError:(NSError **)error {
    if (![self writeByteZero:0 toKey:"Ftst" firmwareResult:NULL]) {
        return YES; // Ftst absent — nothing to restore
    }
    NSLog(@"[SMCWrapperObjC] Ftst=0 written");
    return YES;
}

- (nullable NSString *)detectModeKeyFormat {
    if (self.modeKeyFormatProbed) {
        return self.cachedModeKeyFormat;
    }
    self.modeKeyFormatProbed = YES;

    // Probe fan 0 with both casings. Lowercase FIRST: M5 exposes `F%dmd` and
    // that is the key that actually takes a write there. Probing uppercase
    // first risks binding to a vestigial `F%dMd` that reads back but never
    // engages, which presents to the user as "manual mode does nothing".
    SMCVal_t val;
    if (SMCReadKey(self.connection, "F0md", &val) == kIOReturnSuccess) {
        NSLog(@"[SMCWrapperObjC] Detected mode key format: F%%dmd (lowercase, M5+)");
        self.cachedModeKeyFormat = @"F%dmd";
        return self.cachedModeKeyFormat;
    }
    if (SMCReadKey(self.connection, "F0Md", &val) == kIOReturnSuccess) {
        NSLog(@"[SMCWrapperObjC] Detected mode key format: F%%dMd (uppercase, M1–M4)");
        self.cachedModeKeyFormat = @"F%dMd";
        return self.cachedModeKeyFormat;
    }
    NSLog(@"[SMCWrapperObjC] WARNING: Neither F0md nor F0Md is readable — no mode key found");
    self.cachedModeKeyFormat = nil;
    return nil;
}

#pragma mark - All-in-one Wake Override

- (BOOL)setFanSpeedWithWakeOverrideForIndex:(NSInteger)index
                                        rpm:(double)rpm
                                delayMillis:(NSInteger)delayMillis
                                   deadline:(NSDate *)deadline
                                      error:(NSError **)error {

    NSLog(@"[SMCWrapperObjC] === Wake Override for Fan %ld: target=%.1f RPM, delay=%ldms, budget=%.1fs ===",
          (long)index, rpm, (long)delayMillis, [deadline timeIntervalSinceNow]);

    // ---------- Phase 0: Mode key (cached after the first probe) ----------
    NSString *modeKeyFormat = [self detectModeKeyFormat];
    char mdKey[5];
    if (modeKeyFormat) {
        snprintf(mdKey, sizeof(mdKey), [modeKeyFormat UTF8String], (int)index);
    } else {
        snprintf(mdKey, sizeof(mdKey), "F%dMd", (int)index);
    }
    NSLog(@"[SMCWrapperObjC] Phase0: Using mode key '%s'", mdKey);

    // ---------- Phase 1: Ftst diagnostic unlock ----------
    // On M3/M4, thermalmonitord enforces "System Mode" (mode 3) which blocks
    // direct writes to the mode key. Writing Ftst=1 signals the daemon to yield.
    // Absent on M5+, where the mode key takes writes directly.
    [self enableFtstUnlockWithError:nil];

    // ---------- Phase 2: Enable force override (FS! bitmask) ----------
    // Intel-era mechanism; absent on M5. A failure here is informational only —
    // the mode key in Phase 3 is what decides success on Apple Silicon.
    SMCVal_t fsReadVal;
    kern_return_t fsReadResult = SMCReadKey(self.connection, "FS! ", &fsReadVal);
    if (fsReadResult == kIOReturnSuccess) {
        UInt16 fsMask = ((UInt16)fsReadVal.bytes[0] << 8) | (UInt16)fsReadVal.bytes[1];
        fsMask |= (1 << index);
        SMCVal_t fsWriteVal = fsReadVal;
        fsWriteVal.bytes[0] = (fsMask >> 8) & 0xFF;
        fsWriteVal.bytes[1] = fsMask & 0xFF;
        kern_return_t fsWriteResult = SMCWriteKey(self.connection, fsWriteVal, NULL);
        NSLog(@"[SMCWrapperObjC] Phase2: FS!  write mask=0x%04X result=%d (%s)",
              fsMask, fsWriteResult, fsWriteResult == kIOReturnSuccess ? "OK" : "FAIL");
    } else {
        NSLog(@"[SMCWrapperObjC] Phase2: FS!  absent (%d) — Apple Silicon path, skipping", fsReadResult);
    }

    // ---------- Phase 3: Set mode key to manual, within the time budget ----------
    // After Ftst=1, thermalmonitord needs time to yield. The mode key write
    // must be retried until it succeeds (typically 3–6 seconds on M3/M4).
    // On M1/M5+ where direct mode works, the first attempt succeeds immediately.
    //
    // The budget is a DEADLINE supplied by the caller rather than a fixed retry
    // count, because the retry loop is per-fan: a fixed 6s budget on a two-fan
    // machine meant a single setFanMode could block for over 13 seconds and
    // outrun the app's XPC timeout. The app then reported the helper as
    // unreachable and sent the user to the "install helper" screen — while the
    // helper was in fact alive and still grinding through retries.
    BOOL modeKeyPresent = (modeKeyFormat != nil);
    BOOL modeSet = modeKeyPresent && [self writeModeKeyValue:1 forIndex:index deadline:deadline];

    if (!modeSet && modeKeyPresent) {
        // The hardware refused manual control within the budget. Report it
        // instead of pretending success: the app used to be told the change
        // applied, show Manual, then snap back to Auto on the next 2s poll
        // when it re-read the real SMC state. That silent bounce is what
        // "fan control never works" looks like from the outside.
        NSLog(@"[SMCWrapperObjC] Phase3: FAILED — %s never accepted manual mode within the time budget", mdKey);
        if (error) {
            *error = [NSError errorWithDomain:SMCWrapperErrorDomain code:SMCWrapperErrorOverrideRefused
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"This Mac's firmware refused manual control of fan %ld.", (long)index]}];
        }
        return NO;
    }

    // ---------- Phase 4: Wait for SMC firmware to register state change ----------
    NSLog(@"[SMCWrapperObjC] Phase4: Sleeping %ld ms for SMC firmware wake...", (long)delayMillis);
    usleep((useconds_t)(delayMillis * 1000));

    // ---------- Phase 5: Write target speed ----------
    // Note: F%dMn and F%dMx are guidelines, not enforced limits.
    // We pass the target RPM through without clamping — the SMC will spin
    // the fan at whatever speed it can physically achieve.
    char tgKey[5];
    snprintf(tgKey, sizeof(tgKey), "F%dTg", (int)index);

    NSError *writeError = nil;
    BOOL writeOK = [self writeFloatKey:tgKey value:rpm error:&writeError];
    NSLog(@"[SMCWrapperObjC] Phase5: %s = %.1f RPM, write result: %s",
          tgKey, rpm, writeOK ? "OK" : "FAIL");

    if (!writeOK) {
        // Retry once after a short delay — some SMC firmware needs extra time
        NSLog(@"[SMCWrapperObjC] Phase5: Write failed, retrying after 100ms...");
        usleep(100 * 1000);
        writeError = nil;
        writeOK = [self writeFloatKey:tgKey value:rpm error:&writeError];
        NSLog(@"[SMCWrapperObjC] Phase5: Retry result: %s", writeOK ? "OK" : "FAIL");
    }

    if (!writeOK) {
        if (error) {
            *error = writeError ?: [NSError errorWithDomain:SMCWrapperErrorDomain code:SMCWrapperErrorWriteFailed
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not set the speed of fan %ld.", (long)index]}];
        }
        return NO;
    }

    // ---------- Phase 6: Diagnostic read-back ----------
    // Log-only, and deliberately NOT a success gate: the SMC serves a stale
    // value for a moment after a target write, so an immediate read routinely
    // reports the OLD speed even when the write took hold and the fan reaches
    // the target seconds later. Treating a mismatch here as failure would
    // reject perfectly good writes.
    double verifyRPM = [self readFloatKey:tgKey];
    NSLog(@"[SMCWrapperObjC] Phase6: Read-back %s = %.1f RPM (wrote %.1f; a stale value here is expected)",
          tgKey, verifyRPM, rpm);

    char acKey[5];
    snprintf(acKey, sizeof(acKey), "F%dAc", (int)index);
    double actualRPM = [self readFloatKey:acKey];
    NSLog(@"[SMCWrapperObjC] Phase6: Current actual speed F%dAc = %.1f RPM", (int)index, actualRPM);

    NSLog(@"[SMCWrapperObjC] === Wake Override complete for Fan %ld ===", (long)index);
    return YES;
}

#pragma mark - Release Override

- (BOOL)releaseFanOverrideForIndex:(NSInteger)index error:(NSError **)error {
    NSLog(@"[SMCWrapperObjC] Releasing override for fan %ld", (long)index);

    // Restore Ftst=0 to re-enable thermalmonitord
    [self disableFtstUnlockWithError:nil];

    // Clear the force bit in FS!  (Intel-era; absent on M5)
    SMCVal_t fsReadVal;
    if (SMCReadKey(self.connection, "FS! ", &fsReadVal) == kIOReturnSuccess) {
        UInt16 fsMask = ((UInt16)fsReadVal.bytes[0] << 8) | (UInt16)fsReadVal.bytes[1];
        fsMask &= ~(1 << index);
        SMCVal_t fsWriteVal = fsReadVal;
        fsWriteVal.bytes[0] = (fsMask >> 8) & 0xFF;
        fsWriteVal.bytes[1] = fsMask & 0xFF;
        SMCWriteKey(self.connection, fsWriteVal, NULL);
        NSLog(@"[SMCWrapperObjC] Released FS!  bit for fan %ld, FS! =0x%04X", (long)index, fsMask);
    }

    // Clear the per-fan mode key — the authoritative release on Apple Silicon.
    // Verified with retry: a single blind write here silently left fans pinned
    // in manual, so "Auto" and the on-quit handoff both appeared to do nothing.
    BOOL released = [self writeModeKeyValue:0
                                   forIndex:index
                                   deadline:[NSDate dateWithTimeIntervalSinceNow:kAirwayReleaseBudgetSeconds]];
    if (!released && [self detectModeKeyFormat] != nil) {
        NSLog(@"[SMCWrapperObjC] WARNING: fan %ld is still under manual control after release", (long)index);
        if (error) {
            *error = [NSError errorWithDomain:SMCWrapperErrorDomain code:SMCWrapperErrorWriteFailed
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"Could not return fan %ld to automatic control.", (long)index]}];
        }
        return NO;
    }
    NSLog(@"[SMCWrapperObjC] Released fan %ld back to system control", (long)index);
    return YES;
}

@end
