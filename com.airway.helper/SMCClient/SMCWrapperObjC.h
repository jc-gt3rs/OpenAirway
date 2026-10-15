#import <Foundation/Foundation.h>
#import <bsm/audit.h>

NS_ASSUME_NONNULL_BEGIN

/// `-[NSXPCConnection auditToken]` exists in the ObjC runtime but Apple has
/// never exposed it in the public headers, so Swift can't see it. Redeclaring
/// it here (implementation already lives in the runtime — no .m needed) lets
/// the helper read the connecting process's audit token to verify its code
/// signature. The audit token is the race-free identifier for the peer;
/// `processIdentifier` (PID) is reusable and must not be used for this.
@interface NSXPCConnection (AirwayAuditToken)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

/// Error domain for every failure this wrapper reports.
extern NSString * const SMCWrapperErrorDomain;

typedef NS_ENUM(NSInteger, SMCWrapperErrorCode) {
    /// Could not open a connection to AppleSMC at all.
    SMCWrapperErrorConnectionFailed = 1,
    /// The key needed for this operation isn't present on this hardware.
    SMCWrapperErrorKeyUnavailable = 2,
    /// The SMC firmware refused to hand over manual control of the fan.
    /// Distinct from a transport failure: the helper is healthy and reachable,
    /// the hardware simply said no, so the app must NOT treat it as a broken
    /// helper and send the user off to reinstall it.
    SMCWrapperErrorOverrideRefused = 3,
    /// A key write failed.
    SMCWrapperErrorWriteFailed = 4,
};

@interface SMCWrapperObjC : NSObject

- (nullable instancetype)initWithError:(NSError **)error;

- (NSInteger)fanCount;
- (double)fanSpeedForIndex:(NSInteger)index;
- (double)fanMinSpeedForIndex:(NSInteger)index;
- (double)fanMaxSpeedForIndex:(NSInteger)index;

- (double)systemTemperature;

- (BOOL)setFanTargetSpeedForIndex:(NSInteger)index rpm:(double)rpm error:(NSError **)error NS_SWIFT_NAME(setFanTargetSpeed(index:rpm:));
- (BOOL)setManualMode:(BOOL)enabled fanCount:(NSInteger)fanCount error:(NSError **)error NS_SWIFT_NAME(setManualMode(enabled:fanCount:));

/// Reads the current `FS! ` force bitmask, sets or clears the bit for the given fan index,
/// and writes it back. This is the proper read-modify-write sequence needed to wake an idle fan.
- (BOOL)setForceBitForFanIndex:(NSInteger)index enabled:(BOOL)enabled error:(NSError **)error NS_SWIFT_NAME(setForceBit(fanIndex:enabled:));

/// Clears all bits in the `FS! ` force bitmask, returning full fan control to the system.
- (BOOL)clearAllForceBitsWithError:(NSError **)error NS_SWIFT_NAME(clearAllForceBits());

/// All-in-one: takes manual control of the fan, waits for the SMC to register
/// it, writes the target speed, and verifies. This is the recommended method
/// for controlling a fan that may be idle.
///
/// Returns NO (with `error` set to `SMCWrapperErrorOverrideRefused`) when the
/// hardware would not grant manual control before `deadline`. It does not
/// report success for an override that never engaged.
///
/// - Parameter deadline: the wall-clock instant at which to stop retrying the
///   manual-mode handoff. Callers must size this so the total across all fans
///   stays inside the app's XPC reply timeout.
- (BOOL)setFanSpeedWithWakeOverrideForIndex:(NSInteger)index
                                        rpm:(double)rpm
                                delayMillis:(NSInteger)delayMillis
                                   deadline:(NSDate *)deadline
                                      error:(NSError **)error NS_SWIFT_NAME(setFanSpeedWithWakeOverride(index:rpm:delayMillis:deadline:));

/// Releases override for a single fan: clears FS!  bit and F%dMd, then sets target to 0.
- (BOOL)releaseFanOverrideForIndex:(NSInteger)index error:(NSError **)error NS_SWIFT_NAME(releaseFanOverride(index:));

/// Writes `Ftst=1` to unlock manual fan control on Apple Silicon (M3/M4).
/// On M5+ where Ftst is absent, this is a no-op that returns YES.
- (BOOL)enableFtstUnlockWithError:(NSError **)error NS_SWIFT_NAME(enableFtstUnlock());

/// Writes `Ftst=0` to restore system thermal management.
- (BOOL)disableFtstUnlockWithError:(NSError **)error NS_SWIFT_NAME(disableFtstUnlock());

/// Detects the correct mode key format for this hardware, probing lowercase
/// first. Returns "F%dmd" (M5+) or "F%dMd" (M4 and earlier), whichever is
/// readable, or nil if neither variant is present. Cached after the first call.
- (nullable NSString *)detectModeKeyFormat;

/// Reads the ACTUAL current SMC control state for a fan and reports whether it
/// is under manual/forced override (YES) or system thermal control (NO).
///
/// This reads live hardware state — the `FS! ` force bitmask (authoritative when
/// readable), falling back to the per-fan mode key (`F%dMd`/`F%dmd`) — rather
/// than trusting any value the app previously set. This is what lets the UI
/// detect that macOS silently reclaimed fan control after sleep/wake.
- (BOOL)isFanUnderManualControlForIndex:(NSInteger)index NS_SWIFT_NAME(isFanUnderManualControl(index:));

@end

NS_ASSUME_NONNULL_END
