//
//  HelperService.swift
//
//
//  Created by John Cris Antor on 6/11/2026.
//

import Foundation
import Security
import SMCBridge
import SMCWrapperObjC

final class HelperService: NSObject, HelperProtocol, NSXPCListenerDelegate {
    private var smc: SMCWrapperObjC?
    private let smcLock = NSLock()

    /// Serialises every SMC operation. The XPC handlers and the thermal
    /// watchdog timer both drive the SMC, and the controller does not tolerate
    /// interleaved read-modify-write sequences from two threads.
    private let operationLock = NSLock()

    /// How long to wait (in ms) after writing FS! /F%dMd before writing target speed.
    /// 200ms gives the SMC firmware plenty of time to register the state transition.
    private static let wakeDelayMillis: Int = 200

    /// Total wall-clock budget for handing manual control over to Airway,
    /// shared across all fans in one `setFanMode` call.
    ///
    /// This is a budget rather than a per-fan retry count because the retry
    /// loop runs once per fan: the old fixed 60×100ms loop meant a two-fan
    /// machine could spend over 13 seconds inside a single `setFanMode` and
    /// outrun the app's XPC reply timeout. The app then declared the helper
    /// unreachable and offered to reinstall it — while the helper was alive and
    /// still retrying. Bounding the total keeps every reply comfortably inside
    /// the client's timeout.
    private static let modeHandoffBudgetSeconds: TimeInterval = 8.0

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard isValidClient(connection: newConnection) else { return false }
        NSLog("[AirwayHelper] Accepted XPC connection from pid \(newConnection.processIdentifier).")
        newConnection.exportedInterface = makeHelperInterface()
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    /// Requirement the connecting process's code signature must satisfy:
    /// the Airway.app bundle identifier, signed by our team, chaining to an
    /// Apple root. Without this, ANY local process could connect to this
    /// root-privileged XPC service and drive fan speeds.
    private static let clientRequirement = "anchor apple generic and identifier \"com.airway.app\" and certificate leaf[subject.OU] = \"N392C48YLY\""

    private func isValidClient(connection: NSXPCConnection) -> Bool {
        var token = connection.auditToken
        let attributes = withUnsafeBytes(of: &token) { raw in
            [kSecGuestAttributeAudit: Data(raw)] as CFDictionary
        }

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            NSLog("[AirwayHelper] Rejected connection from pid \(connection.processIdentifier): could not resolve caller's code.")
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.clientRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            NSLog("[AirwayHelper] Rejected connection: failed to build client code requirement.")
            return false
        }

