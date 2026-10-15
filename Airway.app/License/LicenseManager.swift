//
//  LicenseManager.swift
//
//
//  Created by John Cris Antor on 6/20/2026.
//

import Foundation

/// Airway ships in two editions built from the same source.
///
/// - The licensed edition (the `LICENSED` compilation condition) is the signed
///   build sold at airway.fan. It has the trial, license activation, crash
///   reports, in-app feedback and automatic updates.
/// - The open edition is what you get when you build OpenAirway from source.
///   Every feature is unlocked and the app never contacts the Airway server.
enum AirwayEdition {
#if LICENSED
    static let isLicensed = true
#else
    static let isLicensed = false
#endif

    /// Where the open edition sends bug reports and ideas.
    static let issuesURL = URL(string: "https://github.com/jc-gt3rs/OpenAirway/issues")!
}

/// The license states that drive the app's UI and access control.
enum LicenseState: Equatable {
    /// Open edition built from source: every feature, no license needed.
    case unlocked

    /// Initial state — checking keychain on launch.
    case loading

    /// No token found in keychain — prompt for email to start trial.
    case noToken

    /// Beta token — forever valid, no server calls, no expiry checks.
    case beta

    /// Active trial with days remaining (derived from locally verified `exp`).
    case trial(daysRemaining: Int)

    /// Trial has expired — show the paywall.
    case trialExpired

    /// Active paid license with plenty of time remaining.
    case paid

    /// Paid license verification is pending — soft warning, full access continues.
    case paidVerificationPending(String)

    /// Paid license hard-locked after extended grace period of failed verifications.
    case paidLocked

    /// Transient state while an activation request is in flight.
    case activating
}

/// Core license state machine for Airway.
///
/// Uses `ObservableObject` so state observation remains available on macOS 13.
/// All state transitions are driven by local JWT verification first,
/// then selective server calls only when required by the state machine rules.
final class LicenseManager: ObservableObject {
    // MARK: - Published State

    /// The current license state — drives all UI decisions.
    @Published private(set) var state: LicenseState = .loading

    /// Error message from a failed `/license/activate` call.
    /// Surfaced inline in the paywall UI exactly as the server returns it.
    @Published var activationError: String?

    /// Set to true briefly after a successful license activation.
    /// Auto-dismisses after a few seconds.
    @Published var showActivationSuccess: Bool = false

    // MARK: - Display Info

    /// Read-only license details for display (License window). Derived from
    /// the verified token — never from unverified data.
    struct LicenseDisplayInfo {
        let type: LicenseToken.TokenType
        let email: String
        let expiresAt: Date?
        let maxMachines: Int?
    }

    /// Nil when no verified token is present.
    var displayInfo: LicenseDisplayInfo? {
        currentToken.map {
            LicenseDisplayInfo(
                type: $0.type,
                email: $0.email,
                expiresAt: $0.expiresAt,
                maxMachines: $0.maxMachines
            )
        }
    }

    /// Server-reported device usage for this license (active/max). Nil until a
    /// `/license/verify` response includes usage data.
    @Published private(set) var deviceUsage: (active: Int, max: Int)?

    /// Usage row for the License window. The active count comes from `/verify`
    /// when available; otherwise the current signed paid token proves at least
    /// this Mac is active. The plan cap must come from server-authored data.
    var paidDeviceUsageDisplay: (active: Int, max: Int)? {
        guard currentToken?.type == .paid else { return nil }
        guard let max = deviceUsage?.max ?? currentToken?.maxMachines else { return nil }
        return (active: deviceUsage?.active ?? 1, max: max)
    }

    // MARK: - Private State

    /// The raw JWT string currently stored in keychain (cached in-memory for quick access).
    private var currentTokenString: String?

    /// The decoded+verified token (only set after signature verification succeeds).
    private var currentToken: LicenseToken?

    /// Background verification task handle.
    private var verificationTask: Task<Void, Never>?

    /// Background periodic verification timer task.
    private var periodicVerificationTask: Task<Void, Never>?

