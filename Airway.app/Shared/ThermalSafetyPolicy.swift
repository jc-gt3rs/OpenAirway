//
//  ThermalSafetyPolicy.swift
//
//  Sustained-overheat safety override.
//
//  A user-chosen manual speed (or a preset, which is applied as manual) can be
//  too slow for the load the machine is actually under. When that happens the
//  SoC sits pinned at its thermal ceiling because Airway — not macOS — is
//  holding the fans down. This policy watches for that condition and hands the
//  fans to Max until the machine has genuinely cooled off, then gives the
//  user's mode back.
//
//  The policy is a pure value type and takes `now` as a parameter so the whole
//  three-minute window is unit-testable without waiting or live hardware. It
//  lives in Shared/ because the helper daemon runs it (it is the process that
//  is always alive and owns the SMC) while the app needs the same constants to
//  describe what happened.
//

import Foundation

struct ThermalSafetyPolicy {

    /// What the caller should do to the fans right now.
    enum Decision: Equatable {
        /// Keep doing whatever it is doing.
        case none
        /// Take the fans to Max and remember the mode being interrupted.
        case engage
        /// The machine has cooled off — restore the interrupted mode.
        case release
    }

    /// Sustained temperature at or above which the override arms.
    static let triggerTemperature: Double = 90.0
    /// How long the machine must stay at `triggerTemperature` before Max is forced.
    static let sustainedTriggerSeconds: TimeInterval = 180

    /// Temperature the machine must fall to before the override lets go. Well
    /// below the trigger so a machine hovering at the ceiling doesn't flap
    /// between Max and the user's mode.
    static let releaseTemperature: Double = 80.0
    /// How long the machine must stay cool before the user's mode comes back.
    static let sustainedReleaseSeconds: TimeInterval = 60

    /// Readings outside this range are sensor failures, not real temperatures.
    /// `SMCWrapperObjC.systemTemperature` returns 0 when no sensor key decodes,
    /// and 0 must never read as "cold" — that would release a live override.
    private static let plausibleRange: ClosedRange<Double> = 1.0...150.0

    /// Whether the override currently holds the fans at Max.
    private(set) var isEngaged = false

    private var hotSince: Date?
    private var coolSince: Date?

    init() {}

    /// Feeds one temperature sample in and returns the action to take.
    ///
    /// - Parameters:
    ///   - temperature: peak SoC temperature in °C.
    ///   - mode: the mode the fans are in right now.
    ///   - now: the sample's timestamp.
    mutating func evaluate(temperature: Double, mode: FanMode, now: Date) -> Decision {
        // A bad reading tells us nothing. Hold the current state rather than
        // guessing in either direction.
        guard Self.plausibleRange.contains(temperature) else { return .none }

        return isEngaged
            ? evaluateRelease(temperature: temperature, now: now)
            : evaluateEngage(temperature: temperature, mode: mode, now: now)
    }

    /// Clears all accumulated state. Call when the user picks a mode
    /// themselves — their choice restarts the clock and cancels any override.
    mutating func reset() {
        isEngaged = false
        hotSince = nil
        coolSince = nil
    }

    // MARK: - Private

    private mutating func evaluateEngage(temperature: Double, mode: FanMode, now: Date) -> Decision {
        // Only Airway-held manual control can starve the fans. Under `.system`
        // macOS owns thermal management and needs no second-guessing, and
        // `.max` is already the remedy.
        guard mode == .manual, temperature >= Self.triggerTemperature else {
            hotSince = nil
            return .none
        }

        guard let since = hotSince else {
            hotSince = now
            return .none
        }

        guard now.timeIntervalSince(since) >= Self.sustainedTriggerSeconds else {
            return .none
        }

        isEngaged = true
        hotSince = nil
        coolSince = nil
        return .engage
    }

    private mutating func evaluateRelease(temperature: Double, now: Date) -> Decision {
        guard temperature <= Self.releaseTemperature else {
            coolSince = nil
            return .none
        }

        guard let since = coolSince else {
            coolSince = now
            return .none
        }

        guard now.timeIntervalSince(since) >= Self.sustainedReleaseSeconds else {
            return .none
        }

        isEngaged = false
        hotSince = nil
        coolSince = nil
        return .release
    }
}
