//
//  LicenseWindow.swift
//
//  Standalone License window, opened from the popover's dynamic
//  "License" / "Activate License" button.
//
//  State-driven content:
//  - paid / beta / verification-pending → "activated" summary: big headline,
//    who it's licensed to, expiry, and device usage.
//  - anything else (trial, expired, no token) → the existing PaywallView
//    activation form, so activation lives in this window rather than
//    squeezed into the popover.
//

import SwiftUI
import AppKit

// MARK: - Detail view

struct LicenseDetailView: View {
    @ObservedObject var licenseManager: LicenseManager
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Group {
            switch licenseManager.state {
            case .unlocked, .paid, .paidVerificationPending, .beta:
                activatedView
            default:
                // Activation form. `isEarlyActivation` only while a trial is
                // still running (matches the popover's early-paywall wording).
                if case .trial = licenseManager.state {
                    PaywallView(licenseManager: licenseManager, isEarlyActivation: true)
                } else {
                    PaywallView(licenseManager: licenseManager)
                }
            }
        }
        .frame(minWidth: 320)
    }

    private var activatedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .padding(.top, 28)

            Text(loc.t("license_window_activated_title"))
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Device usage. The cap comes from server-authored license data so
            // multi-device plans can vary per purchase.
            if licenseManager.displayInfo?.type == .paid,
               let usage = licenseManager.paidDeviceUsageDisplay {
                Text(loc.t("license_window_devices", usage.active, usage.max))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                if let info = licenseManager.displayInfo {
                    Text(loc.t("license_window_email", info.email))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if info.type == .beta {
                        Text(loc.t("license_window_beta"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else if info.type == .trial, let expiresAt = info.expiresAt {
                        Text(loc.t("license_window_expires",
                                   expiresAt.formatted(date: .abbreviated, time: .omitted)))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.top, 2)

            if case .paidVerificationPending(let message) = licenseManager.state {
                VerificationWarningView(message: message)
                    .padding(.horizontal, 16)
            }

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(minHeight: 240)
    }
}

// MARK: - Window controller

/// Hosts LicenseDetailView in a standalone window. Mirrors
/// FeedbackWindowController so "License" opens like "Send Feedback…" does.
final class LicenseWindowController: NSWindowController {
    static let shared = LicenseWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.keepVisibleAcrossAppsAndSpaces()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        self.init(window: window)
    }

    func show(licenseManager: LicenseManager) {
        guard let window else { return }

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .menu
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active

        let hostingView = NSHostingView(
            rootView: LicenseDetailView(licenseManager: licenseManager)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
        ])

        window.contentView = visualEffect

        // Size to the content's natural height (width fixed at 320).
        let fitting = hostingView.fittingSize
        window.setContentSize(NSSize(width: 320, height: fitting.height > 0 ? fitting.height : 420))
        window.center()

        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
