//
//  LocalizationManager.swift
//
//  Resolves and caches a Bundle for the active AppLanguage, and exposes a
//  keyed string lookup (`t`). Because `language` is @Published, changing it
//  re-renders every view that calls `t(_:)` immediately — no relaunch needed.
//

import Foundation
import Combine

final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    private static let storageKey = "appLanguage"

    private let defaults: UserDefaults
    private var bundle: Bundle = .main

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.storageKey)
            reloadBundle()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.storageKey)
        self.language = saved.flatMap(AppLanguage.init(rawValue:)) ?? .system
        reloadBundle()
    }

    private func reloadBundle() {
        let code = Self.resolvedCode(for: language)
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            bundle = langBundle
        } else {
            bundle = .main
        }
    }

    static func resolvedCode(for language: AppLanguage) -> String {
        language == .system ? systemResolvedCode(preferredLanguages: Locale.preferredLanguages) : language.rawValue
    }

    /// Intersects the user's ordered system-language preferences with our
    /// supported codes; first match wins. Falls back to English.
    static func systemResolvedCode(preferredLanguages: [String]) -> String {
        let supported = AppLanguage.allCases.filter { $0 != .system }.map(\.rawValue)
        for preference in preferredLanguages {
            if let match = supported.first(where: { preference == $0 || preference.hasPrefix($0 + "-") }) {
                return match
            }
        }
        return "en"
    }

    /// Looks up `key` in the active language bundle, falling back to the raw
    /// key (never blank) if the bundle or key is missing.
    func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Formatted variant for strings containing `%@`/`%d` placeholders.
    func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }
}
