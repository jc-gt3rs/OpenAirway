//
//  Preset.swift
//  
//
//  Created by John Cris Antor on 6/21/2026.
//

import Foundation
import AppIntents

// MARK: - Data Model

enum PresetMode: String, Codable, CaseIterable {
    case rpm
    case percentage
}

struct Preset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var mode: PresetMode
    var value: Int
    var symbol: String?
    
    init(id: UUID = UUID(), name: String, mode: PresetMode, value: Int, symbol: String? = nil) {
        self.id = id
        self.name = name
        self.mode = mode
        self.value = value
        self.symbol = symbol
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, mode, value, symbol
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.mode = try container.decode(PresetMode.self, forKey: .mode)
        self.value = try container.decode(Int.self, forKey: .value)
        self.symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mode, forKey: .mode)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(symbol, forKey: .symbol)
    }
}

// MARK: - Preset Store

final class PresetStore: ObservableObject {
    
    static let maxNameLength = 30

    private static let presetsKey = "fanPresets"
    private static let activePresetIDKey = "activePresetID"

    @Published var presets: [Preset] = [] {
        didSet { save() }
    }

    /// Which preset is currently applied. This is SESSION-ONLY and deliberately
    /// NOT persisted across launches: on quit the app hands fan control back to
    /// the system, so a "previously active" preset is no longer running.
    /// Restoring it would wrongly keep that preset lit (and hide the Auto button)
    /// after relaunch even though the system holds control.
    @Published var activePresetID: UUID?

    init() {
        // Clear any value persisted by older builds that saved activePresetID,
        // so it can't be resurrected as a stale "active" preset on launch.
        UserDefaults.standard.removeObject(forKey: Self.activePresetIDKey)
        load()
    }
    
    // MARK: - CRUD
    
    func addPreset(_ preset: Preset) {
        presets.append(preset)
    }
    
    func updatePreset(_ preset: Preset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
    }
    
    func deletePreset(_ preset: Preset) {
        // If the active preset is being deleted, clear the selection
        if activePresetID == preset.id {
            activePresetID = nil
        }
        presets.removeAll { $0.id == preset.id }
    }
    
    func deletePresets(at offsets: IndexSet) {
        for index in offsets {
            if presets.indices.contains(index) && activePresetID == presets[index].id {
                activePresetID = nil
            }
        }
        presets.remove(atOffsets: offsets)
    }
    
    // MARK: - Validation
    
    /// Validates the preset name. Returns an error message or nil if valid.
    static func validateName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Name cannot be empty."
        }
        if trimmed.count > maxNameLength {
            return "Name must be \(maxNameLength) characters or fewer."
        }
        return nil
    }
    
    /// Validates the preset value against fan hardware bounds.
    /// - Parameters:
    ///   - value: The numeric value to validate
    ///   - mode: Whether this is an RPM or percentage value
    ///   - minRPM: The fan's minimum RPM (from FanInfoDTO)
    ///   - maxRPM: The fan's maximum RPM (from FanInfoDTO)
    /// - Returns: An error message, or nil if valid.
    static func validateValue(_ value: Int, mode: PresetMode, minRPM: Double, maxRPM: Double) -> String? {
        switch mode {
        case .rpm:
            let min = Int(minRPM)
            let max = Int(maxRPM)
            if value < min || value > max {
                return "RPM must be between \(min) and \(max)."
            }
        case .percentage:
            if value < 25 || value > 100 {
                return "Percentage must be between 25% and 100%."
            }
        }
        return nil
    }
    
    // MARK: - Persistence
    
    private func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: Self.presetsKey)
        // Re-teach Siri the current preset names so "Hey Siri, Airway on
        // <new preset>" works immediately — App Shortcut phrases embedding an
        // AppEntity parameter only refresh their vocabulary when told to.
        AirwayShortcuts.updateAppShortcutParameters()
    }
    
    private func load() {
        presets = Self.loadPresetsFromDisk()
    }

    /// Reads the saved presets straight from `UserDefaults` without constructing
    /// a full `PresetStore` (which clears legacy keys and would be wasteful to
    /// spin up just to enumerate names). Used by the App Intents entity query,
    /// which may run in a fresh process before the app's own store exists.
    static func loadPresetsFromDisk() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let decoded = try? JSONDecoder().decode([Preset].self, from: data) else { return [] }
        return decoded
    }
}
