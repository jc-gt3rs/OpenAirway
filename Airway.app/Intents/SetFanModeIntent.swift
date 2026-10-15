//
//  SetFanModeIntent.swift
//
//  The flagship intent: "Hey Siri, Airway on Max", "Airway on Chill Mode",
//  and the Shortcuts action a charging automation calls to switch presets.
//

import Foundation
import AppIntents

struct SetFanModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Fan Mode"
    static var description = IntentDescription(
        "Switch Airway to Auto, Max, or one of your saved fan presets.",
        categoryName: "Fan Control"
    )

    // Menu-bar app: run in-process without pulling a window forward.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Mode")
    var mode: FanModeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Set Airway to \(\.$mode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try await AirwayIntentSupport.readyApp()
        try AirwayIntentSupport.requireLicense(app)
        let viewModel = app.viewModel

        switch mode.id {
        case "system":
            try await AirwayIntentSupport.runFanAction { try await viewModel.returnToSystemControl() }
        case "max":
            try await AirwayIntentSupport.runFanAction { try await viewModel.setMaxSpeed() }
        default:
            guard let uuid = UUID(uuidString: mode.id),
                  let preset = viewModel.presetStore.presets.first(where: { $0.id == uuid }) else {
                throw AirwayIntentError.presetNotFound(mode.name)
            }
            try await AirwayIntentSupport.runFanAction { try await viewModel.applyPreset(preset) }
        }

        return .result(dialog: "\(LocalizationManager.shared.t("intent_dialog_set_mode", mode.name))")
    }
}
