//
//  LicenseAPIClient.swift
//
//
//  Created by John Cris Antor on 6/20/2026.
//

import Foundation

/// Errors from the license API, distinguishing network failures from server rejections.
///
/// This distinction is critical: network failures must never lock out a paid user,
/// while server rejections (e.g. `valid: false`) carry authoritative denial semantics.
enum LicenseAPIError: LocalizedError {
    /// The request could not reach the server (timeout, no connection, DNS failure, etc.).
    /// Must be treated as a soft, retryable failure — never as a denial.
    case networkFailure(underlying: Error)

    /// The server responded with a 4xx or 5xx status and an error message.
    /// The message should be surfaced to the user exactly as-is.
    case serverRejection(statusCode: Int, message: String)

    /// The response body could not be decoded.
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .networkFailure(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverRejection(_, let message):
            return message
        case .decodingError(let error):
            return "Unexpected server response: \(error.localizedDescription)"
        }
    }

    /// Whether this error represents a network connectivity issue (as opposed
    /// to an authoritative server rejection).
    var isNetworkFailure: Bool {
        if case .networkFailure = self { return true }
        return false
    }
}

/// Response from the `/license/verify` endpoint.
struct VerifyResponse: Decodable {
    let valid: Bool
    let reason: String?
    let token: String?
    /// Device usage for this license. Optional — older servers may omit these.
    let deviceCount: Int?
    /// Plan cap for this license. `maxDevices` is accepted as an older alias.
    let maxMachines: Int?

    private enum CodingKeys: String, CodingKey {
        case valid
        case reason
        case token
        case deviceCount
        case maxMachines
        case maxDevices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        valid = try container.decode(Bool.self, forKey: .valid)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        deviceCount = try container.decodeIfPresent(Int.self, forKey: .deviceCount)
        maxMachines = try container.decodeIfPresent(Int.self, forKey: .maxMachines)
            ?? container.decodeIfPresent(Int.self, forKey: .maxDevices)
    }
}

/// Async/await API client for the Airway license server.
///
/// Base URL: `https://jc.didthat.lol/airway`
///
/// All methods distinguish network failures from server rejections via
/// `LicenseAPIError` so callers can implement the correct retry/lockout policy.
enum LicenseAPIClient {
    private static let baseURL = URL(string: "https://jc.didthat.lol/airway")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Public API

    /// Starts a trial for the given email and machine.
    /// - Returns: The JWT token string from the server.
    static func startTrial(email: String, machineId: String) async throws -> String {
        struct Request: Encodable {
            let email: String
            let machineId: String
        }
        struct Response: Decodable {
            let token: String
        }

        let body = Request(email: email, machineId: machineId)
        let response: Response = try await post(path: "/license/trial/start", body: body)
        return response.token
    }

    /// Activates a paid license.
    /// - Returns: The JWT token string from the server.
    static func activate(email: String, licenseKey: String, machineId: String) async throws -> String {
        struct Request: Encodable {
            let email: String
            let licenseKey: String
            let machineId: String
        }
        struct Response: Decodable {
            let token: String
        }

        let body = Request(email: email, licenseKey: licenseKey, machineId: machineId)
        let response: Response = try await post(path: "/license/activate", body: body)
        return response.token
    }

    /// Verifies an existing token with the server.
    /// - Returns: A `VerifyResponse` indicating validity and an optional refreshed token.
    static func verify(token: String, machineId: String) async throws -> VerifyResponse {
        struct Request: Encodable {
            let token: String
            let machineId: String
        }

        let body = Request(token: token, machineId: machineId)
        return try await post(path: "/license/verify", body: body)
    }

    // MARK: - Internal Networking

    /// Performs a POST request, decoding the response as the given `Decodable` type.
    ///
    /// Wraps `URLError` and connectivity failures as `.networkFailure`.
    /// Wraps HTTP 4xx/5xx as `.serverRejection` with the server's error message.
    private static func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw LicenseAPIError.decodingError(error)
        }

        let data: Data
        let httpResponse: HTTPURLResponse

        do {
            let (responseData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LicenseAPIError.networkFailure(underlying: URLError(.badServerResponse))
            }
            data = responseData
            httpResponse = http
        } catch let error as LicenseAPIError {
            throw error
        } catch {
            // Any URLError or other transport error is a network failure
            throw LicenseAPIError.networkFailure(underlying: error)
        }

        // Check for server rejections (4xx/5xx)
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = extractErrorMessage(from: data) ?? "Server error (\(httpResponse.statusCode))"
            throw LicenseAPIError.serverRejection(statusCode: httpResponse.statusCode, message: message)
        }

        // Decode the successful response
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw LicenseAPIError.decodingError(error)
        }
    }

    /// Attempts to extract a human-readable error message from a server error response.
    /// Tries JSON `{ "error": "..." }` first, then `{ "message": "..." }`, then raw text.
    private static func extractErrorMessage(from data: Data) -> String? {
        // Try JSON with "error" key
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? String { return error }
            if let message = json["message"] as? String { return message }
        }
        // Fall back to raw text if it's short enough to be a message
        if let text = String(data: data, encoding: .utf8), text.count < 500 {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
