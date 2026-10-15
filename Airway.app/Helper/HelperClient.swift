//
//  HelperClient.swift
//  
//
//  Created by John Cris Antor on 6/11/2026.
//

import Foundation
import ServiceManagement

final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()

    private var connection: NSXPCConnection?
    private let lock = NSLock()

    private final class PendingReply<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            resume(with: .success(value))
        }

        func resume(throwing error: Error) {
            resume(with: .failure(error))
        }

        private func resume(with result: Result<T, Error>) {
            lock.lock()
            guard let continuation else {
                lock.unlock()
                return
            }
            self.continuation = nil
            lock.unlock()

            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Helper Installation

    private enum Constants {
        static let helperLabel = "com.airway.helper"
        static let helperPlistName = "com.airway.helper.plist"
        static let xpcTimeoutSeconds: TimeInterval = 15
        /// Applying a mode is the one genuinely slow call: the helper may spend
        /// its whole mode-handoff budget (8s) coaxing the SMC into releasing
        /// manual control, plus per-fan settling delays. Timing that out at the
        /// read timeout reported a healthy helper as unreachable and sent the
        /// user to the "install helper" screen mid-change.
        static let setModeTimeoutSeconds: TimeInterval = 30
    }

    enum HelperInstallError: LocalizedError {
        case requiresApproval
        case registrationFailed(String)
        case unavailable

        var errorDescription: String? {
            switch self {
            case .requiresApproval:
                return "Airway needs approval in Login Items to run its helper."
            case .registrationFailed(let message):
                return "Unable to register the helper: \(message)"
            case .unavailable:
                return "The helper did not respond."
            }
        }
    }

    /// Launch-time health check. Does NOTHING when the installed helper is
    /// reachable and up to date — no re-registration churn, no daemon restart,
    /// no UI flash. Repairs (silently via SMAppService — never a credential
    /// prompt) only when the helper is unreachable or reports a stale version.
    func ensureHelperReadyAtLaunch() async throws {
        if let version = try? await fetchHelperVersion() {
            if version == HelperVersion.current {
                NSLog("[Airway] Helper healthy (version \(version)) — leaving it alone.")
                return
            }
            NSLog("[Airway] Helper version \(version) != \(HelperVersion.current) — refreshing binary.")
        } else {
            NSLog("[Airway] Helper unreachable at launch — attempting install/repair.")
        }
        invalidateConnection()
        try installOrRepairHelper(forceRepair: true)
    }

    // NOTE: There is deliberately NO SMJobBless fallback here. The helper is
    // embedded for SMAppService (Contents/MacOS + Contents/Library/LaunchDaemons);
    // it is NOT at Contents/Library/LaunchServices, so SMJobBless can never
    // succeed for this bundle — it only showed a pointless admin-password
    // prompt and then failed anyway. SMAppService needs no password at all:
    // first-time consent is macOS's own Login Items approval.
    func installOrRepairHelper(forceRepair: Bool = false) throws {
        guard #available(macOS 13.0, *) else { throw HelperInstallError.unavailable }
        let service = SMAppService.daemon(plistName: Constants.helperPlistName)

        switch service.status {
        case .enabled:
            if !forceRepair {
                NSLog("[Airway] Helper is already enabled via SMAppService.")
                return
            }
            // unregister()+register() is required (confirmed empirically —
            // register() alone does NOT pick up a changed on-disk helper
            // binary) to refresh a stale running daemon after an update.
            NSLog("[Airway] Reinstalling enabled helper to refresh to the current binary.")
            do {
                try service.unregister()
            } catch {
                NSLog("[Airway] SMAppService failed to unregister helper before repair: \(error.localizedDescription)")
            }
            do {
                try service.register()
            } catch {
                NSLog("[Airway] SMAppService failed to register after refresh: \(error.localizedDescription)")
            }
            invalidateConnection()
            if waitUntilEnabled(service) {
                NSLog("[Airway] Helper re-registered via SMAppService.")
                return
            }
            if service.status == .requiresApproval {
                throw HelperInstallError.requiresApproval
            }
            // Status can settle late after an unregister()+register() cycle even
            // though the daemon is fine (launchd starts it on the next XPC
            // connection). Don't treat that as failure — the caller verifies by
            // actually connecting.
            NSLog("[Airway] Helper status still \(service.status.rawValue) after re-registration; proceeding optimistically.")
        case .notFound, .notRegistered:
            do {
                try service.register()
                NSLog("[Airway] Helper registered with SMAppService. Status: \(service.status.rawValue)")
            } catch {
                NSLog("[Airway] SMAppService failed to register: \(error.localizedDescription)")
                if service.status == .requiresApproval {
                    throw HelperInstallError.requiresApproval
                }
                throw HelperInstallError.registrationFailed(error.localizedDescription)
            }
            if waitUntilEnabled(service) { return }
            if service.status == .requiresApproval {
                throw HelperInstallError.requiresApproval
            }
            throw HelperInstallError.registrationFailed("Helper status: \(service.status.rawValue)")
        case .requiresApproval:
            NSLog("[Airway] Helper requires approval in Login Items.")
            throw HelperInstallError.requiresApproval
        @unknown default:
            throw HelperInstallError.registrationFailed("Unknown helper status: \(service.status.rawValue)")
        }
    }

    /// Polls `service.status` for up to ~1.5s — it takes a moment to settle
    /// after register()/unregister() calls.
    @available(macOS 13.0, *)
    private func waitUntilEnabled(_ service: SMAppService) -> Bool {
        for _ in 1...15 {
            if service.status == .enabled { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return service.status == .enabled
    }

    func openHelperApprovalSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        } else {
            // Not supported on older macOS
        }
    }

    // MARK: - XPC Connection

    private func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: Constants.helperLabel, options: .privileged)
        conn.remoteObjectInterface = makeHelperInterface()
        conn.exportedInterface = nil
        conn.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.connection = nil }
        }
        conn.interruptionHandler = { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.connection = nil }
        }
        conn.resume()
        return conn
    }

    private func getConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let existing = connection {
            return existing
        }
        let conn = makeConnection()
        connection = conn
        return conn
    }

    // MARK: - RPC Methods

    func fetchFanInfo() async throws -> [FanInfoDTO] {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingReply<[FanInfoDTO]>(continuation)
            scheduleTimeout(for: pending)

            let conn = self.getConnection()
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                NSLog("[Airway] XPC Error in fetchFanInfo: \(error)")
                pending.resume(throwing: error)
            } as! HelperProtocol

            proxy.getFanInfo { info, error in
                if let error {
                    NSLog("[Airway] Helper returned error: \(error)")
                    pending.resume(throwing: error)
                } else {
                    pending.resume(returning: info)
                }
            }
        }
    }

    func fetchSystemTemperature() async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingReply<Double>(continuation)
            scheduleTimeout(for: pending)

            let conn = self.getConnection()
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                NSLog("[Airway] XPC Error in fetchSystemTemperature: \(error)")
                pending.resume(throwing: error)
            } as! HelperProtocol

            proxy.getSystemTemperature { temp, error in
                if let error {
                    NSLog("[Airway] Helper returned error: \(error)")
                    pending.resume(throwing: error)
                } else {
                    pending.resume(returning: temp)
                }
            }
        }
    }

    func setMode(_ mode: FanMode, percentages: [Int]) async throws {
        let nsPercentages = percentages.map { NSNumber(value: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = PendingReply<Void>(continuation)
            scheduleTimeout(for: pending, seconds: Constants.setModeTimeoutSeconds)

            let conn = self.getConnection()
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                pending.resume(throwing: error)
            } as! HelperProtocol

            proxy.setFanMode(mode, percentages: nsPercentages) { error in
                if let error {
                    pending.resume(throwing: error)
                } else {
                    pending.resume(returning: ())
                }
            }
        }
    }

    /// Quick health/staleness probe used at launch. Short timeout: a healthy
    /// daemon answers instantly, and a missing one fails fast so launch repair
    /// isn't delayed.
    func fetchHelperVersion() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingReply<String>(continuation)
            scheduleTimeout(for: pending, seconds: 3)

            let conn = self.getConnection()
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                pending.resume(throwing: error)
            } as! HelperProtocol

            proxy.getVersion { version in
                pending.resume(returning: version)
            }
        }
    }

    private func scheduleTimeout<T>(for pending: PendingReply<T>, seconds: TimeInterval = Constants.xpcTimeoutSeconds) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            pending.resume(throwing: HelperInstallError.unavailable)
        }
    }

    private func invalidateConnection() {
        lock.withLock {
            connection?.invalidate()
            connection = nil
        }
    }
}
