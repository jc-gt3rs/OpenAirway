//
//  LicenseViews.swift
//
//
//  Created by John Cris Antor on 6/20/2026.
//

import SwiftUI



// MARK: - Input Validation

/// Client-side input validation and sanitization utilities.
/// All user inputs are validated before being sent to the server to provide
/// immediate feedback and prevent malformed/malicious data from reaching the API.
/// Internal (not private) so the onboarding flow reuses the same rules.
enum InputValidator {
    /// RFC 5322 simplified email regex — catches the vast majority of invalid emails.
    private static let emailRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$")
    
    /// Validates an email address format.
    static func validateEmail(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return LocalizationManager.shared.t("license_err_email_empty") }
        if trimmed.count > 254 { return LocalizationManager.shared.t("license_err_email_too_long") }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        guard emailRegex.firstMatch(in: trimmed, options: [], range: range) != nil else {
            return LocalizationManager.shared.t("license_err_email_invalid")
        }
        return nil // valid
    }

    /// Validates a license key format (non-empty, alphanumeric + dashes, reasonable length).
    static func validateLicenseKey(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return LocalizationManager.shared.t("license_err_key_empty") }
        if trimmed.count < 4 { return LocalizationManager.shared.t("license_err_key_too_short") }
        if trimmed.count > 256 { return LocalizationManager.shared.t("license_err_key_too_long") }
        // Allow alphanumeric, dashes, and underscores only — blocks SQL injection characters
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return LocalizationManager.shared.t("license_err_key_invalid_chars")
        }
        return nil // valid
    }

    /// Sanitizes a string by trimming whitespace and removing control characters.
    static func sanitize(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map { String($0) }
            .joined()
    }
}

// MARK: - Trial Email Entry (first launch)

/// Shown when no token exists — collects an email to start the free trial.
struct TrialEmailEntryView: View {
    @ObservedObject var licenseManager: LicenseManager
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var email = ""
    @State private var isLoading = false
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: AirwaySymbol.fan.resolved)
                .font(.system(size: 36))
                .foregroundColor(.secondary)
                .padding(.bottom, 4)

            Text(loc.t("license_welcome"))
                .font(.headline)

            Text(loc.t("license_trial_prompt"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            TextField(loc.t("license_email_placeholder"), text: $email)
                .textFieldStyle(.roundedBorder)
                .onChange(of: email) { _ in
                    // Clear validation error as user types
                    validationError = nil
                    licenseManager.activationError = nil
                }

            if let error = validationError ?? licenseManager.activationError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                let sanitizedEmail = InputValidator.sanitize(email)
                if let error = InputValidator.validateEmail(sanitizedEmail) {
                    validationError = error
                    return
                }
                validationError = nil
                isLoading = true
                Task {
                    await licenseManager.startTrial(email: sanitizedEmail)
                    isLoading = false
                }
            } label: {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(loc.t("license_start_trial"))
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(LicenseButtonStyle(tint: .accentColor))
            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
        }
        .padding(24)
        .frame(width: 320)
    }
}

// MARK: - Trial Banner (shown during active trial)

/// Non-intrusive banner displayed at the bottom of the popover during an active trial.
struct TrialBannerView: View {
    let daysRemaining: Int
    var onActivateEarly: () -> Void
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Button(action: onActivateEarly) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(daysRemaining == 1 ? loc.t("license_day_remaining") : loc.t("license_days_remaining", daysRemaining))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(loc.t("license_activate"))
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Color.accentColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Paywall (trial expired or early activation)

/// Full paywall view with email + license key entry.
/// Shows different messaging depending on whether the trial is still active (early activation)
/// or has already expired.
struct PaywallView: View {
    @ObservedObject var licenseManager: LicenseManager
    @ObservedObject private var loc = LocalizationManager.shared
    /// When true, the trial is still active and the user chose to activate early.
    var isEarlyActivation: Bool = false
    @State private var email = ""
    @State private var licenseKey = ""
    @State private var validationError: String?

    private var isActivating: Bool {
        licenseManager.state == .activating
    }

