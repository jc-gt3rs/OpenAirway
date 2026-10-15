//
//  FanControlPopoverView.swift
//  
//
//  Created by John Cris Antor on 6/11/2026.
//

import SwiftUI
import Combine
import AppKit

private struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A scroll view we fully own (rather than SwiftUI's `ScrollView`) so the
/// overlay scroller is deterministic. Hosts arbitrary SwiftUI content and
/// reports that content's natural (unclamped) endpoint height through a binding,
/// so the parent can decide when to leave scrollable mode.
///
/// The floating **overlay** scroller is set once at creation (and re-asserted if
/// AppKit's global scroller style flips, e.g. "Show scroll bars: Always"). Since
/// we own the instance it never gets recreated out from under us, so there's no
/// legacy frame and the bar never reserves layout width — the popover doesn't
/// resize when it appears. AppKit's own machinery then handles the ghost fade
/// (knob visible while scrolling, invisible at rest).
private struct OverlayScrollView<Content: View>: NSViewRepresentable {
    @Binding var contentHeight: CGFloat
    let maxHeight: CGFloat
    let content: Content

    init(contentHeight: Binding<CGFloat>, maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self._contentHeight = contentHeight
        self.maxHeight = maxHeight
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Keep the document view at its natural height so overflow scrolls.
        // Height is measured only after state reaches an endpoint; measuring on
        // every animation frame creates an AppKit/SwiftUI layout feedback loop.
        hosting.sizingOptions = .intrinsicContentSize
        scrollView.documentView = hosting

        // Canonical macOS constraint-based scroll setup: pin the document view
        // to the clip view (`contentView`) on top/leading/trailing and match its
        // width, leaving the height intrinsic so the overflow is what scrolls.
        // The clip view handles the scroll translation, so these constraints do
        // not fight the scroll offset. Width-matching keeps content from
        // reflowing between the scrollable and non-scrollable states.
        let clipView = scrollView.contentView
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: clipView.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            hosting.widthAnchor.constraint(equalTo: clipView.widthAnchor),
        ])
        context.coordinator.hosting = hosting
        context.coordinator.attach(to: scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let hosting = context.coordinator.hosting else { return }
        hosting.rootView = content
        // Measure once after the updated root view has laid out. While content
        // remains taller than the viewport there is nothing to report; when it
        // reaches or drops below the cap, one binding write exits scroll mode.
        let report: (CGFloat) -> Void = { height in
            let h = height.rounded()
            guard h > 0, h <= maxHeight, abs(h - contentHeight) > 1 else { return }
            contentHeight = h
        }
        DispatchQueue.main.async { report(hosting.fittingSize.height) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hosting: NSHostingView<Content>?
        private var observers: [NSObjectProtocol] = []

        func attach(to scrollView: NSScrollView) {
            // Re-assert overlay if AppKit flips the global scroller style (e.g.
            // the user changes "Show scroll bars"), so the bar never reverts to
            // the legacy space-reserving style.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak scrollView] _ in
                scrollView?.scrollerStyle = .overlay
            })

            // Belt-and-suspenders ghost flash: nudge the overlay knob visible on
            // every scroll tick. Harmless if AppKit already auto-flashes; ensures
            // the knob shows even when the document view is an NSHostingView.
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak scrollView] _ in
                scrollView?.flashScrollers()
            })

        }
        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

/// Defaults key for the "Disable liquid glass" option. When set, the popover
/// and its glass-styled controls render solid fills instead of translucent
/// materials.
let disableLiquidGlassKey = "disableLiquidGlass"

