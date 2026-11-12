import AppKit
import Darwin
import Foundation
import SevindaCore
import os

/// One-time move of an install made before the app was renamed (it was called Mercury) to Sevinda's locations.
///
/// It runs at launch, only on the default data root (never with `SEVINDA_DATA_ROOT`), in two halves:
/// 1. `moveDataIfNeeded()` before the database opens: asks the old app to quit, ends the sessions the old PTY host
///    still runs for that data root, copies `Application Support/Mercury` to `Mercury.backup-<timestamp>`, then moves
///    it to `Application Support/Sevinda`. A marker file travels with the move, so an interrupted run finishes next
///    launch. `renameDatabaseIfPending()` then gives the database files their new name.
/// 2. `finishPending(store:defaults:legacyDefaults:)` once the store is open: drops files the old helper and app
///    generated, carries over defaults, Codex home markers, the user-level Claude skill, account paths and the
///    terminal theme, and marks sessions of the old helper as ended (they show "Session Ended" with Start Again).
///
/// Nothing is deleted from the backup or from the old defaults domain, so the old install can be restored by hand.
/// Every name of the old install lives in this file (and its tests) on purpose.
struct LegacyMercuryMigration {
    // Names of the old install.
    static let legacyFolderName = "Mercury"
    static let legacyDatabaseName = "mercury.sqlite"
    static let legacyDefaultsDomain = "com.tekmium.mercury"
    static let legacyAppBundleIdentifier = "com.tekmium.mercury"
    static let legacyHelperExecutable = "MercuryPTYHost"
    static let legacyDataRootMetadataKey = "mercury.dataRoot"
    static let legacyCodexMarker = ".mercury-managed-home"
    static let legacyCodexRulePrefix = "_mercury-global-"
    static let legacySkillName = "mercury-orchestration"
    static let legacyThemes = ["mercury-light": "sevinda-light", "mercury-dark": "sevinda-dark"]
    /// Files the old app and helper generated inside the data root; the new ones are written under new names.
    static let legacyGeneratedItems = [
        "pty-host/sessions", "shell-integration/mercury.bashrc", "orchestration/claude-plugin/skills/mercury-orchestration",
    ]

    // Names of the new install.
    static let folderName = "Sevinda"
    static let databaseName = "sevinda.sqlite"
    static let codexMarker = ".sevinda-managed-home"
    static let skillName = "sevinda-orchestration"
    /// Written into the old folder just before the move; its content is the old folder's path.
    static let pendingMarkerName = ".sevinda-migration-pending"

    /// What `moveDataIfNeeded()` did.
    enum MoveOutcome: Equatable {
        /// No old install, or nothing left to move.
        case nothingToMove
        /// Both installs have a database: nothing is touched, the old folder stays where it is.
        case bothExist
        /// The old folder is now the Sevinda folder; `finishPending` completes the move.
        case moved(backup: URL)
        /// Nothing was moved, and the app must not create a Sevinda database this launch (so the next launch tries
        /// again). The message is localized and says what to do.
        case blocked(String)
    }

    /// What `finishPending` changed, for the one-time notice.
    struct Report: Equatable {
        var endedSessions = 0
        var claudeAccounts = 0
        var defaultsCopied = 0
    }

    let supportDirectory: URL
    let home: URL
    let processes: any LegacySessionProcesses
    let legacyApp: any LegacyAppControl
    /// Seconds between SIGHUP and SIGKILL for a session of the old helper.
    var hangUpGrace: TimeInterval = 2
    var now: () -> Date = Date.init

    private static let logger = Logger(subsystem: "com.tekmium.sevinda", category: "rename-migration")

    var legacyRoot: URL { supportDirectory.appendingPathComponent(Self.legacyFolderName, isDirectory: true) }
    var root: URL { supportDirectory.appendingPathComponent(Self.folderName, isDirectory: true) }

