//
//  GetFanStatusIntent.swift
//
//  Reports current fan speed + temperature to Siri and, as extractable values,
//  to a Shortcut (e.g. an automation that branches on RPM or temperature).
//

import Foundation
import AppIntents

/// A snapshot of fan speed and temperature. Exposed as an `AppEntity` so a
/// Shortcut can pull the individual `rpm` / `temperature` numbers out of the
/// result rather than getting only spoken text.
struct FanStatusEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Fan Status"
    static var defaultQuery = FanStatusQuery()

    var id: String { "current" }

    @Property(title: "Fan Speed (RPM)")
    var rpm: Int

    @Property(title: "Temperature")
    var temperature: Double

    /// "C" or "F" — matches the user's Airway preference.
    var temperatureUnit: String

    init(rpm: Int, temperature: Double, temperatureUnit: String) {
        // Plain stored property must come first: the @Property-wrapped values
        // assign through setters on self, which requires self to be fully
        // initialized.
        self.temperatureUnit = temperatureUnit
        self.rpm = rpm
        self.temperature = temperature
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(rpm) RPM",
            subtitle: "\(Int(temperature.rounded()))°\(temperatureUnit)"
        )
    }
}

/// The result is built live inside the intent, so the query returns nothing —
/// it exists only to satisfy `AppEntity` conformance.
struct FanStatusQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FanStatusEntity] { [] }
    func suggestedEntities() async throws -> [FanStatusEntity] { [] }
}

struct GetFanStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Fan Status"
    static var description = IntentDescription(
        "Report Airway's current fan speed and system temperature.",
        categoryName: "Fan Control"
    )

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FanStatusEntity> & ProvidesDialog {
        let app = try await AirwayIntentSupport.readyApp()
        try AirwayIntentSupport.requireLicense(app)

        let fans: [FanInfoDTO]
        let tempC: Double
        do {
            async let fansTask = HelperClient.shared.fetchFanInfo()
            async let tempTask = HelperClient.shared.fetchSystemTemperature()
            fans = try await fansTask
            tempC = try await tempTask
        } catch {
            NSLog("[Airway] Get Fan Status failed: \(error.localizedDescription)")
            throw AirwayIntentError.helperUnreachable
        }

        let rpm = Int(fans.map(\.currentRPM).max() ?? 0)
        let useF = app.viewModel.useFahrenheit
        let temp = useF ? (tempC * 9.0 / 5.0 + 32.0) : tempC
        let unit = useF ? "F" : "C"

        let entity = FanStatusEntity(rpm: rpm, temperature: temp, temperatureUnit: unit)
        let tempStr = "\(Int(temp.rounded()))°\(unit)"
        return .result(
            value: entity,
            dialog: "\(LocalizationManager.shared.t("intent_dialog_status", rpm, tempStr))"
        )
    }
}
