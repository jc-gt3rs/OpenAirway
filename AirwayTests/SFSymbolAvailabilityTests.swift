//
//  SFSymbolAvailabilityTests.swift
//
//  Guards Airway's SF Symbol usage against the macOS 13 deployment target.
//
//  `NSImage(systemSymbolName:)` returns nil — and SwiftUI's `Image(systemName:)`
//  renders nothing — for a symbol that postdates the running OS. That is how
//  `fan.fill` (SF Symbols 5 / macOS 14) crashed the menu bar on Ventura. These
//  tests read macOS's own CoreGlyphs availability table, so they are correct
//  regardless of which macOS the test host happens to be running.
//

import XCTest
@testable import Airway

final class SFSymbolAvailabilityTests: XCTestCase {

    /// Airway's deployment target. Keep in sync with `MACOSX_DEPLOYMENT_TARGET`.
    private static let deploymentTarget = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)

    // MARK: - CoreGlyphs availability table

    private static let availabilityPath =
        "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"

    /// Symbol name -> the earliest macOS that ships it, from CoreGlyphs.
    private static let minimumMacOS: [String: OperatingSystemVersion] = {
        guard let data = FileManager.default.contents(atPath: availabilityPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let releases = plist["year_to_release"] as? [String: [String: String]],
              let symbols = plist["symbols"] as? [String: String]
        else { return [:] }

        var table: [String: OperatingSystemVersion] = [:]
        for (name, year) in symbols {
            guard let macOS = releases[year]?["macOS"], let version = parse(macOS) else { continue }
            table[name] = version
        }
        return table
    }()

    private static func parse(_ version: String) -> OperatingSystemVersion? {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        return OperatingSystemVersion(
            majorVersion: major,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
    }

    private static func isAvailableOnDeploymentTarget(_ name: String) -> Bool {
        guard let minimum = minimumMacOS[name] else { return false }
        let target = deploymentTarget
        if minimum.majorVersion != target.majorVersion { return minimum.majorVersion < target.majorVersion }
        if minimum.minorVersion != target.minorVersion { return minimum.minorVersion < target.minorVersion }
        return minimum.patchVersion <= target.patchVersion
    }

    private func describe(_ name: String) -> String {
        guard let minimum = Self.minimumMacOS[name] else { return "\(name) (unknown to CoreGlyphs)" }
        return "\(name) (needs macOS \(minimum.majorVersion).\(minimum.minorVersion))"
    }

    func testAvailabilityTableLoaded() {
        XCTAssertFalse(
            Self.minimumMacOS.isEmpty,
            "Could not read the CoreGlyphs availability table at \(Self.availabilityPath); the symbol tests below cannot guard anything."
        )
        XCTAssertTrue(Self.isAvailableOnDeploymentTarget("wind"), "Sanity check: `wind` has shipped since macOS 10.15.")
        XCTAssertFalse(Self.isAvailableOnDeploymentTarget("fan.fill"), "Sanity check: `fan.fill` arrived with macOS 14.")
    }

    // MARK: - Compatibility chains

    /// Every chain must bottom out in a symbol that exists on the deployment
    /// target, otherwise the fallback itself is a blank icon on Ventura.
    func testEverySymbolChainEndsInADeploymentTargetSafeName() {
        XCTAssertFalse(AirwaySymbol.allChains.isEmpty, "No symbol chains declared.")
        for chain in AirwaySymbol.allChains {
            guard let fallback = chain.names.last else {
                return XCTFail("Symbol chain \(chain.label) is empty.")
            }
            XCTAssertTrue(
                Self.isAvailableOnDeploymentTarget(fallback),
                "Chain \(chain.label) bottoms out in \(describe(fallback)), which is not available on macOS 13."
            )
        }
    }

    /// The chain must resolve to something on the machine running the tests.
    func testEverySymbolChainResolvesOnThisMachine() {
        for chain in AirwaySymbol.allChains {
            XCTAssertNotNil(
                NSImage(systemSymbolName: chain.resolved, accessibilityDescription: nil),
                "Chain \(chain.label) resolved to \(chain.resolved), which this machine cannot render."
            )
        }
    }

    /// The Ventura path: when the preferred name is missing, the chain must
    /// fall through to the next one rather than hand back a name that resolves
    /// to nil. A nil here is what crashed the menu bar on macOS 13.
    func testChainFallsThroughWhenThePreferredSymbolIsMissing() {
        let chain = AirwaySymbol.Chain("test", ["airway.not.a.real.symbol", "fanblades.fill"])
        XCTAssertEqual(chain.resolved, "fanblades.fill")
        XCTAssertNotNil(NSImage(systemSymbolName: chain.resolved, accessibilityDescription: nil))
    }

    /// A chain whose names are all missing must still hand back a usable string
    /// rather than an empty one, so callers never build a nameless image.
    func testChainWithNoResolvableNameFallsBackToItsOldestName() {
        let chain = AirwaySymbol.Chain("test", ["airway.not.a.real.symbol", "airway.also.not.real"])
        XCTAssertEqual(chain.resolved, "airway.also.not.real")
    }

    // MARK: - Source scan

    /// No app source may name a post-13.0 symbol directly.
    ///
    /// This scans *every* string literal rather than just `systemName:` style
    /// arguments, because symbol names also reach AppKit through
    /// `systemImageName:`, through picker catalogues, and through plain `let`
    /// bindings — which is how several macOS 14 glyphs slipped in unnoticed.
    /// New symbols belong in an `AirwaySymbol` chain with an older fallback
    /// beside them, or behind `AirwaySymbol.renderable(_:)`.
    func testNoAppSourceNamesASymbolNewerThanTheDeploymentTarget() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AirwayTests
            .deletingLastPathComponent()  // repo root
        let sources = root.appendingPathComponent("Airway.app")

        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
            "Could not enumerate \(sources.path)"
        )

        let literal = try NSRegularExpression(pattern: #""([^"\\\n]+)""#)
        // Names inside this call are filtered against the running OS already.
        let filtered = try NSRegularExpression(pattern: #"AirwaySymbol\.renderable\(\[[^\]]*\]\)"#)

        var scannedFiles = 0
        var offenders: [String] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            // The chains deliberately name newer symbols beside their fallbacks.
            guard url.lastPathComponent != "AirwaySymbol.swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scannedFiles += 1

            // Blank out runtime-filtered catalogues, preserving line breaks so
            // reported line numbers stay accurate.
            let masked = NSMutableString(string: text)
            for match in filtered.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                let span = masked.substring(with: match.range)
                let blanked = String(span.map { $0.isNewline ? "\n" : " " })
                masked.replaceCharacters(in: match.range, with: blanked)
            }

            let scanned = masked as String
            for match in literal.matches(in: scanned, range: NSRange(location: 0, length: masked.length)) {
                guard let nameRange = Range(match.range(at: 1), in: scanned) else { continue }
                let name = String(scanned[nameRange])
                guard Self.minimumMacOS[name] != nil else { continue }          // not a symbol name
                guard !Self.isAvailableOnDeploymentTarget(name) else { continue }
                let line = scanned[scanned.startIndex..<nameRange.lowerBound].filter(\.isNewline).count + 1
                offenders.append("\(url.lastPathComponent):\(line) uses \(describe(name))")
            }
        }

        XCTAssertGreaterThan(scannedFiles, 0, "Scanned no Swift sources under \(sources.path).")
        XCTAssertTrue(
            offenders.isEmpty,
            "Symbols unavailable on macOS 13 are named directly:\n" + offenders.sorted().joined(separator: "\n")
        )
    }
}