    /// The migration for the real install, or nil when the data root is overridden (tests, scratch runs).
    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> LegacyMercuryMigration? {
        if let override = environment["SEVINDA_DATA_ROOT"], !override.isEmpty { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LegacyMercuryMigration(
            supportDirectory: support, home: FileManager.default.homeDirectoryForCurrentUser,
            processes: SystemLegacySessionProcesses(), legacyApp: SystemLegacyAppControl()
        )
    }

    // MARK: - Moving the folder

    func moveDataIfNeeded() -> MoveOutcome {
        let files = FileManager.default
        guard files.fileExists(atPath: legacyRoot.path) else { return .nothingToMove }
        guard files.fileExists(atPath: legacyRoot.appendingPathComponent(Self.legacyDatabaseName).path) else {
            // A folder without a database holds nothing worth moving. When it holds only the old helper's session
            // records (it writes them as its sessions end, possibly after the move), it is removed.
            removeLeftoverHelperRecords()
            return .nothingToMove
        }
        if files.fileExists(atPath: root.appendingPathComponent(Self.databaseName).path) {
            Self.logger.warning("both data folders have a database; leaving \(Self.legacyFolderName, privacy: .public) untouched")
            return .bothExist
        }
        guard legacyApp.quit(timeout: 10) else {
            return .blocked(String(localized: "Mercury is still open. Quit Mercury, then open Sevinda again to bring over your workspaces and settings."))
        }
        if endLegacySessions() > 0 {
            // Let the old helper record the exits before the folder is copied and moved.
            usleep(useconds_t(min(hangUpGrace, 1) * 1_000_000))
        }
        do {
            let backup = try makeBackup()
            let marker = legacyRoot.appendingPathComponent(Self.pendingMarkerName)
            try Data(legacyRoot.path.utf8).write(to: marker, options: .atomic)
            if files.fileExists(atPath: root.path) {
                // A Sevinda folder without a database only holds files a launch regenerates; keep it aside anyway.
                let aside = uniqueSibling(of: root, suffix: "before-migration-\(timestamp())")
                try files.moveItem(at: root, to: aside)
            }
            do {
                try files.moveItem(at: legacyRoot, to: root)
            } catch {
                try? files.removeItem(at: marker)
                throw error
            }
            Self.logger.notice("moved the Mercury data folder to Sevinda (backup \(backup.lastPathComponent, privacy: .public))")
            return .moved(backup: backup)
        } catch {
            Self.logger.error("data folder move failed: \(error.localizedDescription, privacy: .public)")
            return .blocked(String(localized: "Sevinda could not bring over your Mercury data: \(error.localizedDescription) Nothing was changed; open Sevinda again to retry."))
        }
    }

    /// Copies the old folder next to itself; an existing backup is never overwritten.
    private func makeBackup() throws -> URL {
        let backup = uniqueSibling(of: legacyRoot, suffix: "backup-\(timestamp())")
        do {
            try FileManager.default.copyItem(at: legacyRoot, to: backup)
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw error
        }
        return backup
    }

    private func removeLeftoverHelperRecords() {
        let contents = ((try? FileManager.default.contentsOfDirectory(atPath: legacyRoot.path)) ?? []).filter { $0 != ".DS_Store" }
        guard contents == ["pty-host"] else { return }
        try? FileManager.default.removeItem(at: legacyRoot)
    }

    private func uniqueSibling(of url: URL, suffix: String) -> URL {
        let parent = url.deletingLastPathComponent()
        var candidate = parent.appendingPathComponent("\(url.lastPathComponent).\(suffix)", isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(url.lastPathComponent).\(suffix)-\(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: now())
    }

    // MARK: - Sessions of the old helper

    /// A session the old helper recorded in `<data root>/pty-host/sessions/<id>.json`.
    struct LegacySession: Decodable, Equatable {
        struct Info: Decodable, Equatable {
            var id: String
            var pid: Int32
            var startedAt: Date
            var isRunning: Bool
            var metadata: [String: String]
        }
        var info: Info
        var endedAt: Date?
    }

    /// Running sessions the old helper started for the old data root. Sessions of other data roots (a second build,
    /// the tests) share that helper and are left alone.
    func runningLegacySessions() -> [LegacySession] {
        let directory = legacyRoot.appendingPathComponent("pty-host/sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let session = try? decoder.decode(LegacySession.self, from: data) else { return nil }
            guard session.info.isRunning, session.endedAt == nil,
                  session.info.metadata[Self.legacyDataRootMetadataKey] == legacyRoot.path else { return nil }
            return session
        }
    }

    /// SIGHUP to each session's process group, then SIGKILL to whatever is left after the grace period, as the helper
    /// itself ends a session. A pid that is no longer the old helper's child (reused by another process) is skipped.
    @discardableResult
    func endLegacySessions() -> Int {
        let sessions = runningLegacySessions().filter { processes.isLegacySession(pid: $0.info.pid, startedAt: $0.info.startedAt) }
        guard !sessions.isEmpty else { return 0 }
        for session in sessions { processes.signalGroup(session.info.pid, SIGHUP) }
        let deadline = Date().addingTimeInterval(hangUpGrace)
        while Date() < deadline, sessions.contains(where: { processes.isRunning(pid: $0.info.pid) }) {
            usleep(50_000)
        }
        for session in sessions where processes.isRunning(pid: session.info.pid) {
            processes.signalGroup(session.info.pid, SIGKILL)
        }
        Self.logger.notice("ended \(sessions.count) session(s) of the old PTY host")
        return sessions.count
    }

    // MARK: - Finishing in the new folder

    /// Whether the folder was moved but not finished yet.
    var isPending: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.pendingMarkerName).path) }

    /// Renames the database files. Runs before the store opens.
    func renameDatabaseIfPending() {
        guard isPending else { return }
        let files = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let old = root.appendingPathComponent(Self.legacyDatabaseName + suffix)
            let new = root.appendingPathComponent(Self.databaseName + suffix)
            guard files.fileExists(atPath: old.path), !files.fileExists(atPath: new.path) else { continue }
            do {
                try files.moveItem(at: old, to: new)
            } catch {
                Self.logger.error("cannot rename \(old.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Completes a pending move once the store is open; nil when nothing was pending.
    func finishPending(store: SevindaStore, defaults: UserDefaults, legacyDefaults: [String: Any]?) -> Report? {
        guard isPending else { return nil }
        let marker = root.appendingPathComponent(Self.pendingMarkerName)
        let movedFrom = (try? String(contentsOf: marker, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var report = Report()
        removeGeneratedItems()
        migrateCodexHomes()
        migrateUserSkill()
        report.defaultsCopied = copyDefaults(from: legacyDefaults, to: defaults)
        do {
            report.endedSessions = try endSessionRecords(in: store)
            report.claudeAccounts = try fixAccountPaths(in: store, movedFrom: movedFrom ?? legacyRoot.path)
            try mapTheme(in: store)
        } catch {
            // The marker stays, so the next launch tries the database part again.
            Self.logger.error("database part of the move failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        try? FileManager.default.removeItem(at: marker)
        Self.logger.notice("finished moving the Mercury install")
        return report
    }

    private func removeGeneratedItems() {
        for item in Self.legacyGeneratedItems {
            let url = root.appendingPathComponent(item)
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Codex account homes are recognized by their marker file, and global rules are copied in with a name prefix:
    /// rename the marker, and drop the old copies (the next launch of the account writes them under the new prefix).
    private func migrateCodexHomes() {
        let files = FileManager.default
        let accounts = root.appendingPathComponent("codex-homes", isDirectory: true)
        guard let entries = try? files.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let home = entry.appendingPathComponent("home", isDirectory: true)
            let oldMarker = home.appendingPathComponent(Self.legacyCodexMarker)
            let newMarker = home.appendingPathComponent(Self.codexMarker)
            if files.fileExists(atPath: oldMarker.path), !files.fileExists(atPath: newMarker.path) {
                try? files.moveItem(at: oldMarker, to: newMarker)
            }
            let rules = home.appendingPathComponent("rules", isDirectory: true)
            for rule in (try? files.contentsOfDirectory(atPath: rules.path)) ?? [] where rule.hasPrefix(Self.legacyCodexRulePrefix) {
                try? files.removeItem(at: rules.appendingPathComponent(rule))
            }
        }
    }

    /// The user turned on the skill in `~/.claude/skills` under its old name: install it under the new name and remove
    /// the old one. When it is off, `~/.claude` is not touched.
    private func migrateUserSkill() {
        let skills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        let old = skills.appendingPathComponent(Self.legacySkillName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: old.appendingPathComponent("SKILL.md").path) else { return }
        do {
            try OrchestrationLaunch.setUserClaudeSkill(installed: true, home: home)
            try FileManager.default.removeItem(at: old)
        } catch {
            Self.logger.error("cannot move the user-level orchestration skill: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies the old app's defaults (window frames, tab order, file tree state…). The old values win: before the move
    /// there was no Sevinda database, so anything already in the new domain was not chosen by the user (test runs, the
    /// window of a launch that could not move the data yet).
    func copyDefaults(from legacy: [String: Any]?, to defaults: UserDefaults) -> Int {
        guard let legacy else { return 0 }
        for (key, value) in legacy { defaults.set(value, forKey: key) }
        return legacy.count
    }

    /// The new helper never ran the old helper's sessions, so their records end here.
    private func endSessionRecords(in store: SevindaStore) throws -> Int {
        var ended = 0
        for var session in try store.sessions() where session.state != .exited && session.state != .failed {
            session.state = .exited
            session.endedAt = session.endedAt ?? now()
            try store.save(session)
            ended += 1
        }
        return ended
    }

    /// Account homes live in the data root; their stored paths follow the move. Returns the number of Claude accounts,
    /// whose Keychain login is keyed by the old path and has to be signed in again.
    private func fixAccountPaths(in store: SevindaStore, movedFrom: String) throws -> Int {
        let oldPrefix = movedFrom.hasSuffix("/") ? movedFrom : movedFrom + "/"
        let newPrefix = root.path + "/"
        var claude = 0
        for var account in try store.accounts() {
            if account.homePath.hasPrefix(oldPrefix) {
                account.homePath = newPrefix + account.homePath.dropFirst(oldPrefix.count)
                try store.save(account)
            }
            if account.provider == .claude { claude += 1 }
        }
        return claude
    }

    private func mapTheme(in store: SevindaStore) throws {
        let key = SettingKey.terminalTheme.rawValue
        if let theme = try store.setting(key), let mapped = Self.legacyThemes[theme] {
            try store.setSetting(key, mapped)
        }
    }

    // MARK: - Alerts

    /// The alert when nothing could be moved this launch; `message` comes from `.blocked`.
    static func blockedAlert(_ message: String) -> PresentedError {
        PresentedError(title: String(localized: "Your Mercury data was not moved yet"), message: message)
    }

    /// The one-time alert after a move.
    static func notice(for report: Report) -> PresentedError {
        var lines = [String(localized: "Your workspaces and settings came along. Sessions that were running in Mercury have ended; open one and choose Start Again.")]
        if report.claudeAccounts > 0 {
            lines.append(String(localized: "Sign in again to your managed Claude accounts in Settings → Accounts."))
        }
        lines.append(String(localized: "You can remove Mercury from System Settings → General → Login Items and delete the Mercury app."))
        return PresentedError(title: String(localized: "Mercury is now Sevinda"), message: lines.joined(separator: "\n\n"))
    }
}

// MARK: - Side effects

/// The processes of the old helper's sessions. Tests replace it.
protocol LegacySessionProcesses: Sendable {
    /// Whether `pid` is still the session the old helper started around `startedAt`: alive, a child of the old helper
    /// executable, started at that time. A pid the system has since reused for another process is not.
    func isLegacySession(pid: Int32, startedAt: Date) -> Bool
    func isRunning(pid: Int32) -> Bool
    func signalGroup(_ pid: Int32, _ signal: Int32)
}

/// The old app, which must not have the data folder open while it moves. Tests replace it.
protocol LegacyAppControl: Sendable {
    /// Asks a running old app to quit and waits up to `timeout` seconds; true when it is not running (any more).
    func quit(timeout: TimeInterval) -> Bool
}

struct SystemLegacySessionProcesses: LegacySessionProcesses {
    func isLegacySession(pid: Int32, startedAt: Date) -> Bool {
        guard pid > 0, let info = Self.bsdInfo(pid), info.pbi_status != UInt32(SZOMB) else { return false }
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
        guard abs(started.timeIntervalSince(startedAt)) < 5 else { return false }
        return Self.executableName(Int32(info.pbi_ppid)) == LegacyMercuryMigration.legacyHelperExecutable
    }

    func isRunning(pid: Int32) -> Bool {
        guard let info = Self.bsdInfo(pid) else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

    func signalGroup(_ pid: Int32, _ signal: Int32) {
        // Sessions are process group leaders (setsid in the helper); fall back to the process alone.
        if killpg(pid, signal) != 0 { kill(pid, signal) }
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func executableName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return (path as NSString).lastPathComponent
    }
}

struct SystemLegacyAppControl: LegacyAppControl {
    func quit(timeout: TimeInterval) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: LegacyMercuryMigration.legacyAppBundleIdentifier)
        guard !running.isEmpty else { return true }
        for app in running { app.terminate() }
        let pids = running.map(\.processIdentifier)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ kill($0, 0) != 0 && errno == ESRCH }) { return true }
            usleep(100_000)
        }
        return false
    }
}
