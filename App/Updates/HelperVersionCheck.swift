import Foundation
import SuijinPTYProtocol
import SuijinTerminal
import os

/// Hands the PTY host over to the new version after an update.
///
/// Sparkle replaces Suijin.app (and with it Contents/MacOS/SuijinPTYHost), but the helper launchd started from the
/// old bundle keeps running, so the updated app would talk to the old helper. At launch this check compares the app's
/// `CFBundleVersion` with the build the helper reports in its handshake. On a mismatch with no session running it asks
/// the helper to exit, and launchd starts the new binary on the next connection. A helper that still runs sessions is
/// left alone: it exits by itself once those sessions end and Suijin disconnects, and the next launch gets the new one.
/// A helper that speaks an older but compatible protocol is handled the same way; until it is replaced the app uses
/// only that protocol's features.
@MainActor
enum HelperVersionCheck {
    enum Outcome: Equatable, Sendable {
        /// The helper runs the app's build, or it is a development helper with no build to compare.
        case current
        /// The old helper exited and the new one answered.
        case replaced(from: String, to: String)
        /// The old helper runs sessions, so it stays until they end.
        case deferred(host: String, app: String)
        /// The old helper was asked to exit but no new helper answered in time; the next launch retries.
        case pending(host: String, app: String)
        /// No helper answered (not registered yet, or waiting for approval); session bootstrap reports why.
        case unavailable(String)
    }

    private static let logger = Logger(subsystem: "com.tekmium.suijin", category: "helper-version")

    /// Runs the check once. Call it after the sessions bootstrap registered the helper.
    @discardableResult
    static func run(
        client: PTYHostClient = .shared,
        appBuild: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        attempts: Int = 20,
        retryInterval: Duration = .milliseconds(250)
    ) async -> Outcome {
        let reported: String
        do {
            reported = try await client.handshake()
        } catch {
            return .unavailable(error.localizedDescription)
        }
        // A helper on an older protocol (still compatible, so the app attached to it) is replaced the same way: only
        // once it is idle, so the user's running sessions are never cut.
        let olderProtocol = (client.hostProtocolVersion ?? PTYHostConstants.protocolVersion) < PTYHostConstants.protocolVersion
        guard let appBuild, olderProtocol || isStale(hostBuild: reported, appBuild: appBuild) else { return .current }

        let sessions: [PTYSessionInfo]
        do {
            sessions = try await client.listSessions()
        } catch {
            return .unavailable(error.localizedDescription)
        }
        guard !sessions.contains(where: \.isRunning) else {
            logger.notice("PTY host \(reported, privacy: .public) is older than app build \(appBuild, privacy: .public); it runs sessions, so it stays until they end")
            return .deferred(host: reported, app: appBuild)
        }

        logger.notice("PTY host \(reported, privacy: .public) is older than app build \(appBuild, privacy: .public); asking it to exit")
        client.shutdownHostIfIdle()
        // The client keeps reporting the old build until the helper's exit interrupts the connection; the next
        // handshake after that reaches the helper launchd starts from the updated bundle.
        for _ in 0..<max(attempts, 1) {
            try? await Task.sleep(for: retryInterval)
            guard let fresh = try? await client.handshake() else { continue }
            let current = (client.hostProtocolVersion ?? 0) >= PTYHostConstants.protocolVersion
            if current, !isStale(hostBuild: fresh, appBuild: appBuild) {
                logger.notice("PTY host replaced: \(reported, privacy: .public) -> \(fresh, privacy: .public)")
                return .replaced(from: reported, to: fresh)
            }
        }
        logger.error("PTY host \(reported, privacy: .public) did not hand over to build \(appBuild, privacy: .public)")
        return .pending(host: reported, app: appBuild)
    }

    /// The bundle build inside the helper's handshake string: "0.1.0 (12)" and "12" give "12"; "dev" and "" give nil.
    nonisolated static func build(fromHostBuild value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") {
            let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            let build = inner.trimmingCharacters(in: .whitespaces)
            return build.isEmpty ? nil : build
        }
        return trimmed.isEmpty || trimmed == "dev" ? nil : trimmed
    }

    /// Whether the helper runs a different build than the app. A helper without a build (development) never is.
    nonisolated static func isStale(hostBuild: String, appBuild: String) -> Bool {
        guard let build = build(fromHostBuild: hostBuild) else { return false }
        return build != appBuild.trimmingCharacters(in: .whitespaces)
    }
}