    /// Background paid device usage refresh task handle.
    private var paidDeviceUsageRefreshTask: Task<Void, Never>?

    /// Saved state before activation, so we can restore it on failure
    /// (e.g. a trial user who fails activation should stay in trial, not trialExpired).
    private var preActivationState: LicenseState?

    /// Timestamp of the last activation attempt — used for rate limiting.
    private var lastActivationAttempt: Date?

    /// Number of consecutive failed activation attempts — drives exponential backoff.
    private var activationAttemptCount: Int = 0

    // MARK: - UserDefaults Keys for Grace Period Tracking

    private enum Defaults {
        static let firstVerificationFailure = "licenseVerificationFirstFailure"
        static let lastVerificationAttempt = "licenseLastVerificationAttempt"
        static let lastTrialVerification = "licenseLastTrialVerification"
        static let lastPaidDeviceUsageVerification = "licenseLastPaidDeviceUsageVerification"
    }

    /// Grace period before hard-locking a paid user (3 days).
    private static let gracePeriodSeconds: TimeInterval = 3 * 24 * 60 * 60

    /// Interval between background verification retries for paid tokens (4 hours).
    private static let verificationRetryInterval: TimeInterval = 4 * 60 * 60

    /// Minimum interval between trial verification calls on launch (5 minutes).
    /// Prevents hammering the server when the user rapidly relaunches the app.
    private static let trialVerificationCooldown: TimeInterval = 5 * 60

    /// Minimum interval between paid usage refresh calls on launch (5 minutes).
    /// Matches the trial countdown refresh cadence.
    private static let paidDeviceUsageVerificationCooldown: TimeInterval = trialVerificationCooldown

    // MARK: - Launch

    /// Called once from `AppDelegate.applicationDidFinishLaunching`.
    /// Loads the keychain, verifies the token signature, and evaluates the initial state.
    @MainActor
    func checkLicenseOnLaunch() {
        guard AirwayEdition.isLicensed else {
            NSLog("[Airway] Open edition: all features unlocked, no license checks.")
            state = .unlocked
            return
        }

        let tokenString = KeychainStore.loadToken()

        guard let tokenString, !tokenString.isEmpty else {
            NSLog("[Airway] No license token in keychain.")
            state = .noToken
            return
        }

        // Verify ES256 signature — never trust claims without this.
        guard let token = TokenVerifier.verify(token: tokenString) else {
            NSLog("[Airway] Stored token failed signature verification — discarding.")
            KeychainStore.deleteToken()
            state = .noToken
            return
        }

        currentTokenString = tokenString
        currentToken = token
        evaluateVerifiedToken(token, rawToken: tokenString)
    }

    // MARK: - State Evaluation

    /// Given a signature-verified token, determines the correct license state.
    @MainActor
    private func evaluateVerifiedToken(_ token: LicenseToken, rawToken: String, shouldVerifyTrial: Bool = true) {
        switch token.type {
        case .beta:
            // Beta tokens are unconditionally valid. No server calls, no expiry checks.
            // Beta testers were promised the app forever.
            NSLog("[Airway] Beta license — full access, no verification needed.")
            state = .beta

        case .trial:
            let remaining = daysRemaining(until: token.expiresAt)
            if remaining > 0 {
                NSLog("[Airway] Trial license — \(remaining) days remaining.")
                state = .trial(daysRemaining: remaining)
                // Ask the server whether the trial is still valid. Revocation is
                // immediate (no grace period for trials) but network failures are
                // silent — an offline user must not be locked out.
                if shouldVerifyTrial {
                    triggerBackgroundTrialVerification(rawToken: rawToken, force: true)
                }
            } else {
                NSLog("[Airway] Trial license expired.")
                state = .trialExpired
            }

        case .paid:
            let remaining = daysRemaining(until: token.expiresAt)
            if remaining > 7 {
                // Plenty of time — full access. Refresh display-only device
                // usage on launch, subject to a short cooldown.
                NSLog("[Airway] Paid license — \(remaining) days until expiry, refreshing device usage if needed.")
                state = .paid
                clearVerificationFailures()
                triggerPaidDeviceUsageRefresh(rawToken: rawToken)
            } else {
                // Within 7 days of expiry or already expired — verify in background.
                NSLog("[Airway] Paid license — \(remaining) days until expiry, triggering background verification.")
                // Grant access immediately while verification runs.
                state = .paid
                triggerBackgroundVerification(rawToken: rawToken)
            }
        }

        // Start periodic verification for paid tokens
        if token.type == .paid {
            startPeriodicVerification()
        }
    }

