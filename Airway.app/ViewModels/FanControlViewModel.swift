//
//  FanControlViewModel.swift
//  
//
//  Created by John Cris Antor on 6/11/2026.
//

import Foundation
import SwiftUI
import ServiceManagement

final class FanControlViewModel: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting
        case connected
        /// Helper is registered but macOS is waiting for the user to approve
        /// it in System Settings → General → Login Items.
        case needsApproval
        case error(String)
    }

    private enum DefaultsKey {
        static let showRPMInMenuBar = "showRPMInMenuBar"
        static let showTempInMenuBar = "showTempInMenuBar"
        static let showIconInMenuBar = "showIconInMenuBar"
    }

    @Published var fans: [FanInfoDTO] = []
    @Published var sliderPercentages: [Int] = []
    @Published var activeMode: FanMode = .system
    @Published var connectionState: ConnectionState = .connecting
    
    let presetStore = PresetStore()
    @Published var isApplyingChange: Bool = false
    @Published var isInstallingHelper: Bool = false
    @Published var systemTemperature: Double = 0.0

    /// Localization key for a fan change this Mac refused, shown inline above
    /// the controls.
    ///
    /// Deliberately NOT `connectionState`: a refused fan write used to be
    /// reported as a connection error, which renders the "Enable the helper"
    /// screen. The user watched their Manual/Max tap turn into a helper
    /// reinstall prompt and then bounce back to the fan list — the helper was
    /// never the problem.
    @Published var lastActionErrorKey: String?

    /// True while the helper's sustained-overheat override is holding the fans
    /// at Max, so the UI can explain why Max is lit when the user chose Manual.
    @Published var thermalOverrideActive: Bool = false

    // Keep menu-bar preferences in UserDefaults while publishing changes through
    // ObservableObject, which is available throughout the supported OS range.
    var showRPMInMenuBar: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.showRPMInMenuBar) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.showRPMInMenuBar)
            enforceMenuBarVisibility()
        }
    }
    
    var showTempInMenuBar: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.showTempInMenuBar) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.showTempInMenuBar)
            enforceMenuBarVisibility()
        }
    }

    var showIconInMenuBar: Bool {
        get {
            if !canHideMenuBarIcon { return true }
            return UserDefaults.standard.bool(forKey: DefaultsKey.showIconInMenuBar)
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue || !canHideMenuBarIcon, forKey: DefaultsKey.showIconInMenuBar)
        }
    }

    var canHideMenuBarIcon: Bool {
        showRPMInMenuBar || showTempInMenuBar
    }
    
    var useFahrenheit: Bool {
        get { UserDefaults.standard.bool(forKey: "useFahrenheit") }
        set { UserDefaults.standard.set(newValue, forKey: "useFahrenheit") }
    }
    
    var fineTuneManualOverride: Bool {
        get { UserDefaults.standard.bool(forKey: "fineTuneManualOverride") }
        set { UserDefaults.standard.set(newValue, forKey: "fineTuneManualOverride") }
    }
    
    var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            } else {
                return false // Fallback for older macOS
            }
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        if SMAppService.mainApp.status == .enabled { return }
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("[Airway] Failed to toggle launch at login: \(error)")
                }
            } else {
                // Not supported on older macOS using SMAppService
            }
        }
    }

    private let client = HelperClient.shared
    private var refreshTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    /// Consecutive refresh failures. The "Enable the helper" screen is
    /// reserved for a helper that is actually broken, so a single transient
    /// miss (daemon spawning, launch repair, sleep/wake) never surfaces it.
    private var consecutiveRefreshFailures = 0

    init() {
        UserDefaults.standard.register(defaults: [
            DefaultsKey.showIconInMenuBar: true
        ])
        enforceMenuBarVisibility()

        // macOS silently reclaims fan control across sleep/wake. Refresh
        // immediately on wake so the active mode button reflects real SMC
        // ownership without waiting for the next 2s poll.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isApplyingChange else { return }
            Task { @MainActor in await self.refresh() }
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func enforceMenuBarVisibility() {
        if !showRPMInMenuBar && !showTempInMenuBar {
            UserDefaults.standard.set(true, forKey: DefaultsKey.showIconInMenuBar)
        }
    }

    @MainActor
    func startMonitoring() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                // Skip refresh while a fan change is in-flight to avoid
                // racing the blocked helper XPC queue.
                if !isApplyingChange {
                    await refresh()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopMonitoring() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    @MainActor
    func refresh() async {
        do {
            async let fansTask = client.fetchFanInfo()
            async let tempTask = client.fetchSystemTemperature()
            
            let info = try await fansTask
            let temp = try await tempTask
            
            self.fans = info
            self.systemTemperature = temp
            
            // Reconcile the UI against the ACTUAL control state the helper
            // reports (it reads live SMC state). This must NOT depend on our own
            // previous `activeMode`: on a fresh launch activeMode is already
            // .system while a stale active preset may have been restored from
            // UserDefaults, and on the first refresh the slider-count branch
            // below would otherwise skip the reconciliation entirely.
            let reportedMode = info.first?.mode ?? .system
            if sliderPercentages.count != info.count {
                sliderPercentages = info.map { percentage(for: $0) }
            } else if reportedMode == .system {
                // Auto mode is controlled by macOS, so keep the sliders synced
                // to the live SMC speeds instead of leaving them at the last
                // manual/max/preset value.
                sliderPercentages = info.map { percentage(for: $0) }
            }
            // If the system actually holds control, no manual mode or preset is
            // active. Clear any lingering active-preset selection — e.g. one
            // restored from a previous session after the app handed control back
            // to the system on quit — so the Auto button lights up correctly.
            if reportedMode == .system && presetStore.activePresetID != nil {
                presetStore.activePresetID = nil
            }
            self.activeMode = reportedMode
            self.thermalOverrideActive = info.first?.thermalOverrideActive ?? false
            self.connectionState = .connected
            self.consecutiveRefreshFailures = 0
        } catch {
            // Don't surface connection errors while a fan change is being
            // applied — the helper's XPC queue is blocked handling setFanMode
            // and fetchFanInfo will naturally time out. Likewise, keep the
            // "needs approval" guidance on screen while the user is still in
            // System Settings — a successful connect will clear it naturally.
            if !isApplyingChange && connectionState != .needsApproval {
                consecutiveRefreshFailures += 1
                if consecutiveRefreshFailures >= 2 {
                    self.connectionState = .error(error.localizedDescription)
                }
            }
        }
    }

    /// Routes a failed fan change to the right place.
    ///
    /// Hardware that refuses manual control is a real, permanent-ish answer
    /// about this Mac — it belongs in an inline message next to the controls.
    /// Only a helper we genuinely could not reach justifies tearing down the
    /// fan UI for the "Enable the helper" screen.
    @MainActor
    private func report(_ error: Error) {
        if AirwayHelperError.isHardwareRefusal(error) {
            // The daemon's own message is English-only and too technical for
            // the popover, so it goes to the log and the user sees a
            // translated one-liner.
            NSLog("[Airway] Fan change refused by hardware: \(error.localizedDescription)")
            lastActionErrorKey = "popover_fan_control_unsupported"
        } else {
            connectionState = .error(error.localizedDescription)
        }
    }

    @MainActor
    func installOrRepairHelper() async {
        guard !isInstallingHelper else { return }
        isInstallingHelper = true
        connectionState = .connecting
        defer { isInstallingHelper = false }

        let client = self.client
        do {
            try await Task.detached {
                try client.installOrRepairHelper(forceRepair: true)
            }.value
        } catch HelperClient.HelperInstallError.requiresApproval {
            // No password/Touch ID needed — macOS just wants the user to flip
            // the switch in System Settings → Login Items. Take them there.
            connectionState = .needsApproval
            client.openHelperApprovalSettings()
            return
        } catch {
            // Registration reported a problem, but the daemon may still be
            // reachable (status can settle late). Fall through and let the
            // connection attempts below decide, keeping the error for later.
            NSLog("[Airway] Helper install reported: \(error.localizedDescription)")
        }

        // The launchd daemon can take a moment to finish spinning up after a
        // fresh SMAppService registration. Retry the first connection instead
        // of flashing back to the "Enable" screen on a single transient XPC
        // failure right after install.
        for attempt in 1...5 {
            await refresh()
            if connectionState == .connected { return }
            if attempt < 5 {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    func openHelperApprovalSettings() {
        client.openHelperApprovalSettings()
    }

    @MainActor
    func applyManualSpeed(fanIndex: Int, percentage: Int) async {
        guard fans.indices.contains(fanIndex) else { return }
        sliderPercentages[fanIndex] = percentage
        isApplyingChange = true
        lastActionErrorKey = nil
        defer { isApplyingChange = false }

        do {
            try await client.setMode(.manual, percentages: sliderPercentages)
            activeMode = .manual
            presetStore.activePresetID = nil
        } catch {
            report(error)
        }
    }

    /// Ensures `fans` is populated. The popover drives polling via
    /// `startMonitoring()`, so when an action originates OUTSIDE the popover
    /// (an App Intent from Siri / Shortcuts fired before the popover was ever
    /// opened) `fans` can still be empty. Fetch it directly in that case so
    /// preset/manual math has real hardware bounds to work with. Rethrows the
    /// helper error if it stays unreachable.
    @MainActor
    func ensureFansLoaded() async throws {
        if !fans.isEmpty { return }
        let info = try await client.fetchFanInfo()
        self.fans = info
        if sliderPercentages.count != info.count {
            sliderPercentages = info.map { percentage(for: $0) }
        }
    }

    @MainActor
    func setMaxSpeed() async throws {
        isApplyingChange = true
        lastActionErrorKey = nil
        defer { isApplyingChange = false }
        try await ensureFansLoaded()
        sliderPercentages = Array(repeating: 100, count: fans.count)
        do {
            try await client.setMode(.max, percentages: sliderPercentages)
            activeMode = .max
            presetStore.activePresetID = nil
        } catch {
            report(error)
            throw error
        }
    }

    @MainActor
    func setManualMode() async {
        isApplyingChange = true
        lastActionErrorKey = nil
        defer { isApplyingChange = false }
        do {
            try await client.setMode(.manual, percentages: sliderPercentages)
            activeMode = .manual
            presetStore.activePresetID = nil
        } catch {
            report(error)
        }
    }

    @MainActor
    func returnToSystemControl() async throws {
        isApplyingChange = true
        lastActionErrorKey = nil
        defer { isApplyingChange = false }
        do {
            try await client.setMode(.system, percentages: [])
            activeMode = .system
            presetStore.activePresetID = nil
        } catch {
            report(error)
            throw error
        }
    }

    @MainActor
    func applyPreset(_ preset: Preset) async throws {
        isApplyingChange = true
        lastActionErrorKey = nil
        defer { isApplyingChange = false }
        try await ensureFansLoaded()
        guard !fans.isEmpty else { return }

        let percentages: [Int]
        switch preset.mode {
        case .percentage:
            percentages = Array(repeating: preset.value, count: fans.count)
        case .rpm:
            percentages = fans.map { fan in
                guard fan.maxRPM > fan.minRPM else { return 25 }
                let ratio = (Double(preset.value) - fan.minRPM) / (fan.maxRPM - fan.minRPM)
                return max(25, min(100, Int((ratio * 100).rounded())))
            }
        }

        sliderPercentages = percentages
        do {
            try await client.setMode(.manual, percentages: percentages)
            activeMode = .manual
            presetStore.activePresetID = preset.id
        } catch {
            report(error)
            throw error
        }
    }

    /// Nudges every fan's manual speed by a relative number of percentage
    /// points, switching into manual mode from whatever speed the fans are
    /// actually at right now. Backs the Increase/Decrease Fan Speed intents.
    /// Result is clamped to the 25–100% manual range.
    @MainActor
    func adjustFanSpeed(byPercentagePoints delta: Int) async throws {
        isApplyingChange = true
        lastActionErrorKey = nil
        defer { isApplyingChange = false }
        try await ensureFansLoaded()
        guard !fans.isEmpty else { return }

        // Start from the fans' current actual speeds so a nudge is relative to
        // reality, not a stale slider value.
        let base = fans.map { percentage(for: $0) }
        let adjusted = base.map { Self.nudgedPercentage(from: $0, by: delta) }

        sliderPercentages = adjusted
        do {
            try await client.setMode(.manual, percentages: adjusted)
            activeMode = .manual
            presetStore.activePresetID = nil
        } catch {
            report(error)
            throw error
        }
    }

    /// Pure nudge math for the Increase/Decrease Fan Speed intents: shifts a
    /// manual percentage by `delta` points, clamped to the 25–100% range the
    /// rest of the app enforces for manual control.
    static func nudgedPercentage(from current: Int, by delta: Int) -> Int {
        max(25, min(100, current + delta))
    }

    private func percentage(for fan: FanInfoDTO) -> Int {
        guard fan.maxRPM > fan.minRPM else { return 25 }
        let ratio = (fan.currentRPM - fan.minRPM) / (fan.maxRPM - fan.minRPM)
        return max(25, Int((ratio * 100).rounded()))
    }
}
