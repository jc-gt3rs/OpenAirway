//
//  AirwayIntentError.swift
//
//  Errors and shared plumbing for Airway's App Intents (Siri / Shortcuts).
//

import Foundation
import AppIntents

/// Failures surfaced back to Siri / the Shortcuts app when an intent can't run.
/// Each case's message is what the user hears or sees, so keep it plain.
enum AirwayIntentError: LocalizedError {
    /// The app hasn't finished launching in time to service the intent.
    case appNotReady
    /// The user has no active license/trial — intents honor the same paywall as the UI.
    case licenseRequired
    /// The privileged fan-control helper didn't respond.
    case helperUnreachable
    /// A Shortcut referenced a preset that has since been deleted or renamed.
    case presetNotFound(String)

    var errorDescription: String? {
        let loc = LocalizationManager.shared
        switch self {
        case .appNotReady:
            return loc.t("intent_error_app_not_ready")
        case .licenseRequired:
            return loc.t("intent_error_license_required")
        case .helperUnreachable:
            return loc.t("intent_error_helper_unreachable")
        case .presetNotFound(let name):
            return loc.t("intent_error_preset_not_found", name)
        }
    }
}

/// Shared entry points every intent uses before touching fan state.
enum AirwayIntentSupport {
    /// Waits (briefly) for the app to finish launching, then returns the live
    /// `AppDelegate`. When a Shortcut or Siri phrase fires while Airway isn't
    /// running, the system launches it to execute the in-process intent; this
    /// bridges the small window before `applicationDidFinishLaunching` sets
    /// `AppDelegate.shared`.
    @MainActor
    static func readyApp(timeout: TimeInterval = 8) async throws -> AppDelegate {
        if let app = AppDelegate.shared { return app }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            if let app = AppDelegate.shared { return app }
        }
        throw AirwayIntentError.appNotReady
    }

    /// Enforces the same license gate as the rest of the app — intents must not
    /// be a paywall bypass.
    @MainActor
    static func requireLicense(_ app: AppDelegate) throws {
        guard app.licenseManager.hasFullAccess else {
            throw AirwayIntentError.licenseRequired
        }
    }

    /// Runs a view-model fan action, remapping the low-level helper/XPC failure
    /// into a user-legible `helperUnreachable` for Siri / Shortcuts.
    @MainActor
    static func runFanAction(_ action: () async throws -> Void) async throws {
        do {
            try await action()
        } catch let error as AirwayIntentError {
            throw error
        } catch {
            NSLog("[Airway] Intent fan action failed: \(error.localizedDescription)")
            throw AirwayIntentError.helperUnreachable
        }
    }
}
