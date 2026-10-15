//
//  FanModeEntity.swift
//
//  The "mode" a Set Fan Mode intent can target: Auto, Max, or a user preset.
//  This is what lets Siri resolve "Airway on Max" / "Airway on Chill Mode".
//

import Foundation
import AppIntents

/// A selectable fan mode. `id` is `"system"` (Auto), `"max"`, or a preset's
/// UUID string; `name` is the spoken/displayed label.
struct FanModeEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Fan Mode"
    static var defaultQuery = FanModeEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    // MARK: Built-ins

    static let auto = FanModeEntity(id: "system", name: "Auto")
    static let max = FanModeEntity(id: "max", name: "Max")

    /// Extra words Siri / the LLM assistant can match against for the built-in
    /// modes, so "automatic" or "full blast" resolve without an exact label hit.
    static func synonyms(forID id: String) -> [String] {
        switch id {
        case "system": return ["auto", "automatic", "system", "default", "normal", "quiet"]
        case "max":    return ["max", "maximum", "full", "full blast", "full speed", "turbo", "boost", "high"]
        default:       return []
        }
    }

    /// Auto + Max + every saved preset, read straight from disk so it works even
    /// in a freshly launched process.
    static func all() -> [FanModeEntity] {
        var modes = [auto, max]
        modes.append(contentsOf: PresetStore.loadPresetsFromDisk().map {
            FanModeEntity(id: $0.id.uuidString, name: $0.name)
        })
        return modes
    }
}

/// Supplies the candidate modes to the Shortcuts editor and resolves the
/// spoken/typed string Siri captures (via `EntityStringQuery`).
struct FanModeEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [FanModeEntity] {
        FanModeEntity.all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [FanModeEntity] {
        FanModeEntity.all()
    }

    func entities(matching string: String) async throws -> [FanModeEntity] {
        let needle = string.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return FanModeEntity.all() }

        return FanModeEntity.all().filter { entity in
            let name = entity.name.lowercased()
            if name.contains(needle) || needle.contains(name) { return true }
            return FanModeEntity.synonyms(forID: entity.id).contains { syn in
                syn.contains(needle) || needle.contains(syn)
            }
        }
    }
}
