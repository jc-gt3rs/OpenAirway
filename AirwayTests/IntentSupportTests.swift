//
//  IntentSupportTests.swift
//
//  Unit tests for the pure logic backing the App Intents (Siri / Shortcuts):
//  nudge clamping and reading presets straight from disk.
//  Pure logic — no hardware, no network.
//

import XCTest
@testable import Airway

final class IntentSupportTests: XCTestCase {

    // MARK: - nudgedPercentage clamping

    func testNudge_withinRange_shiftsByDelta() {
        XCTAssertEqual(FanControlViewModel.nudgedPercentage(from: 50, by: 10), 60)
        XCTAssertEqual(FanControlViewModel.nudgedPercentage(from: 50, by: -10), 40)
    }

    func testNudge_clampsToUpperBound() {
        XCTAssertEqual(FanControlViewModel.nudgedPercentage(from: 95, by: 10), 100)
        XCTAssertEqual(FanControlViewModel.nudgedPercentage(from: 100, by: 75), 100)
    }

    func testNudge_clampsToLowerBound() {
        XCTAssertEqual(FanControlViewModel.nudgedPercentage(from: 30, by: -10), 25)
        XCTAssertEqual(FanControlViewModel.nudgedPercentage(from: 25, by: -75), 25)
    }

    func testNudge_atExactBounds_staysPut() {
        XCTAssertEqual(FanControlViewModel.nudgedPercentage(from: 25, by: 0), 25)
        XCTAssertEqual(FanControlViewModel.nudgedPercentage(from: 100, by: 0), 100)
    }

    // MARK: - loadPresetsFromDisk

    private let presetsKey = "fanPresets"
    private var savedPresetsData: Data?

    override func setUp() {
        super.setUp()
        // Preserve whatever real presets are in UserDefaults so tests don't
        // clobber the developer's own data.
        savedPresetsData = UserDefaults.standard.data(forKey: presetsKey)
    }

    override func tearDown() {
        if let savedPresetsData {
            UserDefaults.standard.set(savedPresetsData, forKey: presetsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: presetsKey)
        }
        super.tearDown()
    }

    func testLoadPresetsFromDisk_noData_returnsEmpty() {
        UserDefaults.standard.removeObject(forKey: presetsKey)
        XCTAssertEqual(PresetStore.loadPresetsFromDisk(), [])
    }

    func testLoadPresetsFromDisk_corruptData_returnsEmpty() {
        UserDefaults.standard.set(Data("not json".utf8), forKey: presetsKey)
        XCTAssertEqual(PresetStore.loadPresetsFromDisk(), [])
    }

    func testLoadPresetsFromDisk_roundTripsSavedPresets() throws {
        let presets = [
            Preset(name: "Chill Mode", mode: .percentage, value: 40, symbol: "snowflake"),
            Preset(name: "Charging", mode: .rpm, value: 3200)
        ]
        UserDefaults.standard.set(try JSONEncoder().encode(presets), forKey: presetsKey)

        let loaded = PresetStore.loadPresetsFromDisk()
        XCTAssertEqual(loaded, presets)
    }
}
