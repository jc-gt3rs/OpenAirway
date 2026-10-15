//
//  LocalizationCoverageTests.swift
//
//  Guards against a translated .strings file drifting out of sync with the
//  English source: every key present in English must exist in every other
//  language, and vice versa (no orphaned keys).
//

import XCTest
@testable import Airway

final class LocalizationCoverageTests: XCTestCase {

    private static let languageCodes = ["en", "fil", "es", "fr", "de", "ja", "zh-Hans", "ko"]

    private func keys(forLanguageCode code: String) throws -> Set<String> {
        guard let path = Bundle(for: LocalizationCoverageTests.self)
            .path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: code)
            ?? Bundle.main.path(forResource: code, ofType: "lproj").map { "\($0)/Localizable.strings" },
            let dict = NSDictionary(contentsOfFile: path) as? [String: String]
        else {
            XCTFail("Could not load Localizable.strings for '\(code)'")
            return []
        }
        return Set(dict.keys)
    }

    func testAllLanguages_haveIdenticalKeySets() throws {
        let englishKeys = try keys(forLanguageCode: "en")
        XCTAssertFalse(englishKeys.isEmpty, "English Localizable.strings should not be empty")

        for code in Self.languageCodes where code != "en" {
            let otherKeys = try keys(forLanguageCode: code)
            let missing = englishKeys.subtracting(otherKeys)
            let extra = otherKeys.subtracting(englishKeys)
            XCTAssertTrue(missing.isEmpty, "\(code).lproj is missing keys: \(missing.sorted())")
            XCTAssertTrue(extra.isEmpty, "\(code).lproj has orphaned keys not in English: \(extra.sorted())")
        }
    }
}
