//
//  TokenVerifier.swift
//
//
//  Created by John Cris Antor on 6/20/2026.
//

import Foundation
import CryptoKit

/// Decoded license token payload. Only trusted after ES256 signature verification.
struct LicenseToken: Equatable {
    enum TokenType: String, Codable, Equatable {
        case beta
        case trial
        case paid
    }

    let type: TokenType
    let email: String
    let machineId: String?
    let licenseId: String
    let issuedAt: Date
    let expiresAt: Date?  // nil for beta tokens — they never expire
    let maxMachines: Int?
}

/// ES256 JWT signature verifier using the bundled public key.
///
/// Tokens are only trusted after their signature has been verified against
/// this key. A token that fails verification is treated as "no token."
enum TokenVerifier {
    // MARK: - Embedded Public Key (ES256 / P-256)
    //
    // This is the server's public key. It is compiled into the binary as an
    // immutable constant — never fetched remotely, never writable at runtime.

    private static let publicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfVZUQHlQW/xxCFP2JEhuS5upiqAD
    VGAW+3QfRou7Hixo0meCYF2MDcW1nPk+uKGzWVUSmBUnDHMXZOVKLUdnbg==
    -----END PUBLIC KEY-----
    """

    /// Parsed P-256 public key, derived once from the PEM constant.
    private static let publicKey: P256.Signing.PublicKey = {
        // Strip PEM armor and whitespace to get raw base64
        let base64 = publicKeyPEM
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let derData = Data(base64Encoded: base64) else {
            fatalError("[Airway] Failed to base64-decode the embedded public key.")
        }

        do {
            return try P256.Signing.PublicKey(derRepresentation: derData)
        } catch {
            fatalError("[Airway] Failed to parse the embedded ES256 public key: \(error)")
        }
    }()

    // MARK: - JWT Verification

    /// Verifies the ES256 signature of a JWT and decodes its payload.
    ///
    /// - Parameter token: The raw JWT string (`header.payload.signature`).
    /// - Returns: A `LicenseToken` if the signature is valid and the payload
    ///   decodes correctly, or `nil` if verification fails for any reason
    ///   (tampered, corrupted, wrong key, malformed).
    static func verify(token: String) -> LicenseToken? {
        let parts = token.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            NSLog("[Airway] JWT has \(parts.count) parts, expected 3.")
            return nil
        }

        let headerB64 = String(parts[0])
        let payloadB64 = String(parts[1])
        let signatureB64 = String(parts[2])

        // The signature is computed over the ASCII bytes of "header.payload"
        let signedData = Data("\(headerB64).\(payloadB64)".utf8)

        // Decode the signature from base64url
        guard let signatureData = base64URLDecode(signatureB64) else {
            NSLog("[Airway] Failed to decode JWT signature.")
            return nil
        }

        // ES256 JWTs use a raw (r||s) 64-byte signature.
        // CryptoKit's P256.Signing.ECDSASignature expects raw representation.
        let signature: P256.Signing.ECDSASignature
        do {
            signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        } catch {
            NSLog("[Airway] Invalid ES256 signature format: \(error)")
            return nil
        }

        // Verify the signature against our embedded public key
        guard publicKey.isValidSignature(signature, for: signedData) else {
            NSLog("[Airway] JWT signature verification FAILED — token is not trusted.")
            return nil
        }

        // Signature is valid — now decode the payload
        guard let payloadData = base64URLDecode(payloadB64) else {
            NSLog("[Airway] Failed to decode JWT payload.")
            return nil
        }

        return decodePayload(payloadData)
    }

    // MARK: - Helpers

    /// Decodes a base64url-encoded string (RFC 7515) to raw bytes.
    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Pad to a multiple of 4
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(contentsOf: String(repeating: "=", count: 4 - remainder))
        }

        return Data(base64Encoded: base64)
    }

    /// Decodes the JWT payload JSON into a `LicenseToken`.
    private static func decodePayload(_ data: Data) -> LicenseToken? {
        // Decode into a flexible structure first to handle optional `exp`
        struct JWTPayload: Decodable {
            let type: LicenseToken.TokenType
            let email: String
            let machineId: String?
            let licenseId: String
            let iat: TimeInterval
            let exp: TimeInterval?
            let maxMachines: Int?
            let maxDevices: Int?
        }

        do {
            let payload = try JSONDecoder().decode(JWTPayload.self, from: data)
            return LicenseToken(
                type: payload.type,
                email: payload.email,
                machineId: payload.machineId,
                licenseId: payload.licenseId,
                issuedAt: Date(timeIntervalSince1970: payload.iat),
                expiresAt: payload.exp.map { Date(timeIntervalSince1970: $0) },
                maxMachines: payload.maxMachines ?? payload.maxDevices
            )
        } catch {
            NSLog("[Airway] Failed to decode JWT payload: \(error)")
            return nil
        }
    }
}
