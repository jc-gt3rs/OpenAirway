//
//  PresetTests.swift
//
//  Unit tests for Preset validation and PresetStore encoding.
//  Pure logic — no hardware, no network.
//

import XCTest
@testable import Airway

final class PresetTests: XCTestCase {

    // MARK: - validateName

    func testValidateName_empty_returnsError() {
        XCTAssertNotNil(PresetStore.validateName(""))
        XCTAssertNotNil(PresetStore.validateName("   "))
        XCTAssertNotNil(PresetStore.validateName("\n\t"))
    }

    func testValidateName_valid_returnsNil() {
        XCTAssertNil(PresetStore.validateName("Quiet"))
        XCTAssertNil(PresetStore.validateName("  Turbo  ")) // trimmed, still valid
    }

    func testValidateName_atMaxLength_isValid() {
        let name = String(repeating: "x", count: PresetStore.maxNameLength)
        XCTAssertNil(PresetStore.validateName(name))
    }

    func testValidateName_overMaxLength_returnsError() {
        let name = String(repeating: "x", count: PresetStore.maxNameLength + 1)
        XCTAssertNotNil(PresetStore.validateName(name))
    }

    // MARK: - validateValue (RPM)

    func testValidateValue_rpm_inRange_isValid() {
        XCTAssertNil(PresetStore.validateValue(2000, mode: .rpm, minRPM: 1200, maxRPM: 5000))
        XCTAssertNil(PresetStore.validateValue(1200, mode: .rpm, minRPM: 1200, maxRPM: 5000)) // lower bound
        XCTAssertNil(PresetStore.validateValue(5000, mode: .rpm, minRPM: 1200, maxRPM: 5000)) // upper bound
    }

    func testValidateValue_rpm_belowMin_returnsError() {
        XCTAssertNotNil(PresetStore.validateValue(1000, mode: .rpm, minRPM: 1200, maxRPM: 5000))
    }

    func testValidateValue_rpm_aboveMax_returnsError() {
        XCTAssertNotNil(PresetStore.validateValue(6000, mode: .rpm, minRPM: 1200, maxRPM: 5000))
    }

    // MARK: - validateValue (percentage)

    func testValidateValue_percentage_inRange_isValid() {
        XCTAssertNil(PresetStore.validateValue(25, mode: .percentage, minRPM: 0, maxRPM: 0))  // safety floor
        XCTAssertNil(PresetStore.validateValue(60, mode: .percentage, minRPM: 0, maxRPM: 0))
        XCTAssertNil(PresetStore.validateValue(100, mode: .percentage, minRPM: 0, maxRPM: 0)) // ceiling
    }

    func testValidateValue_percentage_belowSafetyFloor_returnsError() {
        // The 25% hardware-safety floor must be enforced.
        XCTAssertNotNil(PresetStore.validateValue(24, mode: .percentage, minRPM: 0, maxRPM: 0))
        XCTAssertNotNil(PresetStore.validateValue(0, mode: .percentage, minRPM: 0, maxRPM: 0))
    }

    func testValidateValue_percentage_aboveCeiling_returnsError() {
        XCTAssertNotNil(PresetStore.validateValue(101, mode: .percentage, minRPM: 0, maxRPM: 0))
    }

    // MARK: - Codable round-trip

    func testPreset_codableRoundTrip_preservesAllFields() throws {
        let preset = Preset(name: "Turbo", mode: .rpm, value: 4200, symbol: "flame")
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        XCTAssertEqual(decoded, preset)
        XCTAssertEqual(decoded.symbol, "flame")
    }

    func testPreset_decodesWithoutSymbol() throws {
        // symbol is optional and must decode from JSON that omits it.
        let json = #"{"id":"\#(UUID().uuidString)","name":"Quiet","mode":"percentage","value":30}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        XCTAssertNil(decoded.symbol)
        XCTAssertEqual(decoded.mode, .percentage)
        XCTAssertEqual(decoded.value, 30)
    }
}