struct FanControlPopoverView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var viewModel: FanControlViewModel
    @ObservedObject var licenseManager: LicenseManager
    @ObservedObject var updateManager: AppUpdateManager
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var optionsDisclosure = PopoverDisclosureState()
    @State private var isOptionsContentVisible = false
    @State private var isOptionsHovered = false
    @State private var isOptionsPressed = false
    @State private var languageDisclosure = PopoverDisclosureState()
    @State private var isLanguageContentVisible = false
    @State private var isLanguageHovered = false
    @State private var isLanguagePressed = false
    @State private var measuredContentHeight: CGFloat = 0
    @State private var overflowState = PopoverOverflowState()
    @AppStorage("showModeSymbols") private var showModeSymbols = true
    @AppStorage(disableLiquidGlassKey) private var disableLiquidGlass = false
    @AppStorage(AppearanceMode.defaultsKey) private var appearanceModeRaw = AppearanceMode.system.rawValue

    private var currentLanguageLabel: String {
        loc.language == .system ? loc.t("language_system") : loc.language.nativeName
    }

    private var disclosureAnimation: Animation {
        .easeOut(duration: disclosureAnimationDuration)
    }

    private var disclosureAnimationDuration: TimeInterval {
        0.14
    }

    private func afterDisclosureAnimation(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + disclosureAnimationDuration, execute: action)
    }

    /// "Activate License" until the license is activated; then "License" so the
    /// user can always check their license details.
    private var licenseButtonTitle: String {
        switch licenseManager.state {
        case .beta, .paid, .paidVerificationPending:
            return loc.t("popover_license")
        default:
            return loc.t("popover_activate_license")
        }
    }

    private var updateButtonTitle: String {
        switch updateManager.state {
        case .idle:
            return loc.t("popover_check_for_updates")
        case .checking:
            return loc.t("popover_checking_for_updates")
        case .upToDate:
            return loc.t("popover_up_to_date")
        case .updateAvailable(let version):
            return loc.t("popover_update_available", version)
        case .downloading(_, let progress):
            guard let progress else { return loc.t("popover_downloading_update") }
            return loc.t("popover_downloading_update_progress", Int(progress * 100))
        case .readyToInstall(let version):
            return loc.t("popover_update_now", version)
        case .installing:
            return loc.t("popover_installing_update")
        case .error:
            return loc.t("popover_update_failed")
        }
    }

    /// Space available between the menu bar and the Dock (or bottom of
    /// screen), minus a small margin for the popover's own inset.
    private var maxPopoverHeight: CGFloat {
        (NSScreen.screens.first?.visibleFrame.height ?? 600) - 24
    }

    var body: some View {
        VStack(spacing: 0) {
            switch licenseManager.state {
            case .unlocked, .beta, .trial, .paid, .paidVerificationPending, .activating:
                fanControlContent
            default:
                // Unlicensed states (.noToken, .trialExpired, .paidLocked, .loading)
                // should never reach the popover — togglePopover intercepts them
                // and opens the License window or onboarding instead. This is a
                // safety fallback.
                loadingView
            }
        }
        // Solid interior instead of the popover's translucent blur when the
        // user has disabled liquid glass. The popover's own chrome still clips
        // this to its rounded shape.
        .background((disableLiquidGlass || !liquidGlassSupported) ? Color(nsColor: .windowBackgroundColor) : Color.clear)
    }
    
    /// The main fan control UI — shown when the license grants full access.
    /// Becomes scrollable only once its measured content would push past the
    /// Dock (or bottom of screen); otherwise it stays content-sized as before.
    ///
    /// The non-overflowing path stays a plain `.fixedSize` view. Disclosure
    /// layout changes only at animation endpoints, avoiding frame-by-frame
    /// popover resizing while the lightweight presentation animates.
    private var fanControlContent: some View {
        VStack(spacing: 0) {
            if overflowState.isOverflowing {
                OverlayScrollView(contentHeight: $measuredContentHeight, maxHeight: maxPopoverHeight) {
                    fanControlInnerContent
                }
                // Keep the viewport capped while overflowing. Endpoint
                // measurement switches back to the natural-height branch after
                // collapsed content fits again.
                .frame(height: min(max(measuredContentHeight, 1), maxPopoverHeight))
            } else {
                fanControlInnerContent
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
            // Only trust the SwiftUI preference in the non-scroll branch. In
            // scroll mode the content lives inside our own NSScrollView, so this
            // preference collapses to its default (0); height then comes from
            // OverlayScrollView's binding instead.
            guard !overflowState.isOverflowing else { return }
            measuredContentHeight = height
        }
        .onChange(of: measuredContentHeight) { _ in
            overflowState.update(
                contentHeight: measuredContentHeight,
                maxHeight: maxPopoverHeight
            )
        }
    }

    private var fanControlInnerContent: some View {
        VStack(spacing: 16) {
                header

                // License status banners
                if licenseManager.showActivationSuccess {
                    ActivationSuccessBannerView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                if case .paidVerificationPending(let message) = licenseManager.state {
                    VerificationWarningView(message: message)
                }
                
                switch viewModel.connectionState {
                case .connecting:
                    connectingView
                case .needsApproval:
                    needsApprovalView
                case .error(let message):
                    errorView(message)
                case .connected:
                    if viewModel.fans.isEmpty {
                        noFanDetectedView
                    } else {
                        if viewModel.thermalOverrideActive {
                            inlineNotice(
                                loc.t("popover_thermal_override"),
                                systemImage: "thermometer.high",
                                tint: .orange
                            )
                        }
                        if let errorKey = viewModel.lastActionErrorKey {
                            inlineNotice(
                                loc.t(errorKey),
                                systemImage: "exclamationmark.triangle",
                                tint: .secondary
                            )
                        }
                        fanList
                        actionButtons
                        presetSection
                    }
                }
                
                // Trial banner
                if case .trial(let daysRemaining) = licenseManager.state {
                    TrialBannerView(daysRemaining: daysRemaining) {
                        LicenseWindowController.shared.show(licenseManager: licenseManager)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                
                VStack(spacing: 0) {
                    Divider()
                        .padding(.bottom, 6)
                    
                    PlainTextHoverButton(title: loc.t("popover_add_preset")) {
                        PresetWindowController.shared.showWindow(viewModel: viewModel)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .padding(.horizontal, -12)
                    
                    HStack(alignment: .center) {
                        Text(loc.t("popover_options"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(isOptionsHovered ? .primary : .secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(isOptionsHovered ? .primary : .secondary)
                            .rotationEffect(.degrees(isOptionsContentVisible ? 90 : 0))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill((isOptionsHovered && !isOptionsPressed) ? Color.primary.opacity(0.1) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .onHover { hovering in
                        if !isOptionsPressed {
                            isOptionsHovered = hovering
                        }
                    }
                    .onTapGesture {
                        toggleOptionsDisclosure()
                    }
                    .padding(.horizontal, -12)
                    
                    settingsFooter
                        .opacity(isOptionsContentVisible ? 1 : 0)
                        .offset(y: isOptionsContentVisible ? 0 : -4)
                        .padding(.top, optionsDisclosure.isExpanded ? 8 : 0)
                        .padding(.bottom, optionsDisclosure.isExpanded ? 10 : 0)
                        .frame(maxHeight: optionsDisclosure.isExpanded ? .none : 0, alignment: .top)
                        .clipped()
                        .allowsHitTesting(optionsDisclosure.isExpanded)

                    HStack(alignment: .center) {
                        Text(loc.t("popover_language"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(isLanguageHovered ? .primary : .secondary)
                        Spacer()
                        Text(currentLanguageLabel)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(isLanguageHovered ? .primary : .secondary)
                            .rotationEffect(.degrees(isLanguageContentVisible ? 90 : 0))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill((isLanguageHovered && !isLanguagePressed) ? Color.primary.opacity(0.1) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .onHover { hovering in
                        if !isLanguagePressed {
                            isLanguageHovered = hovering
                        }
                    }
                    .onTapGesture {
                        toggleLanguageDisclosure()
                    }
                    .padding(.horizontal, -12)

                    languageFooter
                        .opacity(isLanguageContentVisible ? 1 : 0)
                        .offset(y: isLanguageContentVisible ? 0 : -4)
                        .padding(.top, languageDisclosure.isExpanded ? 8 : 0)
                        .padding(.bottom, languageDisclosure.isExpanded ? 10 : 0)
                        .frame(maxHeight: languageDisclosure.isExpanded ? .none : 0, alignment: .top)
                        .clipped()
                        .allowsHitTesting(languageDisclosure.isExpanded)

                    if AirwayEdition.isLicensed {
                        PlainTextHoverButton(title: licenseButtonTitle) {
                            LicenseWindowController.shared.show(licenseManager: licenseManager)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        .padding(.horizontal, -12)
                    }

                    // The open edition has no feedback server, so feedback goes
                    // to the OpenAirway issue tracker on GitHub.
                    PlainTextHoverButton(title: loc.t("popover_send_feedback")) {
                        if AirwayEdition.isLicensed {
                            FeedbackWindowController.shared.show()
                            NSApp.activate(ignoringOtherApps: true)
                        } else {
                            NSWorkspace.shared.open(AirwayEdition.issuesURL)
                        }
                    }
                    .padding(.horizontal, -12)

                    if AirwayEdition.isLicensed {
                        PlainTextHoverButton(title: updateButtonTitle) {
                            if case .readyToInstall = updateManager.state {
                                updateManager.installUpdateNow()
                            } else {
                                updateManager.checkForUpdates()
                            }
                        }
                        .padding(.horizontal, -12)
                        .disabled(!updateManager.state.canPerformAction)
                    }

                    PlainTextHoverButton(title: loc.t("popover_about")) {
                        AboutWindowController.shared.showWindow(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .padding(.horizontal, -12)

                    PlainTextHoverButton(title: loc.t("popover_close"), hoverColor: Color(red: 225/255, green: 44/255, blue: 18/255)) {
                        NSApplication.shared.terminate(nil)
                    }
                    .padding(.horizontal, -12)
                }
                .padding(.bottom, -10)
        }
        .padding(16)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ContentHeightPreferenceKey.self, value: geo.size.height)
            }
        )
    }

    private func toggleOptionsDisclosure() {
        guard !isOptionsPressed else { return }
        isOptionsPressed = true

        if reduceMotion {
            optionsDisclosure.toggle()
            isOptionsContentVisible = optionsDisclosure.isExpanded
            isOptionsPressed = false
        } else if optionsDisclosure.isExpanded {
            withAnimation(disclosureAnimation) {
                isOptionsContentVisible = false
            }
            afterDisclosureAnimation {
                optionsDisclosure.toggle()
                isOptionsPressed = false
            }
        } else {
            optionsDisclosure.toggle()
            DispatchQueue.main.async {
                withAnimation(disclosureAnimation) {
                    isOptionsContentVisible = true
                }
                afterDisclosureAnimation {
                    isOptionsPressed = false
                }
            }
        }
    }

    private func toggleLanguageDisclosure() {
        guard !isLanguagePressed else { return }
        isLanguagePressed = true

        if reduceMotion {
            languageDisclosure.toggle()
            isLanguageContentVisible = languageDisclosure.isExpanded
            isLanguagePressed = false
        } else if languageDisclosure.isExpanded {
            withAnimation(disclosureAnimation) {
                isLanguageContentVisible = false
            }
            afterDisclosureAnimation {
                languageDisclosure.toggle()
                isLanguagePressed = false
            }
        } else {
            languageDisclosure.toggle()
            DispatchQueue.main.async {
                withAnimation(disclosureAnimation) {
                    isLanguageContentVisible = true
                }
                afterDisclosureAnimation {
                    isLanguagePressed = false
                }
            }
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(loc.t("popover_checking_license"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .frame(width: 320)
    }

    /// Detects whether the current Mac is a MacBook Air by checking the IOKit model identifier.
    private var isMacBookAir: Bool {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelString = String(cString: model)
        return modelString.lowercased().contains("macbookair")
    }

    private var noFanDetectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: isMacBookAir ? "laptopcomputer" : AirwaySymbol.fanSlash.resolved)
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(isMacBookAir ? loc.t("popover_no_fan_air") : loc.t("popover_no_fan"))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
    }

    private var maxRPM: Double {
        viewModel.fans.map(\.currentRPM).max() ?? 0
    }

    private var animationSpeed: Double {
        let rpm = maxRPM
        if rpm < 500 { return 0.2 }
        if rpm > 6000 { return 3.0 }
        return max(0.2, rpm / 2000.0)
    }

    private var header: some View {
        HStack {
            Image(systemName: AirwaySymbol.fan.resolved)
                .font(.title2)
                .modifier(ContinuousSpinModifier(rpm: maxRPM))
            VStack(alignment: .leading, spacing: 2) {
                Text("Airway")
                    .font(.headline)
                Text(modeDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            
            if viewModel.isApplyingChange {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var modeDescription: String {
        if let activePresetID = viewModel.presetStore.activePresetID,
           let preset = viewModel.presetStore.presets.first(where: { $0.id == activePresetID }) {
            return preset.name
        }
        switch viewModel.activeMode {
        case .system: return loc.t("popover_mode_system")
        case .manual: return loc.t("popover_mode_manual")
        case .max: return loc.t("popover_mode_max")
        }
    }

    private var connectingView: some View {
        VStack(spacing: 12) {
            ProgressView(loc.t("popover_connecting_helper"))

            Button(viewModel.isInstallingHelper ? loc.t("popover_repairing") : loc.t("popover_repair_helper")) {
                Task { await viewModel.installOrRepairHelper() }
            }
            .disabled(viewModel.isInstallingHelper)
        }
        .padding(.vertical, 24)
    }

    private var fanList: some View {
        VStack(spacing: 14) {
            ForEach(Array(viewModel.fans.enumerated()), id: \.offset) { index, fan in
                FanSliderRow(
                    title: loc.t("popover_fan_index", index + 1),
                    rpm: Int(fan.currentRPM),
                    percentage: Binding(
                        get: { viewModel.sliderPercentages.indices.contains(index) ? viewModel.sliderPercentages[index] : 0 },
                        set: { newValue in
                            Task { await viewModel.applyManualSpeed(fanIndex: index, percentage: newValue) }
                        }
                    ),
                    fineTune: viewModel.fineTuneManualOverride
                )
                .disabled(viewModel.activeMode != .manual || viewModel.presetStore.activePresetID != nil)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                Task { try? await viewModel.returnToSystemControl() }
            } label: {
                Group {
                    if showModeSymbols {
                        Label(loc.t("popover_auto"), systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Text(loc.t("popover_auto"))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(isActive: viewModel.activeMode == .system && viewModel.presetStore.activePresetID == nil))

            Button {
                Task { await viewModel.setManualMode() }
            } label: {
                Group {
                    if showModeSymbols {
                        Label(loc.t("popover_manual"), systemImage: "hand.tap")
                    } else {
                        Text(loc.t("popover_manual"))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(isActive: viewModel.activeMode == .manual && viewModel.presetStore.activePresetID == nil))

            Button {
                Task { try? await viewModel.setMaxSpeed() }
            } label: {
                Group {
                    if showModeSymbols {
                        Label(loc.t("popover_max"), systemImage: "wind")
                    } else {
                        Text(loc.t("popover_max"))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(isActive: viewModel.activeMode == .max && viewModel.presetStore.activePresetID == nil, tint: Color(red: 225/255, green: 44/255, blue: 18/255)))
        }
        .disabled(viewModel.isApplyingChange)
    }
    
    private var languageFooter: some View {
        VStack(spacing: 4) {
            ForEach(AppLanguage.allCases, id: \.self) { language in
                let isSelected = loc.language == language
                HStack {
                    Text(language == .system ? loc.t("language_system") : language.nativeName)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    loc.language = language
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private var settingsFooter: some View {
        VStack(spacing: 12) {
            // Menu bar display toggles
            HStack {
                Text(loc.t("popover_show_rpm"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.showRPMInMenuBar },
                    set: { viewModel.showRPMInMenuBar = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            
            HStack {
                Text(loc.t("popover_show_temp"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.showTempInMenuBar },
                    set: { viewModel.showTempInMenuBar = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }

            HStack {
                Text(loc.t("popover_show_icon"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.showIconInMenuBar },
                    set: { viewModel.showIconInMenuBar = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!viewModel.canHideMenuBarIcon)
            }
            
            HStack {
                Text(loc.t("popover_launch_at_login"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.launchAtLogin = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            
            HStack {
                Text(loc.t("popover_use_fahrenheit"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.useFahrenheit },
                    set: { viewModel.useFahrenheit = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            
            HStack {
                Text(loc.t("popover_fine_tune"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.fineTuneManualOverride },
                    set: { viewModel.fineTuneManualOverride = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            
            HStack {
                Text(loc.t("popover_show_mode_symbols"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("", isOn: $showModeSymbols)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }

            HStack {
                Text(loc.t("popover_disable_liquid_glass"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { disableLiquidGlass || !liquidGlassSupported },
                    set: { disableLiquidGlass = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!liquidGlassSupported)
            }

            VStack(spacing: 6) {
                HStack {
                    Text(loc.t("popover_appearance"))
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                AppearanceSegmentedControl(selection: Binding(
                    get: { AppearanceMode(storedValue: appearanceModeRaw) },
                    set: { mode in
                        appearanceModeRaw = mode.rawValue
                        mode.apply()
                    }
                ))
            }
        }
        .padding(.horizontal, 8)
        .disabled(viewModel.isApplyingChange)
    }

    private var needsApprovalView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.title)
                .foregroundColor(.secondary)
            Text("Approve Airway's helper in System Settings → General → Login Items, then come back here.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button(loc.t("popover_open_login_items")) {
                viewModel.openHelperApprovalSettings()
            }
        }
        .padding(.vertical, 24)
    }

    /// A compact, non-destructive message shown above the fan controls.
    ///
    /// Conditions that used to replace the whole fan UI with the "Enable the
    /// helper" screen live here instead when the helper is healthy and the
    /// hardware — not the connection — is what said no.
    private func inlineNotice(_ message: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundColor(tint)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: AirwaySymbol.disconnected.resolved)
                .font(.title)
                .foregroundColor(.secondary)
            Text(loc.t("popover_enable_helper_desc"))
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button(viewModel.isInstallingHelper ? loc.t("popover_enabling") : loc.t("popover_enable")) {
                    Task { await viewModel.installOrRepairHelper() }
                }
                .disabled(viewModel.isInstallingHelper)

            }
        }
        .padding(.vertical, 24)
    }
    
    @ViewBuilder
    private var presetSection: some View {
        if !viewModel.presetStore.presets.isEmpty {
            VStack(spacing: 4) {
                Divider()
                    .padding(.vertical, 8)
                
                HStack {
                    Text(loc.t("popover_preset"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.bottom, 2)
                
                VStack(spacing: 2) {
                    ForEach(viewModel.presetStore.presets) { preset in
                        PresetRowView(
                            preset: preset,
                            isSelected: viewModel.presetStore.activePresetID == preset.id,
                            action: { Task { try? await viewModel.applyPreset(preset) } }
                        )
                        .padding(.horizontal, -12)
                    }
                }
            }
            .disabled(viewModel.isApplyingChange)
            .padding(.top, -8)
            .padding(.bottom, -8)
        }
    }
}

private struct PlainTextHoverButton: View {
    let title: String
    var hoverColor: Color = .primary
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundColor(isHovered ? hoverColor : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isHovered ? hoverColor.opacity(0.1) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct FanSliderRow: View {
    let title: String
    let rpm: Int
    @Binding var percentage: Int
    let fineTune: Bool

    @State private var displayValue: Double
    @State private var isEditingSlider = false

    init(title: String, rpm: Int, percentage: Binding<Int>, fineTune: Bool) {
        self.title = title
        self.rpm = rpm
        self._percentage = percentage
        self.fineTune = fineTune
        self._displayValue = State(initialValue: Double(percentage.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(rpm) RPM")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(Int(displayValue))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            Slider(
                value: $displayValue,
                in: 25...100,
                step: fineTune ? 1 : 25,
                onEditingChanged: { editing in
                    isEditingSlider = editing
                    if !editing {
                        percentage = Int(displayValue)
                    }
                }
            )
            .tint(.accentColor)
        }
        .onChange(of: percentage) { newValue in
            displayValue = Double(newValue)
        }
        .onChange(of: displayValue) { _ in
            guard isEditingSlider else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment, performanceTime: .default
            )
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: displayValue)
    }
}

/// Light / System / Dark pill with a sliding accent thumb, mirroring
/// PresetModeSegmentedControl's look at the options-row scale.
private struct AppearanceSegmentedControl: View {
    @Binding var selection: AppearanceMode
    @ObservedObject private var loc = LocalizationManager.shared
    @Namespace private var thumbNamespace
    @AppStorage(disableLiquidGlassKey) private var disableLiquidGlass = false

    var body: some View {
        HStack(spacing: 4) {
            segment(loc.t("appearance_light"), mode: .light)
            segment(loc.t("appearance_system"), mode: .system)
            segment(loc.t("appearance_dark"), mode: .dark)
        }
        .padding(2)
        .frame(height: 28)
        .background(
            Group {
                if disableLiquidGlass || !liquidGlassSupported {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
        )
    }

    private func segment(_ title: String, mode: AppearanceMode) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                selection = mode
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(selection == mode ? .white : .primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .buttonStyle(.plain)
        .background(
            Group {
                if selection == mode {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "thumb", in: thumbNamespace)
                }
            }
        )
    }
}

private struct GlassButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var tint: Color = .accentColor
    @AppStorage(disableLiquidGlassKey) private var disableLiquidGlass = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 8)
            .background(buttonBackground)
            .foregroundColor(isActive ? .white : Color.primary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }

    @ViewBuilder
    private var buttonBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        if isActive {
            shape
                .fill(tint)
                .overlay(
                    shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
        } else if disableLiquidGlass || !liquidGlassSupported {
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape.strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                )
                .overlay(
                    shape.strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
                )
        }
    }
}

private struct HoverButton: View {
    let title: String
    let icon: String
    var hoverColor: Color = .primary
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundColor(isHovered ? hoverColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered ? hoverColor.opacity(0.1) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct ContinuousSpinModifier: ViewModifier {
    let rpm: Double
    @State private var angle: Double = 0
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onReceive(timer) { _ in
                if rpm > 100 {
                    // Let's map RPM to spin speed.
                    // Assuming max typical RPM is ~6000.
                    // 6000 RPM means it should spin fast visually, say 3 rotations per second.
                    // 3 rotations/sec = 1080 degrees/sec.
                    // per 1/60th sec frame = 18 degrees/frame.
                    // Formula: (rpm / 6000.0) * 18.0
                    let speed = (rpm / 6000.0) * 18.0
                    angle += speed
                    if angle >= 360 {
                        angle -= 360
                    }
                }
            }
    }
}

private struct PresetRowView: View {
    let preset: Preset
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @AppStorage(disableLiquidGlassKey) private var disableLiquidGlass = false

    private enum Metrics {
        static let rowHeight: CGFloat = 32
        static let iconSize: CGFloat = 26
        static let symbolSize: CGFloat = 13
        static let emojiSize: CGFloat = 12
        static let horizontalPadding: CGFloat = 12
        static let rowCornerRadius: CGFloat = 8
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                presetIcon
                
                Text(preset.name)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
            .padding(.horizontal, Metrics.horizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.09) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityValue(isSelected ? LocalizationManager.shared.t("popover_selected") : LocalizationManager.shared.t("popover_not_selected"))
    }

    private var presetIcon: some View {
        ZStack {
            iconBackground

            if let symbol = preset.symbol, !symbol.isEmpty {
                if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                    Image(systemName: symbol)
                        .font(.system(size: Metrics.symbolSize, weight: .medium))
                        .foregroundColor(isSelected ? .white : .primary.opacity(0.82))
                } else {
                    Text(symbol)
                        .font(.system(size: Metrics.emojiSize))
                        .foregroundColor(isSelected ? .white : .primary.opacity(0.82))
                }
            } else {
                Image(systemName: AirwaySymbol.fan.resolved)
                    .font(.system(size: Metrics.symbolSize, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary.opacity(0.82))
            }
        }
        .frame(width: Metrics.iconSize, height: Metrics.iconSize)
    }

    @ViewBuilder
    private var iconBackground: some View {
        if isSelected {
            Circle()
                .fill(Color.accentColor)
        } else if disableLiquidGlass || !liquidGlassSupported {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    Circle()
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Circle()
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
                )
        }
    }
}