    /// Calculates the number of whole days remaining until a given expiry date.
    /// Returns `Int.max` if `expiresAt` is nil (beta tokens).
    private func daysRemaining(until expiresAt: Date?) -> Int {
        guard let expiresAt else { return Int.max }
        let seconds = expiresAt.timeIntervalSince(Date())
        if seconds <= 0 { return 0 }
        return Int(seconds / 86400)
    }

    // MARK: - Trial Flow

    /// Starts a trial for the given email.
    /// Called from the trial email entry UI.
    @MainActor
    func startTrial(email: String) async {
        guard AirwayEdition.isLicensed else { return }
        let machineId = MachineID.platformUUID
        // Sanitize input — trim whitespace and strip control characters.
        let sanitizedEmail = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map { String($0) }
            .joined()
        state = .loading
        activationError = nil

        do {
            let tokenString = try await LicenseAPIClient.startTrial(email: sanitizedEmail, machineId: machineId)

            // Verify the token we just received from the server
            guard let token = TokenVerifier.verify(token: tokenString) else {
                NSLog("[Airway] Server returned a token that fails local verification — this should never happen.")
                state = .noToken
                return
            }

            KeychainStore.save(token: tokenString)
            currentTokenString = tokenString
            currentToken = token
            evaluateVerifiedToken(token, rawToken: tokenString)

        } catch let error as LicenseAPIError {
            NSLog("[Airway] Trial start failed: \(error.localizedDescription)")
            // Replace generic server messages with user-friendly text
            if case .serverRejection(_, let message) = error {
                let lower = message.lowercased()
                if lower.contains("bad request") || lower.contains("invalid") {
                    activationError = "Please enter a valid email address."
                } else {
                    activationError = message
                }
            } else {
                activationError = error.localizedDescription
            }
            state = .noToken
        } catch {
            NSLog("[Airway] Trial start failed: \(error.localizedDescription)")
            activationError = error.localizedDescription
            state = .noToken
        }
    }

    // MARK: - Activation Flow (Paywall)

