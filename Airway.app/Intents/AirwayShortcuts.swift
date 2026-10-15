//
//  AirwayShortcuts.swift
//
//  Registers Airway's App Shortcuts — this is what makes the intents appear in
//  the Shortcuts app automatically and gives Siri the launch phrases
//  ("Hey Siri, Airway on Max" / "…on Chill Mode"). The newer LLM-based Siri
//  also grounds on these phrases plus the entity names/synonyms, so richer
//  phrasing resolves without exact matches.
//

import Foundation
import AppIntents

struct AirwayShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .teal

    // `systemImageName` must be a compile-time literal — App Intents extracts
    // this metadata at build time — so these cannot go through
    // `AirwaySymbol`'s runtime chains. They name glyphs that already exist on
    // the macOS 13 deployment target instead.

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetFanModeIntent(),
            phrases: [
                "\(.applicationName) on \(\.$mode)",
                "Set \(.applicationName) to \(\.$mode)",
                "Turn on \(\.$mode) in \(.applicationName)",
                "Switch \(.applicationName) to \(\.$mode)"
            ],
            shortTitle: "Set Fan Mode",
            systemImageName: "fanblades.fill"
        )
        AppShortcut(
            intent: GetFanStatusIntent(),
            phrases: [
                "\(.applicationName) status",
                "Get fan status from \(.applicationName)",
                "How fast are my fans in \(.applicationName)"
            ],
            shortTitle: "Fan Status",
            systemImageName: "gauge"
        )
        AppShortcut(
            intent: IncreaseFanSpeedIntent(),
            phrases: [
                "Increase fan speed in \(.applicationName)",
                "Turn up the fans in \(.applicationName)",
                "\(.applicationName) faster"
            ],
            shortTitle: "Increase Speed",
            systemImageName: "arrow.up.circle"
        )
        AppShortcut(
            intent: DecreaseFanSpeedIntent(),
            phrases: [
                "Decrease fan speed in \(.applicationName)",
                "Turn down the fans in \(.applicationName)",
                "\(.applicationName) slower"
            ],
            shortTitle: "Decrease Speed",
            systemImageName: "arrow.down.circle"
        )
    }
}
