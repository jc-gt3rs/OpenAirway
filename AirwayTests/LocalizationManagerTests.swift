//
//  LocalizationManagerTests.swift
//
//  Unit tests for AppLanguage and LocalizationManager.
//

import XCTest
@testable import Airway

final class LocalizationManagerTests: XCTestCase {

    // MARK: - AppLanguage

    func testAllCases_containsExpectedLanguages() {
        let codes = AppLanguage.allCases.map(\.rawValue)
        XCTAssertEqual(codes, [
            "system", "en", "fil", "es", "fr", "de", "ja", "zh-Hans", "ko"
        ])
    }

    func testNativeNames_areNeverEmpty_exceptSystem() {
        for lang in AppLanguage.allCases where lang != .system {
            XCTAssertFalse(lang.nativeName.isEmpty, "\(lang) should have a non-empty nativeName")
        }
        XCTAssertTrue(AppLanguage.system.nativeName.isEmpty)
    }

    // MARK: - System resolution

    func testSystemResolvedCode_picksFirstSupported() {
        XCTAssertEqual(LocalizationManager.systemResolvedCode(preferredLanguages: ["ja", "en"]), "ja")
        XCTAssertEqual(LocalizationManager.systemResolvedCode(preferredLanguages: ["fil", "en"]), "fil")
    }

    func testSystemResolvedCode_fallsBackToEnglish() {
        XCTAssertEqual(LocalizationManager.systemResolvedCode(preferredLanguages: ["pt-BR", "it"]), "en")
        XCTAssertEqual(LocalizationManager.systemResolvedCode(preferredLanguages: []), "en")
    }

    func testSystemResolvedCode_handlesRegionalVariants() {
        // "es-MX" should match "es"
        XCTAssertEqual(LocalizationManager.systemResolvedCode(preferredLanguages: ["es-MX"]), "es")
        // "zh-Hans-CN" should match "zh-Hans"
        XCTAssertEqual(LocalizationManager.systemResolvedCode(preferredLanguages: ["zh-Hans-CN"]), "zh-Hans")
    }

    // MARK: - Round-trip persistence

    func testLanguage_roundTrips_throughUserDefaults() {
        let defaults = UserDefaults(suiteName: "LocalizationManagerTests")!
        defaults.removePersistentDomain(forName: "LocalizationManagerTests")

        let manager = LocalizationManager(defaults: defaults)
        XCTAssertEqual(manager.language, .system)

        manager.language = .korean
        let manager2 = LocalizationManager(defaults: defaults)
        XCTAssertEqual(manager2.language, .korean)

        defaults.removePersistentDomain(forName: "LocalizationManagerTests")
    }
}
