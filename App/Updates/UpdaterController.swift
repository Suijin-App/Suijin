import AppKit
import Foundation
import Observation
import Sparkle
import os

/// Software updates through Sparkle 2: a daily check of the appcast, Sparkle's own update dialog with the release
/// notes, an EdDSA signature check of the download, and a relaunch into the new version (docs/release-process.md).
///
/// Wraps `SPUStandardUpdaterController`. The updater stays off until `start()`, which the app calls once its window is
/// up, and only when the build carries a real public EdDSA key: a build with the placeholder key could never verify an
/// update, so it does not check at all.
@MainActor
@Observable
final class UpdaterController {
    enum State: Equatable {
        /// Created but not started.
        case idle
        /// Checking on schedule and on request.
        case running
        /// The build has no public EdDSA key (`SUPublicEDKey` is missing or still the placeholder).
        case notConfigured
        /// Sparkle refused to start; the message says why.
        case failed(String)
    }

    /// The app's updater, shared by the menu command and Settings.
    static let shared = UpdaterController()

    /// The value `App/Info.plist` ships with until the owner pastes the real public key. scripts/release-notarize.sh
    /// refuses to publish a build that still carries it.
    nonisolated static let publicKeyPlaceholder = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"

    private(set) var state: State = .idle
    /// A check may start now (no update session is in progress).
    private(set) var canCheckForUpdates = false
    /// When the appcast was last checked, by schedule or by hand; `nil` before the first check.
    private(set) var lastCheckDate: Date?
    /// Whether Sparkle checks on its own once a day. Sparkle keeps the choice in the app's defaults.
    private(set) var automaticallyChecks: Bool

    @ObservationIgnored private let standardController: SPUStandardUpdaterController
    @ObservationIgnored private let delegate = Delegate()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private static let logger = Logger(subsystem: "com.tekmium.mercury", category: "updates")

    private var updater: SPUUpdater { standardController.updater }

    private init() {
        standardController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        automaticallyChecks = standardController.updater.automaticallyChecksForUpdates
        lastCheckDate = standardController.updater.lastUpdateCheckDate
        delegate.owner = self
    }

    // MARK: - Starting

    /// Starts scheduled checks when the build can verify updates; otherwise records why it cannot. Safe to call twice.
    func start() {
        switch state {
        case .running, .notConfigured: return
        case .idle, .failed: break
        }
        guard Self.hasPublicKey(in: .main) else {
            state = .notConfigured
            Self.logger.notice("updates off: SUPublicEDKey is not set in this build")
            return
        }
        do {
            try updater.start()
            state = .running
            observeUpdater()
        } catch {
            state = .failed(error.localizedDescription)
            Self.logger.error("updater did not start: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// Whether `bundle` carries a public EdDSA key Sparkle can verify updates with.
    nonisolated static func hasPublicKey(in bundle: Bundle) -> Bool {
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return isUsablePublicKey(key)
    }

    /// A Sparkle public key is 32 bytes in base64; the placeholder and anything else are rejected.
    nonisolated static func isUsablePublicKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != publicKeyPlaceholder, let data = Data(base64Encoded: trimmed) else { return false }
        return data.count == 32
    }

    // MARK: - Actions

    /// Opens Sparkle's dialog for a check the user asked for (menu or Settings).
    func checkForUpdates() {
        guard state == .running, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
        refresh()
    }

    /// Turns the daily check on or off; Sparkle reschedules (or cancels) its next check itself.
    func setAutomaticallyChecks(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecks = updater.automaticallyChecksForUpdates
    }

    // MARK: - State from Sparkle

    fileprivate func refresh() {
        canCheckForUpdates = state == .running && updater.canCheckForUpdates
        lastCheckDate = updater.lastUpdateCheckDate
        automaticallyChecks = updater.automaticallyChecksForUpdates
    }

    /// Sparkle changes these on the main thread, at the start and end of every update session.
    private func observeUpdater() {
        let changed: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { _, _ in changed() },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { _, _ in changed() },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { _, _ in changed() },
        ]
    }

    /// Sparkle's delegate. A separate object because Sparkle takes its delegate when the updater is created, before the
    /// controller is fully initialized.
    private final class Delegate: NSObject, SPUUpdaterDelegate {
        weak var owner: UpdaterController?

        func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
            MainActor.assumeIsolated { owner?.refresh() }
        }
    }
}