        let status = SecCodeCheckValidity(code, [], requirement)
        guard status == errSecSuccess else {
            NSLog("[AirwayHelper] Rejected connection from pid \(connection.processIdentifier): failed code requirement check (status \(status)).")
            return false
        }
        return true
    }

    func getVersion(reply: @escaping (String) -> Void) {
        reply(HelperVersion.current)
    }

    func getSystemTemperature(reply: @escaping (Double, Error?) -> Void) {
        do {
            let smc = try getSMC()
            let temp = operationLock.withLock { smc.systemTemperature() }
            reply(temp, nil)
        } catch {
            reply(0, error)
        }
    }

    func getFanInfo(reply: @escaping ([FanInfoDTO], Error?) -> Void) {
        do {
            let smc = try getSMC()
            let results = try operationLock.withLock { try readFanInfo(smc) }
            NSLog("[AirwayHelper] getFanInfo: \(results.map { "Fan\($0.index): \($0.currentRPM)RPM min=\($0.minRPM) max=\($0.maxRPM)" }.joined(separator: ", "))")
            reply(results, nil)
        } catch {
            reply([], error)
        }
    }

    /// Reads live fan state. Caller must hold `operationLock`.
    private func readFanInfo(_ smc: SMCWrapperObjC) throws -> [FanInfoDTO] {
        let count = smc.fanCount()
        if count <= 0 {
            throw AirwayHelperError.error(.noFans, "This Mac reports no controllable fans.")
        }
        // Derive the ACTUAL control mode from live SMC state rather than
        // trusting `currentMode` (which goes stale when macOS silently
        // reclaims fan control after sleep/wake). If no fan is force-
        // overridden, the system holds control and we report `.system`.
        // If any fan is overridden, Airway holds control, so we preserve the
        // user's chosen flavor (`.manual` vs `.max`) from `currentMode`.
        var anyManual = false
        for i in 0..<count where smc.isFanUnderManualControl(index: i) {
            anyManual = true
            break
        }
        let effectiveMode: FanMode
        if anyManual {
            effectiveMode = (currentMode == .system) ? .manual : currentMode
        } else {
            effectiveMode = .system
            if currentMode != .system {
                NSLog("[AirwayHelper] getFanInfo: SMC shows system control but currentMode was \(currentMode.rawValue); resyncing to .system.")
                currentMode = .system
            }
            // The system took the fans back, so there is nothing left for the
            // safety override to hold or restore.
            if thermalPolicy.isEngaged {
                NSLog("[AirwayHelper] System reclaimed fan control — standing down the thermal override.")
                thermalPolicy.reset()
                interruptedMode = nil
            }
        }

        let overrideActive = thermalPolicy.isEngaged
        return (0..<count).map { i in
            FanInfoDTO(
                index: i,
                currentRPM: smc.fanSpeed(for: i),
                minRPM: smc.fanMinSpeed(for: i),
                maxRPM: smc.fanMaxSpeed(for: i),
                mode: effectiveMode,
                thermalOverrideActive: overrideActive
            )
        }
    }

    private var currentMode: FanMode = .system
    /// The percentages backing `currentMode` when it is `.manual`. Kept so the
    /// thermal override can put the user's exact speeds back afterwards.
    private var currentPercentages: [Int] = []

    private func getSMC() throws -> SMCWrapperObjC {
        smcLock.lock()
        defer { smcLock.unlock() }

        if let smc {
            return smc
        }

        // `-initWithError:` bridges to a throwing initializer, so a failure to
        // reach AppleSMC propagates instead of handing back a live-looking
        // object whose every read silently returns 0.
        let openedSMC = try SMCWrapperObjC()
        smc = openedSMC
        NSLog("[AirwayHelper] Opened AppleSMC connection.")
        return openedSMC
    }

    /// Fallback maximum RPM when the SMC reports 0 (common for idle fans on Apple Silicon).
    private static let fallbackMaxRPM: Double = 6500

    func setFanMode(_ mode: FanMode, percentages: [NSNumber], reply: @escaping (Error?) -> Void) {
        let ints = percentages.map { $0.intValue }
        do {
            try operationLock.withLock {
                // A mode the user picked themselves overrides — and cancels —
                // any safety override in flight.
                thermalPolicy.reset()
                interruptedMode = nil
                try applyMode(mode, percentages: ints)
            }
            reply(nil)
        } catch {
            NSLog("[AirwayHelper] setFanMode ERROR: \(error)")
            reply(translate(error))
        }
    }

    /// Maps a low-level SMC failure onto the shared error vocabulary the app
    /// understands, so it can tell "this Mac won't do it" from "the helper is
    /// gone" and stop offering a pointless helper reinstall.
    private func translate(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == SMCWrapperErrorDomain else { return error }
        switch nsError.code {
        case SMCWrapperErrorCode.overrideRefused.rawValue,
             SMCWrapperErrorCode.keyUnavailable.rawValue:
            return AirwayHelperError.error(.fanControlUnsupported, nsError.localizedDescription)
        default:
            return error
        }
    }

    /// Applies a fan mode. Caller must hold `operationLock`.
    private func applyMode(_ mode: FanMode, percentages: [Int]) throws {
        let smc = try getSMC()
        let count = smc.fanCount()
        guard count > 0 else {
            throw AirwayHelperError.error(.noFans, "This Mac reports no controllable fans.")
        }

        NSLog("[AirwayHelper] applyMode: mode=\(mode.rawValue) (\(mode == .system ? "system" : mode == .manual ? "manual" : "max")), percentages=\(percentages), fanCount=\(count)")

        switch mode {
        case .system:
            NSLog("[AirwayHelper] Releasing fan control back to system...")
            try smc.clearAllForceBits()
            for i in 0..<count {
                try smc.releaseFanOverride(index: i)
            }

        case .manual:
            // Split the handoff budget evenly so the total stays bounded no
            // matter how many fans this Mac has.
            let perFanBudget = Self.modeHandoffBudgetSeconds / Double(count)
            for (i, pct) in percentages.enumerated() where i < count {
                var minRPM = smc.fanMinSpeed(for: i)
                var maxRPM = smc.fanMaxSpeed(for: i)

                NSLog("[AirwayHelper] Fan \(i): pct=\(pct)%, min=\(minRPM), max=\(maxRPM)")

                // Use fallback values when SMC reports 0 (idle/stopped fan)
                if maxRPM <= 0 {
                    maxRPM = Self.fallbackMaxRPM
                    NSLog("[AirwayHelper] Fan \(i): maxRPM was 0, using fallback \(maxRPM)")
                }
                if minRPM < 0 { minRPM = 0 }
                if maxRPM <= minRPM {
                    maxRPM = max(minRPM + 1, Self.fallbackMaxRPM)
                    NSLog("[AirwayHelper] Fan \(i): maxRPM <= minRPM, using fallback \(maxRPM)")
                }

                let targetRPM = minRPM + (Double(pct) / 100.0) * (maxRPM - minRPM)
                NSLog("[AirwayHelper] Fan \(i): computed target = \(targetRPM) RPM")

                try smc.setFanSpeedWithWakeOverride(
                    index: i,
                    rpm: targetRPM,
                    delayMillis: Self.wakeDelayMillis,
                    deadline: Date().addingTimeInterval(perFanBudget)
                )
            }

        case .max:
            let perFanBudget = Self.modeHandoffBudgetSeconds / Double(count)
            for i in 0..<count {
                var maxRPM = smc.fanMaxSpeed(for: i)
                if maxRPM <= 0 {
                    maxRPM = Self.fallbackMaxRPM
                    NSLog("[AirwayHelper] Fan \(i): maxRPM was 0, using fallback \(maxRPM)")
                }
                NSLog("[AirwayHelper] Fan \(i): setting to max RPM = \(maxRPM)")
                try smc.setFanSpeedWithWakeOverride(
                    index: i,
                    rpm: maxRPM,
                    delayMillis: Self.wakeDelayMillis,
                    deadline: Date().addingTimeInterval(perFanBudget)
                )
            }
        }

        currentMode = mode
        currentPercentages = (mode == .manual) ? percentages : []
    }

    // MARK: - Sustained-overheat safety override

    private var thermalPolicy = ThermalSafetyPolicy()
    /// The mode the override interrupted, restored once the machine cools.
    private var interruptedMode: (mode: FanMode, percentages: [Int])?
    private var thermalTimer: DispatchSourceTimer?
    private let thermalQueue = DispatchQueue(label: "com.airway.helper.thermal")

    /// How often the machine's temperature is sampled. Well inside the
    /// policy's 60s release window, and cheap — a handful of SMC reads.
    private static let thermalSampleIntervalSeconds: Int = 15

    /// Starts the watchdog that forces Max when the machine sits at
    /// `ThermalSafetyPolicy.triggerTemperature` under an Airway-held manual
    /// speed. It lives in the helper, not the app, because the helper is the
    /// process that is always running and owns the SMC — the protection has to
    /// hold whether or not the menu-bar popover is open, and even if the app
    /// has been quit while an override is still applied.
    func startThermalSafetyMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: thermalQueue)
        timer.schedule(deadline: .now() + .seconds(Self.thermalSampleIntervalSeconds),
                       repeating: .seconds(Self.thermalSampleIntervalSeconds))
        timer.setEventHandler { [weak self] in
            self?.sampleTemperatureForSafety()
        }
        timer.resume()
        thermalTimer = timer
        NSLog("[AirwayHelper] Thermal safety monitor armed: force Max after \(Int(ThermalSafetyPolicy.sustainedTriggerSeconds))s at \(ThermalSafetyPolicy.triggerTemperature)C.")
    }

    private func sampleTemperatureForSafety() {
        // Never queue behind an in-flight fan change: a skipped sample only
        // delays the decision by one interval, and the trigger window is many
        // intervals wide.
        guard operationLock.try() else { return }
        defer { operationLock.unlock() }

        guard let smc = try? getSMC() else { return }

        let temperature = smc.systemTemperature()
        let decision = thermalPolicy.evaluate(temperature: temperature, mode: currentMode, now: Date())

        switch decision {
        case .none:
            return

        case .engage:
            NSLog("[AirwayHelper] THERMAL SAFETY: \(temperature)C sustained for \(Int(ThermalSafetyPolicy.sustainedTriggerSeconds))s under manual control — forcing Max.")
            interruptedMode = (currentMode, currentPercentages)
            do {
                try applyMode(.max, percentages: [])
            } catch {
                NSLog("[AirwayHelper] THERMAL SAFETY: could not force Max: \(error.localizedDescription)")
                // Leave the policy engaged. The fans are still where the user
                // put them, but re-running `applyMode` on the next tick is
                // pointless — `.release` will restore cleanly once it cools,
                // and `interruptedMode` already holds what to go back to.
            }

        case .release:
            guard let previous = interruptedMode else { return }
            NSLog("[AirwayHelper] THERMAL SAFETY: cooled to \(temperature)C — restoring \(previous.mode.rawValue).")
            interruptedMode = nil
            do {
                try applyMode(previous.mode, percentages: previous.percentages)
            } catch {
                NSLog("[AirwayHelper] THERMAL SAFETY: could not restore previous mode: \(error.localizedDescription)")
            }
        }
    }
}
