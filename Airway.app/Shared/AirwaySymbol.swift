//
//  AirwaySymbol.swift
//
//  SF Symbol names resolved against what the running macOS actually ships.
//
//  A symbol that postdates the running OS is not an error at build time: the
//  SDK knows it, so the compiler is happy, but at runtime
//  `NSImage(systemSymbolName:)` returns nil and SwiftUI's `Image(systemName:)`
//  draws nothing. Airway deploys back to macOS 13 while several symbols it
//  wants — `fan.fill`, `cable.connector.slash` — arrived with SF Symbols 5 on
//  macOS 14, so on Ventura they simply do not exist.
//
//  Each symbol is therefore a chain: the preferred name first, then older
//  stand-ins, ending in one that ships on the deployment target. Resolution
//  happens once, the first time the chain is touched.
//

import AppKit

enum AirwaySymbol {

    /// A preferred SF Symbol plus progressively older fallbacks.
    struct Chain {
        /// Name used in test failures and diagnostics.
        let label: String
        /// Preferred name first; the last entry must exist on the deployment target.
        let names: [String]
        /// The first name the running system actually ships.
        let resolved: String

        init(_ label: String, _ names: [String]) {
            self.label = label
            self.names = names
            // If nothing resolves — a symbol renamed out from under us — fall
            // back to the oldest name rather than an empty string, so callers
            // still get a well-formed (if blank) image instead of a surprise.
            self.resolved = names.first { name in
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            } ?? names.last ?? ""
        }
    }

    /// Airway's fan glyph. `fan.fill` is macOS 14+; `fanblades.fill` has shipped
    /// since macOS 12 and reads as the same object.
    static let fan = Chain("fan", ["fan.fill", "fanblades.fill"])

    /// Shown when the privileged helper is unreachable. `cable.connector.slash`
    /// is macOS 14+; the slashed antenna is macOS 12 and keeps the "no
    /// connection" reading, which is the whole job of the icon.
    static let disconnected = Chain("disconnected", [
        "cable.connector.slash",
        "antenna.radiowaves.left.and.right.slash",
    ])

    /// Shown when no controllable fan is present. `fan.slash` is macOS 14+;
    /// `fanblades.slash` has shipped since macOS 13.
    static let fanSlash = Chain("fanSlash", ["fan.slash", "fanblades.slash"])

    /// Siri/Shortcuts tile for the fan-status intent.
    /// `gauge.with.dots.needle.50percent` is macOS 14+; `gauge` is macOS 10.15.
    static let gauge = Chain("gauge", ["gauge.with.dots.needle.50percent", "gauge"])

    /// Every chain, so tests can check each one has a safe fallback.
    static let allChains: [Chain] = [fan, disconnected, fanSlash, gauge]

    /// Filters a symbol list down to what the running macOS can actually draw.
    ///
    /// The preset symbol picker offers a fixed catalogue that spans several SF
    /// Symbols releases. Rather than pin every entry to the deployment target,
    /// drop the ones this machine has never heard of — they would render as
    /// blank, unpickable tiles on an older macOS.
    static func renderable(_ names: [String]) -> [String] {
        names.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    }
}
