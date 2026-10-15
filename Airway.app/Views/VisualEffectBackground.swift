//
//  VisualEffectBackground.swift
//  
//
//  Created by John Cris Antor on 6/11/2026.
//

import SwiftUI
import AppKit

/// Whether the running OS renders Airway's translucent "liquid glass" material
/// styling well enough to offer it as a user choice. Below this, the option is
/// forced off and its toggle is locked.
var liquidGlassSupported: Bool {
    if #available(macOS 14, *) { return true }
    return false
}

/// User-selected appearance override persisted under the "appearanceMode"
/// defaults key. `system` follows macOS (`NSApp.appearance = nil`).
enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    static let defaultsKey = "appearanceMode"

    /// Tolerant init for values read back from UserDefaults.
    init(storedValue: String) {
        self = AppearanceMode(rawValue: storedValue) ?? .system
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Resolves Automatic to the same concrete appearance used by the matching
    /// explicit mode. This prevents the status-item popover from inheriting the
    /// menu bar's wallpaper-derived appearance instead of the macOS app theme.
    func resolvedAppearance(from systemAppearance: NSAppearance) -> NSAppearance {
        let name: NSAppearance.Name
        switch self {
        case .system:
            name = systemAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        case .light:
            name = .aqua
        case .dark:
            name = .darkAqua
        }
        return NSAppearance(named: name) ?? systemAppearance
    }

    /// Applies the override to regular windows. The status-item popover does
    /// NOT follow `NSApp.appearance` — it inherits the status-bar window's
    /// appearance — so `AppDelegate` applies a resolved concrete appearance to
    /// the popover and refreshes it when the system appearance changes.
    func apply() {
        NSApp.appearance = nsAppearance
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
