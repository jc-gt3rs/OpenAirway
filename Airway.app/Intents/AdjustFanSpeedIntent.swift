//
//  AdjustFanSpeedIntent.swift
//
//  Relative nudges: "increase fan speed", "turn the fans down a bit" —
//  switches to manual mode offset from the fans' current actual speeds.
//

import Foundation
import AppIntents

struct IncreaseFanSpeedIntent: AppIntent {
    static var title: LocalizedStringResource = "Increase Fan Speed"
    static var description = IntentDescription(
        "Speed the fans up by a number of percentage points (default 10).",
        categoryName: "Fan Control"
    )

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Amount (%)", default: 10, inclusiveRange: (1, 75))
    var amount: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Increase fan speed by \(\.$amount)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try await AirwayIntentSupport.readyApp()
        try AirwayIntentSupport.requireLicense(app)
        try await AirwayIntentSupport.runFanAction {
            try await app.viewModel.adjustFanSpeed(byPercentagePoints: amount)
        }
        return .result(dialog: "\(LocalizationManager.shared.t("intent_dialog_increase", amount))")
    }
}

struct DecreaseFanSpeedIntent: AppIntent {
    static var title: LocalizedStringResource = "Decrease Fan Speed"
    static var description = IntentDescription(
        "Slow the fans down by a number of percentage points (default 10).",
        categoryName: "Fan Control"
    )

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Amount (%)", default: 10, inclusiveRange: (1, 75))
    var amount: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Decrease fan speed by \(\.$amount)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try await AirwayIntentSupport.readyApp()
        try AirwayIntentSupport.requireLicense(app)
        try await AirwayIntentSupport.runFanAction {
            try await app.viewModel.adjustFanSpeed(byPercentagePoints: -amount)
        }
        return .result(dialog: "\(LocalizationManager.shared.t("intent_dialog_decrease", amount))")
    }
}
