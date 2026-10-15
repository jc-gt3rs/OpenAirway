//
//  AppLanguage.swift
//
//  The set of languages Airway can display in, independent of macOS's own
//  system language. `system` means "follow the OS", resolved at lookup time
//  by LocalizationManager rather than stored as a fixed code.
//

import Foundation

enum AppLanguage: String, CaseIterable, Codable {
    case system
    case english = "en"
    case filipino = "fil"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case japanese = "ja"
    case chineseSimplified = "zh-Hans"
    case korean = "ko"

    /// Each language's own name for itself, shown in the picker regardless of
    /// the app's current display language (so a Japanese speaker can always
    /// find "日本語" even while the app is showing German).
    var nativeName: String {
        switch self {
        case .system: return ""  // UI uses LocalizationManager.t("language_system") instead
        case .english: return "English"
        case .filipino: return "Filipino"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .japanese: return "日本語"
        case .chineseSimplified: return "简体中文"
        case .korean: return "한국어"
        }
    }
}
