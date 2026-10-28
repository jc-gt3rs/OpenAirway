//
//  TokenVerifierTests.swift
//
//  Security-critical robustness tests for TokenVerifier. These verify the app
//  REFUSES to trust malformed or tampered tokens. (The valid-signature happy
//  path requires the server's private key and is covered by the live server
//  validator in scripts/validate-license-server.swift.)
//

import XCTest
@testable import Airway

final class TokenVerifierTests: XCTestCase {

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeSegment(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return base64URL(data)
    }

    func testVerify_emptyString_returnsNil() {
        XCTAssertNil(TokenVerifier.verify(token: ""))
    }

    func testVerify_wrongPartCount_returnsNil() {
        XCTAssertNil(TokenVerifier.verify(token: "onlyonepart"))
        XCTAssertNil(TokenVerifier.verify(token: "two.parts"))
        XCTAssertNil(TokenVerifier.verify(token: "a.b.c.d.e"))
    }

    func testVerify_garbageSegments_returnsNil() {
        XCTAssertNil(TokenVerifier.verify(token: "@@@.@@@.@@@"))
    }

    func testVerify_wellFormedButUnsigned_returnsNil() {
        // Valid base64url header + payload, but a random (invalid) signature.
        // Must be rejected — we never trust an unverified token.
        let header = makeSegment(["alg": "ES256", "typ": "JWT"])
        let payload = makeSegment([
            "type": "paid",
            "email": "attacker@example.com",
            "licenseId": "forged",
            "iat": Date().timeIntervalSince1970,
            "exp": Date().timeIntervalSince1970 + 99_999_999
        ])
        let fakeSignature = base64URL(Data((0..<64).map { _ in UInt8.random(in: 0...255) }))
        let forged = "\(header).\(payload).\(fakeSignature)"

        XCTAssertNil(TokenVerifier.verify(token: forged),
                     "A token with an invalid signature must never verify.")
    }

    func testVerify_tamperedPayload_returnsNil() {
        // Even a structurally perfect JWT whose signature doesn't cover the
        // payload must be rejected.
        let header = makeSegment(["alg": "ES256", "typ": "JWT"])
        let payload = makeSegment([
            "type": "beta",
            "email": "someone@example.com",
            "licenseId": "abc",
            "iat": Date().timeIntervalSince1970
        ])
        // Signature is the right *length* but wrong *value*.
        let sig = base64URL(Data(repeating: 0x01, count: 64))
        XCTAssertNil(TokenVerifier.verify(token: "\(header).\(payload).\(sig)"))
    }

    // MARK: - License types (incident 2026-10-28)

    private func payload(type: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": type,
            "email": "student@example.edu",
            "machineId": "M1",
            "licenseId": "L1",
            "iat": 1_800_000_000,
            "exp": 1_900_000_000,
            "maxMachines": 1
        ])
    }

    func testStudentLicenseDecodesAsPaid() throws {
        // Student licenses were rejected as "an invalid token" because the
        // app only knew beta/trial/paid.
        let token = try XCTUnwrap(TokenVerifier.decodePayload(payload(type: "student")),
                                  "a student token must decode")
        XCTAssertEqual(token.type, .paid)
        XCTAssertEqual(token.licenseName, "student")
        XCTAssertEqual(token.maxMachines, 1)
    }

    func testUnknownFutureLicenseTypeDecodesAsPaid() throws {
        // A type the server adds later must never lock users out again.
        let token = try XCTUnwrap(TokenVerifier.decodePayload(payload(type: "education-site-license")))
        XCTAssertEqual(token.type, .paid)
        XCTAssertEqual(token.licenseName, "education-site-license")
    }

    func testKnownTypesStillDecodeAsThemselves() throws {
        for (raw, expected) in [("beta", LicenseToken.TokenType.beta), ("trial", .trial), ("paid", .paid)] {
            let token = try XCTUnwrap(TokenVerifier.decodePayload(payload(type: raw)))
            XCTAssertEqual(token.type, expected, raw)
            XCTAssertEqual(token.licenseName, raw)
        }
    }
}