    var body: some View {
        VStack(spacing: 16) {
            Image("AboutIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .padding(.bottom, 4)

            Text(isEarlyActivation ? loc.t("license_trial_ending") : loc.t("license_trial_ended"))
                .font(.headline)

            Text(isEarlyActivation
                 ? loc.t("license_activate_prompt_ending")
                 : loc.t("license_activate_prompt_ended"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                TextField(loc.t("license_email_placeholder"), text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isActivating)
                    .onChange(of: email) { _ in
                        validationError = nil
                        licenseManager.activationError = nil
                    }

                TextField(loc.t("license_key_placeholder"), text: $licenseKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isActivating)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: licenseKey) { _ in
                        validationError = nil
                        licenseManager.activationError = nil
                    }
            }

            if let error = validationError ?? licenseManager.activationError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                let sanitizedEmail = InputValidator.sanitize(email)
                let sanitizedKey = InputValidator.sanitize(licenseKey)

                if let emailError = InputValidator.validateEmail(sanitizedEmail) {
                    validationError = emailError
                    return
                }
                if let keyError = InputValidator.validateLicenseKey(sanitizedKey) {
                    validationError = keyError
                    return
                }
                validationError = nil

                Task {
                    await licenseManager.activateLicense(email: sanitizedEmail, licenseKey: sanitizedKey)
                }
            } label: {
                if isActivating {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(loc.t("license_activate_license"))
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(LicenseButtonStyle(tint: .accentColor))
            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || isActivating)

            Button(loc.t("license_get_license")) {
                if let url = URL(string: "https://airway.fan") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.caption)
            .foregroundColor(Color.accentColor)
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(width: 320)
    }
}

// MARK: - Activation Success Banner

/// Non-intrusive green banner shown briefly after successful license activation.
struct ActivationSuccessBannerView: View {
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption2)
                .foregroundColor(.green)

            Text(loc.t("license_activated_success"))
                .font(.caption)
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.green.opacity(0.1))
        )
    }
}

// MARK: - Verification Warning (paid, pending verification)

/// Non-intrusive amber warning bar shown when paid license verification is pending.
/// Does NOT block any app functionality.
struct VerificationWarningView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundColor(.orange)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }
}

// MARK: - License Locked (paid, grace period exceeded)

/// Full-screen lock view shown after extended verification failure.
struct LicenseLockedView: View {
    @ObservedObject var licenseManager: LicenseManager
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var email = ""
    @State private var licenseKey = ""
    @State private var validationError: String?

    private var isActivating: Bool {
        licenseManager.state == .activating
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundColor(.orange)
                .padding(.bottom, 4)

            Text(loc.t("license_verification_required"))
                .font(.headline)

            Text("Your license could not be verified for an extended period. Please re-enter your credentials or check your internet connection.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                TextField(loc.t("license_email_placeholder"), text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isActivating)
                    .onChange(of: email) { _ in
                        validationError = nil
                        licenseManager.activationError = nil
                    }

                TextField(loc.t("license_key_placeholder"), text: $licenseKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isActivating)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: licenseKey) { _ in
                        validationError = nil
                        licenseManager.activationError = nil
                    }
            }

            if let error = validationError ?? licenseManager.activationError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                let sanitizedEmail = InputValidator.sanitize(email)
                let sanitizedKey = InputValidator.sanitize(licenseKey)

                if let emailError = InputValidator.validateEmail(sanitizedEmail) {
                    validationError = emailError
                    return
                }
                if let keyError = InputValidator.validateLicenseKey(sanitizedKey) {
                    validationError = keyError
                    return
                }
                validationError = nil

                Task {
                    await licenseManager.activateLicense(email: sanitizedEmail, licenseKey: sanitizedKey)
                }
            } label: {
                if isActivating {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(loc.t("license_reactivate"))
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(LicenseButtonStyle(tint: .accentColor))
            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || isActivating)

            Button(loc.t("license_contact_support")) {
                if let url = URL(string: "mailto:support@airbender.com") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(width: 320)
    }
}

// MARK: - Shared Button Style

/// Styled button matching the existing Airway glass aesthetic.
struct LicenseButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
