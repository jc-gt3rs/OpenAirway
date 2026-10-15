//
//  HelperProtocol.swift
//  
//
//  Created by John Cris Antor on 6/11/2026.
//

import Foundation

@objc(FanMode) enum FanMode: Int, Codable {
    case system = 0
    case manual = 1
    case max = 2
}

/// Bump this whenever the helper's code changes. At launch the app compares it
/// against the running daemon's reported version and only reinstalls the
/// helper when they differ (or the daemon is unreachable) — a healthy,
/// up-to-date helper is left completely untouched.
enum HelperVersion {
    static let current = "1.0.2"
}

/// Errors the helper reports for conditions that are NOT transport failures.
///
/// The distinction matters: `HelperClient` surfaces a timed-out or dropped XPC
/// call as "the helper did not respond", and the app answers that by offering
/// to reinstall the helper. A fan write the SMC firmware refused is a
/// completely different thing — the helper is healthy — and must not send the
/// user round the reinstall loop.
enum AirwayHelperError {
    static let domain = "com.airway.helper.FanControl"

    enum Code: Int {
        /// The hardware would not grant manual fan control.
        case fanControlUnsupported = 1
        /// No fans were reported by the SMC.
        case noFans = 2
    }

    static func error(_ code: Code, _ message: String) -> NSError {
        NSError(domain: domain, code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// True when `error` describes hardware that refused the request, rather
    /// than a helper that could not be reached.
    static func isHardwareRefusal(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == domain
            && nsError.code == Code.fanControlUnsupported.rawValue
    }
}

@objc(HelperProtocol) protocol HelperProtocol {
    func getFanInfo(reply: @escaping ([FanInfoDTO], Error?) -> Void)
    func getSystemTemperature(reply: @escaping (Double, Error?) -> Void)
    func setFanMode(_ mode: FanMode, percentages: [NSNumber], reply: @escaping (Error?) -> Void)
    func getVersion(reply: @escaping (String) -> Void)
}

@objc(FanInfoDTO) final class FanInfoDTO: NSObject, NSSecureCoding, Codable, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { return true }

    let index: Int
    let currentRPM: Double
    let minRPM: Double
    let maxRPM: Double
    let mode: FanMode
    /// True while the sustained-overheat safety override is holding the fans
    /// at Max. The app shows this so a user who set Manual and now sees Max
    /// understands why.
    let thermalOverrideActive: Bool

    init(index: Int, currentRPM: Double, minRPM: Double, maxRPM: Double, mode: FanMode, thermalOverrideActive: Bool = false) {
        self.index = index
        self.currentRPM = currentRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.mode = mode
        self.thermalOverrideActive = thermalOverrideActive
    }

    func encode(with coder: NSCoder) {
        coder.encode(index, forKey: "index")
        coder.encode(currentRPM, forKey: "currentRPM")
        coder.encode(minRPM, forKey: "minRPM")
        coder.encode(maxRPM, forKey: "maxRPM")
        coder.encode(mode.rawValue, forKey: "mode")
        coder.encode(thermalOverrideActive, forKey: "thermalOverrideActive")
    }

    init?(coder: NSCoder) {
        index = coder.decodeInteger(forKey: "index")
        currentRPM = coder.decodeDouble(forKey: "currentRPM")
        minRPM = coder.decodeDouble(forKey: "minRPM")
        maxRPM = coder.decodeDouble(forKey: "maxRPM")
        mode = FanMode(rawValue: coder.decodeInteger(forKey: "mode")) ?? .system
        thermalOverrideActive = coder.decodeBool(forKey: "thermalOverrideActive")
    }
}

/// Creates a properly configured `NSXPCInterface` for `HelperProtocol`,
/// with custom class whitelists for XPC serialization of `FanInfoDTO` and `NSNumber` arrays.
func makeHelperInterface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: HelperProtocol.self)

    // getFanInfo reply block parameter 0: [FanInfoDTO]
    let fanInfoClasses = NSSet(array: [NSArray.self, FanInfoDTO.self]) as! Set<AnyHashable>
    interface.setClasses(
        fanInfoClasses,
        for: #selector(HelperProtocol.getFanInfo(reply:)),
        argumentIndex: 0,
        ofReply: true
    )

    // setFanMode percentages parameter (argument index 1, not of reply)
    let numberClasses = NSSet(array: [NSArray.self, NSNumber.self]) as! Set<AnyHashable>
    interface.setClasses(
        numberClasses,
        for: #selector(HelperProtocol.setFanMode(_:percentages:reply:)),
        argumentIndex: 1,
        ofReply: false
    )

    return interface
}
