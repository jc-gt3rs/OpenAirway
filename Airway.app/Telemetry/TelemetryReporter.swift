//
//  TelemetryReporter.swift
//
//  Beta telemetry + feedback. Sends structured crash reports and user feedback
//  to the self-hosted Airway server so problems surface without waiting on a
//  tester to email. Everything here is best-effort and fire-and-forget: it must
//  never block the UI, and a telemetry failure must never affect fan control.
//
//  Server endpoints this expects (see scripts/SERVER-SPEC.md):
//    POST /telemetry/feedback  → 2xx on success
//    POST /telemetry/crash     → 2xx on success
//
//  Created for the beta hardening pass.
//

import Foundation
import os
import OSLog
import IOKit

// MARK: - Structured logging

/// Central os.Logger handles. Prefer these over NSLog for anything new so logs
/// are queryable in Console.app and can be exported for a bug report.
enum AirwayLog {
    private static let subsystem = "com.airway.app"
    static let general = Logger(subsystem: subsystem, category: "general")
    static let fans = Logger(subsystem: subsystem, category: "fans")
    static let license = Logger(subsystem: subsystem, category: "license")
    static let telemetry = Logger(subsystem: subsystem, category: "telemetry")
}

// MARK: - Device / app context

/// Immutable snapshot of the app + machine, attached to every report.
struct TelemetryContext: Encodable {
    let appVersion: String
    let build: String
    let osVersion: String
    let machineId: String
    let model: String

    static let current: TelemetryContext = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return TelemetryContext(
            appVersion: version,
            build: build,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            machineId: TelemetryContext.platformUUID(),
            model: TelemetryContext.hardwareModel()
        )
    }()

    /// Same source as MachineID, duplicated here so telemetry has no dependency
    /// on the license layer.
    private static func platformUUID() -> String {
        let match = IOServiceMatching("IOPlatformExpertDevice")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != IO_OBJECT_NULL else { return "unknown" }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString,
                                                kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String) ?? "unknown"
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

// MARK: - Reporter

enum TelemetryReporter {
    /// Must match the base URL used by LicenseAPIClient.
    private static let baseURL = URL(string: "https://jc.didthat.lol/airway")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: Feedback

    enum FeedbackCategory: String, Encodable, CaseIterable, Identifiable {
        case bug, idea, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bug: return "Bug"
            case .idea: return "Idea"
            case .other: return "Other"
            }
        }
    }

    /// Sends user feedback. Returns true on a 2xx response, false otherwise.
    /// Awaited by the feedback UI so it can show success/failure.
    @discardableResult
    static func sendFeedback(category: FeedbackCategory, message: String,
                             contactEmail: String?) async -> Bool {
        struct Payload: Encodable {
            let kind = "feedback"
            let category: FeedbackCategory
            let message: String
            let contactEmail: String?
            let logs: [String]
            let context: TelemetryContext
            let ts: TimeInterval
        }
        // Cap every field before it leaves the client. This bounds the payload
        // size and is defense-in-depth only — it does NOT protect the endpoint
        // from an attacker POSTing directly. Real abuse protection (rate limiting,
        // body-size limits, auth) must live server-side. See
        // from-server/telemetry-hardening.md.
        let cappedMessage = String(message.prefix(2000))
        let cappedEmail = contactEmail.flatMap { $0.isEmpty ? nil : String($0.prefix(256)) }
        let cappedLogs = recentLogTail().prefix(200).map { String($0.prefix(500)) }

        let payload = Payload(
            category: category,
            message: cappedMessage,
            contactEmail: cappedEmail,
            logs: Array(cappedLogs),
            context: .current,
            ts: Date().timeIntervalSince1970
        )
        return await post(path: "/telemetry/feedback", payload: payload)
    }

    // MARK: Crash reporting

    private static var crashFileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("Airway", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("pending-crash.json")
    }

    /// Persists a crash so it can be uploaded on next launch (we can't reliably
    /// finish a network call from inside an exception handler).
    static func persistCrash(name: String, reason: String, callStack: [String]) {
        guard let url = crashFileURL else { return }
        struct Crash: Encodable {
            let kind = "crash"
            let name: String
            let reason: String
            let callStack: [String]
            let context: TelemetryContext
            let ts: TimeInterval
        }
        let crash = Crash(name: name, reason: reason, callStack: callStack,
                          context: .current, ts: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(crash) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Uploads and clears any crash captured on a previous run. Call once at launch.
    static func flushPendingCrashReport() {
        guard let url = crashFileURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) else { return }
        Task {
            let ok = await postRaw(path: "/telemetry/crash", jsonObject: json)
            if ok {
                try? FileManager.default.removeItem(at: url)
                AirwayLog.telemetry.info("Flushed pending crash report.")
            } else {
                AirwayLog.telemetry.error("Failed to flush crash report; will retry next launch.")
            }
        }
    }

    // MARK: Networking

    private static func post<T: Encodable>(path: String, payload: T) async -> Bool {
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        return await send(path: path, body: data)
    }

    private static func postRaw(path: String, jsonObject: Any) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject) else { return false }
        return await send(path: path, body: data)
    }

    private static func send(path: String, body: Data) async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (_, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (200...299).contains(code)
        } catch {
            AirwayLog.telemetry.error("Telemetry POST \(path) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Log capture

    /// Best-effort tail of this process's recent os_log entries, attached to
    /// feedback so a bug report carries context. Never throws to the caller.
    private static func recentLogTail(limit: Int = 200) -> [String] {
        guard #available(macOS 12.0, *) else { return [] }
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(timeIntervalSinceLatestBoot: 1)
            let entries = try store.getEntries(at: since)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == "com.airway.app" }
                .suffix(limit)
                .map { "[\($0.category)] \($0.composedMessage)" }
            return Array(entries)
        } catch {
            return []
        }
    }
}

// MARK: - Crash catcher

/// Installs a top-level NSException handler that persists the crash for upload
/// on next launch. This catches Objective-C exceptions (the common case for AppKit
/// misuse); it does not catch pure Swift fatalErrors or signals, which is an
/// acceptable limitation for a beta feedback loop.
enum CrashCatcher {
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            TelemetryReporter.persistCrash(
                name: exception.name.rawValue,
                reason: exception.reason ?? "unknown",
                callStack: exception.callStackSymbols
            )
        }
    }
}