    /// Activates a paid license with the given email and license key.
    /// Called from the paywall UI when the user submits their credentials.
    ///
    /// Includes rate limiting with exponential backoff to prevent brute-force attacks.
    @MainActor
    func activateLicense(email: String, licenseKey: String) async {
        guard AirwayEdition.isLicensed else { return }

        // --- Rate limiting ---
        // Enforce exponential backoff: 2s, 4s, 8s, 16s, 30s max between attempts.
        if let lastAttempt = lastActivationAttempt {
            let backoffSeconds = min(30.0, pow(2.0, Double(activationAttemptCount)))
            let elapsed = Date().timeIntervalSince(lastAttempt)
            if elapsed < backoffSeconds {
                let waitSeconds = Int(ceil(backoffSeconds - elapsed))
                activationError = "Too many attempts. Please wait \(waitSeconds) second\(waitSeconds == 1 ? "" : "s") before trying again."
                return
            }
        }

        let machineId = MachineID.platformUUID
        // Sanitize inputs — trim whitespace and strip control characters.
        let sanitizedEmail = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map { String($0) }
            .joined()
        let sanitizedKey = licenseKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map { String($0) }
            .joined()
        activationError = nil
        // Save current state so we can restore it on failure
        preActivationState = state
        state = .activating
        lastActivationAttempt = Date()

        do {
            let tokenString = try await LicenseAPIClient.activate(
                email: sanitizedEmail,
                licenseKey: sanitizedKey,
                machineId: machineId
            )

            // Verify the token we just received
            guard let token = TokenVerifier.verify(token: tokenString) else {
                NSLog("[Airway] Activation returned an unverifiable token.")
                activationError = "Received an invalid token from the server. Please try again."
                activationAttemptCount += 1
                state = preActivationState ?? .trialExpired
                return
            }

            // Success — reset rate limiting
            activationAttemptCount = 0
            KeychainStore.save(token: tokenString)
            currentTokenString = tokenString
            currentToken = token
            clearVerificationFailures()

            // Show success feedback briefly
            showActivationSuccess = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                showActivationSuccess = false
            }

            evaluateVerifiedToken(token, rawToken: tokenString)

        } catch let error as LicenseAPIError {
            // Surface the server's error message — replace generic "bad request" with helpful text.
            NSLog("[Airway] Activation failed: \(error.localizedDescription)")
            activationAttemptCount += 1
            if case .serverRejection(_, let message) = error {
                let lower = message.lowercased()
                if lower.contains("bad request") {
                    activationError = "Invalid email or license key. Please check your credentials."
                } else {
                    activationError = message
                }
            } else {
                activationError = error.localizedDescription
            }
            // Restore the state from before activation — don't force trialExpired
            state = preActivationState ?? .trialExpired
        } catch {
            NSLog("[Airway] Activation failed: \(error.localizedDescription)")
            activationAttemptCount += 1
            activationError = error.localizedDescription
            // Restore the state from before activation
            state = preActivationState ?? .trialExpired
        }
    }

    // MARK: - Trial Verification

    /// Forces a fresh server check for the active trial token.
    ///
    /// Useful when a UI surface appears while the app is already running: trial
    /// expiry is server-authoritative, and the visible countdown should follow
    /// any refreshed JWT returned by `/license/verify`.
    @MainActor
    func refreshTrialStatusFromServer() {
        guard let tokenString = currentTokenString,
              let token = currentToken,
              token.type == .trial else { return }
        triggerBackgroundTrialVerification(rawToken: tokenString, force: true)
    }

    /// Fires a background server check for trial tokens on every launch,
    /// optionally subject to a cooldown to avoid hammering the server on rapid restarts.
    @MainActor
    private func triggerBackgroundTrialVerification(rawToken: String, force: Bool = false) {
        let defaults = UserDefaults.standard
        let lastCheck = defaults.double(forKey: Defaults.lastTrialVerification)
        let elapsed = Date().timeIntervalSince1970 - lastCheck
        guard force || elapsed >= Self.trialVerificationCooldown else {
            NSLog("[Airway] Trial verification skipped — last check was \(Int(elapsed))s ago (cooldown: \(Int(Self.trialVerificationCooldown))s).")
            return
        }
        defaults.set(Date().timeIntervalSince1970, forKey: Defaults.lastTrialVerification)
        NSLog("[Airway] Trial verification — triggering background server check.")
        verificationTask?.cancel()
        verificationTask = Task {
            await performTrialVerification(rawToken: rawToken)
        }
    }

    /// Verifies a trial token with the server.
    ///
    /// Outcomes:
    /// - `valid: true`  → stay in trial (optionally store refreshed token).
    /// - `valid: false` → flip to `.trialExpired` immediately.
    /// - Network failure → silent; offline users must not be locked out.
    @MainActor
    private func performTrialVerification(rawToken: String) async {
        let machineId = MachineID.platformUUID
        do {
            let response = try await LicenseAPIClient.verify(token: rawToken, machineId: machineId)
            if response.valid {
                // Trial is still active on the server. If a refreshed token was
                // returned, store it and re-evaluate state so the "X days
                // remaining" count reflects the server's expiresAt.
                if let newTokenString = response.token,
                   let verified = TokenVerifier.verify(token: newTokenString) {
                    KeychainStore.save(token: newTokenString)
                    currentTokenString = newTokenString
                    currentToken = verified
                    NSLog("[Airway] Trial verified and token refreshed — re-evaluating state.")
                    evaluateVerifiedToken(verified, rawToken: newTokenString, shouldVerifyTrial: false)
                } else {
                    NSLog("[Airway] Trial verified by server, but no usable refreshed token was returned; keeping existing countdown.")
                }
            } else {
                // Server explicitly revoked the trial.
                let reason = response.reason ?? "Trial is no longer valid."
                NSLog("[Airway] Server revoked trial: \(reason)")
                state = .trialExpired
            }
        } catch let error as LicenseAPIError where error.isNetworkFailure {
            // Network failure — NOT a revocation. Stay in trial silently.
            NSLog("[Airway] Trial verification network failure (silent — not a revocation): \(error.localizedDescription)")
        } catch {
            NSLog("[Airway] Trial verification unexpected error (silent): \(error.localizedDescription)")
        }
    }

    // MARK: - Paid Verification

    /// Refreshes paid device usage on app launch so the License window can show
    /// the latest database-backed maxMachines without waiting for near-expiry
    /// verification. Network failures are silent because this refresh is
    /// display-oriented; explicit server rejections still count.
    @MainActor
    private func triggerPaidDeviceUsageRefresh(rawToken: String, force: Bool = false) {
        let defaults = UserDefaults.standard
        let lastCheck = defaults.double(forKey: Defaults.lastPaidDeviceUsageVerification)
        let elapsed = Date().timeIntervalSince1970 - lastCheck
        guard force || elapsed >= Self.paidDeviceUsageVerificationCooldown else {
            NSLog("[Airway] Paid device usage refresh skipped — last check was \(Int(elapsed))s ago (cooldown: \(Int(Self.paidDeviceUsageVerificationCooldown))s).")
            return
        }
        defaults.set(Date().timeIntervalSince1970, forKey: Defaults.lastPaidDeviceUsageVerification)
        NSLog("[Airway] Paid device usage refresh — triggering background server check.")
        paidDeviceUsageRefreshTask?.cancel()
        paidDeviceUsageRefreshTask = Task {
            await performPaidDeviceUsageRefresh(rawToken: rawToken)
        }
    }

    /// Performs a launch-time paid usage refresh for the License window.
    @MainActor
    private func performPaidDeviceUsageRefresh(rawToken: String) async {
        let machineId = MachineID.platformUUID

        do {
            let response = try await LicenseAPIClient.verify(token: rawToken, machineId: machineId)

            if response.valid {
                applyPaidVerificationSuccess(response)
                clearVerificationFailures()
                state = .paid
            } else {
                let reason = response.reason ?? "License could not be verified."
                NSLog("[Airway] Server rejected license during paid device usage refresh: \(reason)")
                handleVerificationFailure(message: reason)
            }
        } catch let error as LicenseAPIError where error.isNetworkFailure {
            NSLog("[Airway] Paid device usage refresh network failure (silent): \(error.localizedDescription)")
        } catch {
            NSLog("[Airway] Paid device usage refresh unexpected error (silent): \(error.localizedDescription)")
        }
    }

    /// Triggers a background verification call for a paid token.
    /// Never blocks the UI — access continues while this runs.
    @MainActor
    private func triggerBackgroundVerification(rawToken: String) {
        verificationTask?.cancel()
        verificationTask = Task {
            await performVerification(rawToken: rawToken)
        }
    }

    /// Performs the actual verification call and handles all outcomes.
    @MainActor
    private func performVerification(rawToken: String) async {
        let machineId = MachineID.platformUUID

        do {
            let response = try await LicenseAPIClient.verify(token: rawToken, machineId: machineId)

            if response.valid {
                // Server confirmed the license is valid.
                applyPaidVerificationSuccess(response)
                clearVerificationFailures()
                state = .paid
            } else {
                // Server explicitly said `valid: false`.
                let reason = response.reason ?? "License could not be verified."
                NSLog("[Airway] Server rejected license: \(reason)")
                handleVerificationFailure(message: reason)
            }

        } catch let error as LicenseAPIError where error.isNetworkFailure {
            // Network failure — NOT a denial. Retry later, keep access.
            NSLog("[Airway] Verification network failure (not a denial): \(error.localizedDescription)")
            handleVerificationFailure(message: "License could not be verified — please check your connection.")

        } catch {
            // Unexpected error — treat as network failure (benefit of the doubt).
            NSLog("[Airway] Verification unexpected error: \(error.localizedDescription)")
            handleVerificationFailure(message: "License could not be verified — please check your connection.")
        }
    }

    /// Applies a valid paid `/license/verify` response to local display state.
    @MainActor
    private func applyPaidVerificationSuccess(_ response: VerifyResponse) {
        // Store the refreshed token if provided.
        if let newToken = response.token {
            if let verified = TokenVerifier.verify(token: newToken) {
                KeychainStore.save(token: newToken)
                currentTokenString = newToken
                currentToken = verified
                NSLog("[Airway] Paid license verified and token refreshed.")
            } else {
                // Refreshed token fails verification — keep the old one but consider it valid.
                NSLog("[Airway] Refreshed token failed verification, keeping existing token.")
            }
        }

        let maxMachines = response.maxMachines ?? currentToken?.maxMachines
        if let maxMachines {
            let activeCount = response.deviceCount ?? deviceUsage?.active ?? 1
            deviceUsage = (active: activeCount, max: maxMachines)
        }
    }

    /// Handles a verification failure (either server rejection or network failure).
    /// Tracks the grace period and only hard-locks after several days of consistent failures.
    @MainActor
    private func handleVerificationFailure(message: String) {
        let defaults = UserDefaults.standard

        // Record the first failure time if not already set.
        if defaults.object(forKey: Defaults.firstVerificationFailure) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: Defaults.firstVerificationFailure)
        }
        defaults.set(Date().timeIntervalSince1970, forKey: Defaults.lastVerificationAttempt)

        // Check if the grace period has been exceeded.
        let firstFailure = defaults.double(forKey: Defaults.firstVerificationFailure)
        let elapsed = Date().timeIntervalSince1970 - firstFailure

        if elapsed > Self.gracePeriodSeconds {
            NSLog("[Airway] Grace period exceeded (\(Int(elapsed / 86400)) days) — locking.")
            state = .paidLocked
        } else {
            let daysLeft = Int(ceil((Self.gracePeriodSeconds - elapsed) / 86400))
            NSLog("[Airway] Verification pending — \(daysLeft) grace day(s) remaining.")
            state = .paidVerificationPending(message)
        }
    }

    /// Clears the verification failure tracking in UserDefaults.
    private func clearVerificationFailures() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Defaults.firstVerificationFailure)
        defaults.removeObject(forKey: Defaults.lastVerificationAttempt)
    }

    // MARK: - Periodic Background Verification

    /// Starts a periodic task that retries verification every few hours for paid tokens.
    private func startPeriodicVerification() {
        periodicVerificationTask?.cancel()
        periodicVerificationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.verificationRetryInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard let self,
                      let tokenString = self.currentTokenString,
                      let token = self.currentToken,
                      token.type == .paid else { break }

                // Only retry verification if we're in a pending or near-expiry state
                let remaining = self.daysRemaining(until: token.expiresAt)
                if remaining <= 7 {
                    await MainActor.run {
                        self.triggerBackgroundVerification(rawToken: tokenString)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Whether the current license state grants full app access.
    var hasFullAccess: Bool {
        switch state {
        case .unlocked, .beta, .trial, .paid, .paidVerificationPending:
            return true
        case .loading, .noToken, .trialExpired, .paidLocked, .activating:
            return false
        }
    }

    /// The number of trial days remaining, if in a trial state.
    var trialDaysRemaining: Int? {
        if case .trial(let days) = state { return days }
        return nil
    }

    deinit {
        verificationTask?.cancel()
        periodicVerificationTask?.cancel()
        paidDeviceUsageRefreshTask?.cancel()
    }
}
