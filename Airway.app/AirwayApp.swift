//
//  AirwayApp.swift
//  
//
//  Created by John Cris Antor on 6/11/2026.
//

import SwiftUI

extension NSWindow {
    func keepVisibleAcrossAppsAndSpaces() {
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// The live app delegate, exposed so App Intents (Siri / Shortcuts) can act
    /// on the same `viewModel`/`licenseManager` the popover UI uses — a change
    /// made via Siri then shows up in the popover exactly like a button click.
    /// Set at the END of `applicationDidFinishLaunching`, so a non-nil value
    /// guarantees the license state has been evaluated and the app is ready.
    static private(set) var shared: AppDelegate?

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var viewModel = FanControlViewModel()
    var licenseManager = LicenseManager()
    lazy var updateManager = AppUpdateManager()
    private var effectiveAppearanceObservation: NSKeyValueObservation?

    /// Set only on macOS 13, where the popover's size has to be driven by hand.
    /// The popover owns the controller, so this is weak.
    private weak var popoverSizing: (any PopoverContentSizing)?
    
    /// Tracks when the popover last closed so we can debounce re-opens
    /// caused by the transient behavior dismissing the popover before
    /// the status bar button action fires.
    private var lastCloseTime: Date = .distantPast
    
    // Timer to update menu bar text
    private var updateTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture uncaught exceptions and upload any crash from the previous run.
        // The open edition never talks to the Airway server, so it skips both.
        if AirwayEdition.isLicensed {
            CrashCatcher.install()
            TelemetryReporter.flushPendingCrashReport()
        }

        // Apply the saved appearance override before any windows appear.
        AppearanceMode(storedValue: UserDefaults.standard.string(forKey: AppearanceMode.defaultsKey) ?? "").apply()

        // Check license state before anything else.
        licenseManager.checkLicenseOnLaunch()

        // `--show-onboarding` forces it regardless of license state for
        // previewing/iterating on the design without resetting the license.
        let forceOnboarding = ProcessInfo.processInfo.arguments.contains("--show-onboarding")
        if forceOnboarding {
            OnboardingWindowController.shared.show(licenseManager: licenseManager)
        } else if case .noToken = licenseManager.state,
                  !UserDefaults.standard.bool(forKey: OnboardingWindowController.hasSeenOnboardingKey) {
            OnboardingWindowController.shared.show(licenseManager: licenseManager)
        }
        
        // Health-check the privileged helper off the main thread. A reachable,
        // up-to-date helper is left completely untouched — no re-registration,
        // no daemon restart, no prompts, and the popover goes straight to the
        // fan UI. Repair only happens when the helper is unreachable or stale.
        Task.detached { [viewModel] in
            do {
                try await HelperClient.shared.ensureHelperReadyAtLaunch()
            } catch HelperClient.HelperInstallError.requiresApproval {
                await MainActor.run { viewModel.connectionState = .needsApproval }
            } catch {
                NSLog("[Airway] WARNING: Helper launch check failed: \(error.localizedDescription)")
            }
        }
        
        setupPopover()
        setupStatusItem()
        viewModel.startMonitoring()
        
        // Timer to refresh status item
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusBar()
            }
        }

        // Publish the ready delegate LAST so App Intents only ever see a fully
        // initialized app (license evaluated, view model live).
        AppDelegate.shared = self
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            do {
                try await HelperClient.shared.setMode(.system, percentages: [])
                NSLog("[Airway] Successfully set mode to system on termination.")
            } catch {
                NSLog("[Airway] Failed to set mode to system on termination: \(error)")
            }
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    
    /// The user's saved appearance override, re-read from defaults on demand.
    private var storedAppearanceMode: AppearanceMode {
        AppearanceMode(storedValue: UserDefaults.standard.string(forKey: AppearanceMode.defaultsKey) ?? "")
    }

    private func updatePopoverAppearance() {
        popover?.appearance = storedAppearanceMode.resolvedAppearance(from: NSApp.effectiveAppearance)
    }

    // Reapply the appearance override to the popover whenever the Options pill
    // writes the defaults key. The popover needs its own `appearance` because
    // it inherits the status-bar window's (menu bar) appearance, not
    // `NSApp.appearance` — see AppearanceMode.apply().
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == AppearanceMode.defaultsKey else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        updatePopoverAppearance()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        updatePopoverAppearance()
        UserDefaults.standard.addObserver(self, forKeyPath: AppearanceMode.defaultsKey, options: [], context: nil)
        effectiveAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updatePopoverAppearance()
            }
        }
        
        let rootView = FanControlPopoverView(
            viewModel: viewModel,
            licenseManager: licenseManager,
            updateManager: updateManager
        )
            .frame(width: 320)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear {
                Task { @MainActor in
                    self.viewModel.startMonitoring()
                    self.licenseManager.refreshTrialStatusFromServer()
                }
            }
            .onDisappear {
                Task { @MainActor in
                    self.viewModel.stopMonitoring()
                }
            }
            
        let hostingController = PopoverContentHostingController(rootView: rootView)
        if #available(macOS 14.0, *) {
            // Sonoma and later keep the popover in step with the content on
            // their own.
            hostingController.sizingOptions = .intrinsicContentSize
        } else {
            // Ventura's NSPopover ignores `.intrinsicContentSize` and keeps a
            // content size smaller than the view, which centres and clips the
            // UI on all four sides. Attaching the popover makes the controller
            // size it by hand instead.
            hostingController.popover = popover
            popoverSizing = hostingController
        }
        popover.contentViewController = hostingController
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
       
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: AirwaySymbol.fan.resolved, accessibilityDescription: "Airway")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        // Until onboarding is done (i.e. a license exists), the menu is
        // off-limits: clicking the status item (re)opens the onboarding
        // window instead — even if the user dismissed it earlier. Trial
        // entry lives in onboarding, not the popover.
        if case .noToken = licenseManager.state {
            if let onboardingWindow = OnboardingWindowController.shared.window,
               onboardingWindow.isVisible {
                onboardingWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                OnboardingWindowController.shared.show(licenseManager: licenseManager)
            }
            return
        }
        // Trial expired or paid license locked — send the user to the License
        // window (activation / paywall) instead of the fan-control popover.
        if case .trialExpired = licenseManager.state {
            LicenseWindowController.shared.show(licenseManager: licenseManager)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if case .paidLocked = licenseManager.state {
            LicenseWindowController.shared.show(licenseManager: licenseManager)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // If onboarding is on screen for any other reason (e.g. forced for
        // testing), just re-focus it rather than fighting it for key status.
        if let onboardingWindow = OnboardingWindowController.shared.window,
           onboardingWindow.isVisible {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // If the popover was *just* closed by transient behavior (e.g. the
            // user clicked the status-bar button to dismiss), the close happens
            // before our action fires, so isShown is already false.  Debounce
            // re-opens within 250 ms of a close.
            guard Date().timeIntervalSince(lastCloseTime) > 0.25 else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Force the window to be key so SwiftUI controls render as "active" (not grayed out)
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    // MARK: - NSPopoverDelegate
    
    func popoverDidClose(_ notification: Notification) {
        lastCloseTime = Date()
    }

    /// Size the popover before it is drawn, so macOS 13 opens at the right size
    /// rather than opening clipped and correcting itself a frame later. No-op
    /// on macOS 14+, where `popoverSizing` is nil.
    func popoverWillShow(_ notification: Notification) {
        popoverSizing?.synchronizePopoverContentSize()
    }
    
    private func updateStatusBar() {
        guard let button = statusItem.button else { return }
        let showRPM = viewModel.showRPMInMenuBar
        let showTemp = viewModel.showTempInMenuBar
        let showIcon = viewModel.showIconInMenuBar
        let useF = viewModel.useFahrenheit
        
        let rpm = Int(viewModel.fans.map(\.currentRPM).max() ?? 0)
        let tempC = viewModel.systemTemperature
        let tempVal = useF ? Int(round(tempC * 9.0/5.0 + 32.0)) : Int(round(tempC))
        let tempStr = "\(tempVal)°\(useF ? "F" : "C")"
        
        // Never force-unwrap a system symbol: it resolves to nil on any macOS
        // that predates the glyph, and this runs on a repeating timer, so a nil
        // here takes the whole app down a couple of seconds after launch.
        let fanImage = NSImage(systemSymbolName: AirwaySymbol.fan.resolved, accessibilityDescription: "Airway")
        fanImage?.isTemplate = true
        let drawIcon = showIcon && fanImage != nil
        
        if showRPM || showTemp {
            let text: String
            let textWidth: CGFloat
            let fontSize: CGFloat
            
            if showRPM && showTemp {
                text = "\(tempStr)\n\(rpm) RPM"
                textWidth = 54 // fixed width for stacked
                fontSize = 9.5
            } else if showRPM {
                text = "\(rpm) RPM"
                textWidth = 60
                fontSize = 11.0
            } else {
                text = tempStr
                textWidth = 36
                fontSize = 11.0
            }
            
            let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .left
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: NSColor.headerTextColor
            ]
            
            let attrString = NSAttributedString(string: text, attributes: attributes)
            let textSize = attrString.size()
            
            let iconWidth = drawIcon ? (fanImage?.size.width ?? 0) + 4 : 0
            let totalWidth = iconWidth + textWidth
            let imageSize = NSSize(width: totalWidth, height: 22)
            
            let combinedImage = NSImage(size: imageSize)
            combinedImage.lockFocus()
            
            let contentWidth = iconWidth + ceil(textSize.width)
            let startX = max(0, (totalWidth - contentWidth) / 2.0)
            
            if drawIcon, let fanImage {
                fanImage.draw(at: NSPoint(x: startX, y: (22 - fanImage.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            
            let textRect = NSRect(x: startX + iconWidth, y: (22 - textSize.height) / 2, width: ceil(textSize.width), height: textSize.height)
            attrString.draw(in: textRect)
            
            combinedImage.unlockFocus()
            combinedImage.isTemplate = true
            button.image = combinedImage
            button.title = ""
        } else {
            button.image = fanImage
            button.title = fanImage == nil ? "Airway" : ""
        }
    }
}

@main
struct AirwayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()
    
    private convenience init() {
        // Traffic light controls but close is active, minimize and max disabled.
        // We use a custom window style.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
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
        window.center()
        
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .menu
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        
        let hostingView = NSHostingView(rootView: AboutView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        
        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
        ])
        
        window.contentView = visualEffect
        
        self.init(window: window)
    }
}

class PresetWindowController: NSWindowController {
    static let shared = PresetWindowController()
    
    private var isContentViewSet = false
    
    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.keepVisibleAcrossAppsAndSpaces()
        window.title = "Airway"
        window.minSize = NSSize(width: 640, height: 430)
        window.center()
        self.init(window: window)
    }
    
    func showWindow(viewModel: FanControlViewModel) {
        if !isContentViewSet {
            let rootView = PresetManagerView(viewModel: viewModel)
            window?.contentView = NSHostingView(rootView: rootView)
            isContentViewSet = true
        }
        showWindow(nil)
    }
}

struct AboutView: View {
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 8) {
            Image("AboutIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .padding(.bottom, 8)

            // Brand name is not translated, matching standard product-name convention.
            Text("Airway")
                .font(.system(size: 24, weight: .bold))

            Text(loc.t("about_version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"))
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(loc.t("about_copyright"))
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.top, 4)

            Text(loc.t("about_author"))
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 300, height: 300)
    }
}
