//
//  AppearanceModeTests.swift
//
//  Covers the AppearanceMode enum backing the popover's Appearance control:
//  raw-value round-trips for the persisted string, fallback for unknown
//  stored values, and the NSAppearance each mode resolves to.
//

import XCTest
import AppKit
@testable import Airway

final class AppearanceModeTests: XCTestCase {

    func testRawValues_roundTrip() {
        for mode in AppearanceMode.allCases {
            XCTAssertEqual(AppearanceMode(rawValue: mode.rawValue), mode)
        }
        XCTAssertEqual(AppearanceMode(rawValue: "system"), .system)
        XCTAssertEqual(AppearanceMode(rawValue: "light"), .light)
        XCTAssertEqual(AppearanceMode(rawValue: "dark"), .dark)
    }

    func testStoredValueInit_fallsBackToSystem() {
        XCTAssertEqual(AppearanceMode(storedValue: "garbage"), .system)
        XCTAssertEqual(AppearanceMode(storedValue: ""), .system)
        XCTAssertEqual(AppearanceMode(storedValue: "dark"), .dark)
        XCTAssertEqual(AppearanceMode(storedValue: "light"), .light)
    }

    func testNSAppearanceMapping() {
        XCTAssertNil(AppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
    }

    func testSystemResolution_matchesExplicitLightAndDark() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertEqual(
            AppearanceMode.system.resolvedAppearance(from: light).name,
            AppearanceMode.light.resolvedAppearance(from: dark).name
        )
        XCTAssertEqual(
            AppearanceMode.system.resolvedAppearance(from: dark).name,
            AppearanceMode.dark.resolvedAppearance(from: light).name
        )
    }
}
