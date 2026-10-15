//
//  OnboardingView.swift
//
//  First-launch onboarding window, styled after macOS's device-showcase
//  welcome screens. The hero is a placeholder (a literal crossed-out box)
//  until real showcase art per feature is ready. Captions page beneath the
//  hero — four feature pages, then a final page that collects the trial
//  email and starts the trial via the same LicenseManager path the popover
//  uses.
//

import SwiftUI
import AppKit

// MARK: - Onboarding pages

private struct OnboardingPage {
    let title: String
    let subtitle: String
}

// MARK: - Root view

struct OnboardingView: View {
    @ObservedObject var licenseManager: LicenseManager
    @ObservedObject private var loc = LocalizationManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onFinished: () -> Void = {}

    @State private var page = 0
    @State private var isGoingBack = false
    @State private var email = ""
    @State private var validationError: String?
    @State private var isLoading = false

    /// Computed (not stored) so a runtime language change re-renders the copy.
    private var onboardingPages: [OnboardingPage] {
        [
            .init(title: loc.t("onboarding_fans_title"),
                  subtitle: loc.t("onboarding_fans_subtitle")),
            .init(title: loc.t("onboarding_presets_title"),
                  subtitle: loc.t("onboarding_presets_subtitle")),
            .init(title: loc.t("onboarding_siri_title"),
                  subtitle: loc.t("onboarding_siri_subtitle")),
            .init(title: loc.t("onboarding_menubar_title"),
                  subtitle: loc.t("onboarding_menubar_subtitle")),
            .init(title: loc.t("onboarding_page3_title"),
                  subtitle: loc.t("onboarding_page3_subtitle")),
        ]
    }

    private var isLastPage: Bool { page == onboardingPages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch OnboardingHeroPresentation.presentation(
                    for: page,
                    reduceMotion: reduceMotion
                ) {
                case .demoVideo(let resourceName, let fileExtension, let shouldPlay):
                    LoopingVideoView(
                        resourceName: resourceName,
                        fileExtension: fileExtension,
                        shouldPlay: shouldPlay
                    )
                    .id(resourceName)
                    .frame(
                        width: OnboardingVideoGeometry.width(forHeight: 300),
                        height: 300
                    )
                    .accessibilityHidden(true)
                case .placeholder:
                    PlaceholderShowcaseBox()
                        .frame(height: 300)
                        .padding(.horizontal, 72)
                }
            }
                .padding(.top, 36)

            // Caption / email area — fixed height so paging never shifts the hero.
            ZStack {
                captionArea
            }
            .frame(height: 150)
            .padding(.horizontal, 56)

            Spacer(minLength: 0)

            footer
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .frame(width: 640, height: 560)
        .onChange(of: licenseManager.state) { newState in
            // Trial (or any full-access state) started — onboarding is done.
            switch newState {
            case .unlocked, .trial, .beta, .paid:
                onFinished()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var captionArea: some View {
        let current = onboardingPages[page]
        VStack(spacing: 10) {
            Text(current.title)
                .font(.system(size: 24, weight: .bold))

            if isLastPage {
                VStack(spacing: 8) {
                    Text(current.subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    TextField(loc.t("license_email_placeholder"), text: $email)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onChange(of: email) { _ in
                            validationError = nil
                            licenseManager.activationError = nil
                        }
                        .onSubmit(startTrial)

                    if let error = validationError ?? licenseManager.activationError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                Text(current.subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(page) // new identity per page so the transition animates
        .transition(.asymmetric(
            insertion: .move(edge: isGoingBack ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: isGoingBack ? .trailing : .leading).combined(with: .opacity)
        ))
    }

    private var footer: some View {
        HStack {
            // Page dots
            HStack(spacing: 7) {
                ForEach(onboardingPages.indices, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.primary.opacity(0.8) : Color.primary.opacity(0.22))
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            // Back — hidden (not just disabled) on the first page so the
            // primary button keeps its position without a dead control beside it.
            if page > 0 {
                Button(action: goBack) {
                    Text(loc.t("onboarding_back"))
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 70, height: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isLoading)
                .transition(.opacity)
            }

            Button(action: advance) {
                Group {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(isLastPage ? loc.t("license_start_trial") : loc.t("onboarding_continue"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(width: isLastPage ? 130 : 100, height: 20)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLastPage && (email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading))
        }
    }

    private func advance() {
        if isLastPage {
            startTrial()
        } else {
            isGoingBack = false
            withAnimation(.spring(duration: 0.35)) { page += 1 }
        }
    }

    private func goBack() {
        guard page > 0 else { return }
        isGoingBack = true
        withAnimation(.spring(duration: 0.35)) { page -= 1 }
    }

    private func startTrial() {
        let sanitized = InputValidator.sanitize(email)
        if let error = InputValidator.validateEmail(sanitized) {
            validationError = error
            return
        }
        validationError = nil
        isLoading = true
        Task { @MainActor in
            await licenseManager.startTrial(email: sanitized)
            isLoading = false
        }
    }
}

// MARK: - Placeholder hero

/// A literal placeholder: a dashed rounded box with an X through it, where
/// the per-feature showcase art will eventually go. Deliberately unstyled so
/// nobody mistakes it for final design. (The previous vector MacBook showcase
/// lives in git history if it's ever wanted back.)
struct PlaceholderShowcaseBox: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        Color.secondary.opacity(0.5),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )

                // The X
                Path { p in
                    let inset: CGFloat = 2
                    p.move(to: CGPoint(x: inset, y: inset))
                    p.addLine(to: CGPoint(x: geo.size.width - inset, y: geo.size.height - inset))
                    p.move(to: CGPoint(x: geo.size.width - inset, y: inset))
                    p.addLine(to: CGPoint(x: inset, y: geo.size.height - inset))
                }
                .stroke(Color.secondary.opacity(0.35), lineWidth: 2)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}

// MARK: - Window

/// Hosts OnboardingView in a standalone welcome window on first launch.
/// Mirrors the About/Feedback window pattern.
final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()

    static let hasSeenOnboardingKey = "hasSeenOnboarding"

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
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

    /// Shows the onboarding window and marks it as seen.
    func show(licenseManager: LicenseManager) {
        guard let window else { return }
        UserDefaults.standard.set(true, forKey: Self.hasSeenOnboardingKey)

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .underWindowBackground
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active

        let hostingView = NSHostingView(
            rootView: OnboardingView(licenseManager: licenseManager,
                                     onFinished: { [weak self] in self?.window?.close() })
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])
        window.contentView = visualEffect
        window.setContentSize(NSSize(width: 640, height: 560))
        window.center()

        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
