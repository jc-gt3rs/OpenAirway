//
//  HelperErrorRoutingTests.swift
//
//  The reported M5 bug was a routing bug as much as a hardware one: EVERY
//  failed fan write was reported as a connection error, which renders the
//  "Enable the helper" screen. Tapping Manual/Max therefore produced
//  spinner -> "install helper" -> back to the fan list, forever, even though
//  the helper was healthy the whole time.
//
//  These tests pin the classification that keeps a hardware refusal out of
//  that screen.
//

import XCTest
@testable import Airway

final class HelperErrorRoutingTests: XCTestCase {

    func testHardwareRefusalIsRecognised() {
        let error = AirwayHelperError.error(
            .fanControlUnsupported,
            "This Mac's firmware refused manual control of fan 0."
        )
        XCTAssertTrue(
            AirwayHelperError.isHardwareRefusal(error),
            "a refused fan write must be shown inline, not as a broken helper"
        )
    }

    func testHelperTimeoutIsNotAHardwareRefusal() {
        // What a timed-out or dropped XPC call surfaces as. This one SHOULD
        // reach the "Enable the helper" screen — the helper really is gone.
        XCTAssertFalse(AirwayHelperError.isHardwareRefusal(HelperClient.HelperInstallError.unavailable))
        XCTAssertFalse(AirwayHelperError.isHardwareRefusal(HelperClient.HelperInstallError.requiresApproval))
    }

    func testXPCConnectionErrorIsNotAHardwareRefusal() {
        let xpcError = NSError(domain: NSCocoaErrorDomain, code: 4099,
                               userInfo: [NSLocalizedDescriptionKey: "connection invalid"])
        XCTAssertFalse(AirwayHelperError.isHardwareRefusal(xpcError))
    }

    func testNoFansIsNotClassifiedAsARefusal() {
        // "No fans" is a real hardware fact, but it has its own UI (the
        // no-fan-detected view) and must not be confused with a refusal.
        let error = AirwayHelperError.error(.noFans, "This Mac reports no controllable fans.")
        XCTAssertFalse(AirwayHelperError.isHardwareRefusal(error))
    }

    func testAnUnrelatedErrorSharingTheCodeIsNotARefusal() {
        // Guards against matching on the code alone: plenty of domains use 1.
        let lookalike = NSError(domain: "SomeOtherDomain", code: 1)
        XCTAssertFalse(AirwayHelperError.isHardwareRefusal(lookalike))
    }

    func testRefusalMessageSurvivesTheRoundTrip() {
        let message = "This Mac's firmware refused manual control of fan 1."
        let error = AirwayHelperError.error(.fanControlUnsupported, message)
        XCTAssertEqual(error.localizedDescription, message)
    }
}
