//
//  ThermalSafetyPolicyTests.swift
//
//  Unit tests for the sustained-overheat safety override state machine.
//  `ThermalSafetyPolicy` is pure and takes `now` as a parameter, so the whole
//  three-minute trigger window is exercised without any real waiting and
//  without live SMC hardware.
//

import XCTest
@testable import Airway

final class ThermalSafetyPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    // MARK: - Engaging

    func testStaysQuietWhileBelowTheTriggerTemperature() {
        var policy = ThermalSafetyPolicy()
        for second in stride(from: 0.0, through: 600.0, by: 10.0) {
            XCTAssertEqual(
                policy.evaluate(temperature: 89.9, mode: .manual, now: at(second)),
                .none,
                "89.9C must never trigger the 90C override"
            )
        }
        XCTAssertFalse(policy.isEngaged)
    }

    func testDoesNotEngageBeforeTheSustainedWindowElapses() {
        var policy = ThermalSafetyPolicy()
        XCTAssertEqual(policy.evaluate(temperature: 95, mode: .manual, now: at(0)), .none)
        XCTAssertEqual(policy.evaluate(temperature: 95, mode: .manual, now: at(60)), .none)
        XCTAssertEqual(policy.evaluate(temperature: 95, mode: .manual, now: at(179)), .none)
        XCTAssertFalse(policy.isEngaged)
    }

    func testEngagesOnceTheSustainedWindowElapses() {
        var policy = ThermalSafetyPolicy()
        _ = policy.evaluate(temperature: 90, mode: .manual, now: at(0))
        XCTAssertEqual(
            policy.evaluate(temperature: 90, mode: .manual, now: at(180)),
            .engage,
            "3 minutes at exactly 90C must engage the override"
        )
        XCTAssertTrue(policy.isEngaged)
    }

    func testEngagesOnlyOnceWhileItStaysHot() {
        var policy = ThermalSafetyPolicy()
        _ = policy.evaluate(temperature: 99, mode: .manual, now: at(0))
        XCTAssertEqual(policy.evaluate(temperature: 99, mode: .manual, now: at(180)), .engage)
        // Already engaged — no repeated commands to the SMC.
        XCTAssertEqual(policy.evaluate(temperature: 99, mode: .max, now: at(240)), .none)
        XCTAssertEqual(policy.evaluate(temperature: 99, mode: .max, now: at(600)), .none)
    }

    func testDippingBelowTheThresholdRestartsTheClock() {
        var policy = ThermalSafetyPolicy()
        _ = policy.evaluate(temperature: 95, mode: .manual, now: at(0))
        _ = policy.evaluate(temperature: 95, mode: .manual, now: at(170))
        // A cool moment resets the sustained window.
        _ = policy.evaluate(temperature: 70, mode: .manual, now: at(175))
        _ = policy.evaluate(temperature: 95, mode: .manual, now: at(180))
        XCTAssertEqual(
            policy.evaluate(temperature: 95, mode: .manual, now: at(300)),
            .none,
            "only 120s of sustained heat since the dip — must not engage yet"
        )
        XCTAssertEqual(policy.evaluate(temperature: 95, mode: .manual, now: at(360)), .engage)
    }

    // MARK: - Which modes arm the override

    func testDoesNotArmUnderSystemControl() {
        var policy = ThermalSafetyPolicy()
        _ = policy.evaluate(temperature: 99, mode: .system, now: at(0))
        XCTAssertEqual(
            policy.evaluate(temperature: 99, mode: .system, now: at(600)),
            .none,
            "macOS owns thermal management in Auto — Airway must not override it"
        )
    }

    func testDoesNotArmWhenAlreadyAtMax() {
        var policy = ThermalSafetyPolicy()
        _ = policy.evaluate(temperature: 99, mode: .max, now: at(0))
        XCTAssertEqual(policy.evaluate(temperature: 99, mode: .max, now: at(600)), .none)
    }

    func testHeatAccumulatedUnderSystemControlDoesNotCarryIntoManual() {
        var policy = ThermalSafetyPolicy()
        _ = policy.evaluate(temperature: 99, mode: .system, now: at(0))
        _ = policy.evaluate(temperature: 99, mode: .manual, now: at(170))
        XCTAssertEqual(
            policy.evaluate(temperature: 99, mode: .manual, now: at(200)),
            .none,
            "the clock starts when manual control begins, not before"
        )
    }

    // MARK: - Releasing

    private func engagedPolicy() -> ThermalSafetyPolicy {
        var policy = ThermalSafetyPolicy()
        _ = policy.evaluate(temperature: 99, mode: .manual, now: at(0))
        XCTAssertEqual(policy.evaluate(temperature: 99, mode: .manual, now: at(180)), .engage)
        return policy
    }

    func testReleasesAfterSustainedCooling() {
        var policy = engagedPolicy()
        _ = policy.evaluate(temperature: 70, mode: .max, now: at(200))
        XCTAssertEqual(
            policy.evaluate(temperature: 70, mode: .max, now: at(260)),
            .release,
            "60s below the 80C release threshold must hand control back"
        )
        XCTAssertFalse(policy.isEngaged)
    }

    func testDoesNotReleaseOnABriefDip() {
        var policy = engagedPolicy()
        _ = policy.evaluate(temperature: 70, mode: .max, now: at(200))
        _ = policy.evaluate(temperature: 85, mode: .max, now: at(230))
        XCTAssertEqual(
            policy.evaluate(temperature: 70, mode: .max, now: at(280)),
            .none,
            "the cooling window restarts when the temperature climbs back"
        )
        XCTAssertTrue(policy.isEngaged)
    }

    func testDoesNotReleaseWhileStillAboveTheReleaseThreshold() {
        var policy = engagedPolicy()
        _ = policy.evaluate(temperature: 80.1, mode: .max, now: at(200))
        XCTAssertEqual(policy.evaluate(temperature: 80.1, mode: .max, now: at(600)), .none)
        XCTAssertTrue(policy.isEngaged)
    }

    func testReleaseIsEmittedOnlyOnce() {
        var policy = engagedPolicy()
        _ = policy.evaluate(temperature: 60, mode: .max, now: at(200))
        XCTAssertEqual(policy.evaluate(temperature: 60, mode: .max, now: at(260)), .release)
        XCTAssertEqual(policy.evaluate(temperature: 60, mode: .manual, now: at(320)), .none)
    }

    // MARK: - Reset

    func testResetDisarmsAndForgetsAccumulatedHeat() {
        var policy = ThermalSafetyPolicy()
        _ = policy.evaluate(temperature: 99, mode: .manual, now: at(0))
        _ = policy.evaluate(temperature: 99, mode: .manual, now: at(179))
        policy.reset()
        XCTAssertFalse(policy.isEngaged)
        XCTAssertEqual(
            policy.evaluate(temperature: 99, mode: .manual, now: at(181)),
            .none,
            "a user-initiated mode change clears the accumulated window"
        )
    }

    // MARK: - Bad readings

    func testIgnoresUnreadableTemperature() {
        // `systemTemperature()` returns 0 when no sensor key decodes. That is a
        // read failure, not a cold machine, and must neither engage nor count
        // as cooling.
        var policy = engagedPolicy()
        _ = policy.evaluate(temperature: 0, mode: .max, now: at(200))
        XCTAssertEqual(policy.evaluate(temperature: 0, mode: .max, now: at(600)), .none)
        XCTAssertTrue(policy.isEngaged, "a failed sensor read must not silently release the override")
    }

    func testIgnoresImplausiblyHighTemperature() {
        var policy = ThermalSafetyPolicy()
        _ = policy.evaluate(temperature: 999, mode: .manual, now: at(0))
        XCTAssertEqual(policy.evaluate(temperature: 999, mode: .manual, now: at(600)), .none)
    }
}
