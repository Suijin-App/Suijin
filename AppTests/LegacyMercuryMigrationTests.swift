import Darwin
import Foundation
import SevindaCore
import Synchronization
import Testing
@testable import Sevinda

/// The one-time move of a Mercury install, on a fake `Application Support` folder in a temporary directory, a
/// throwaway defaults suite, and fake process and app control: nothing here reads or signals a real process.
@MainActor
struct LegacyMercuryMigrationTests {
    /// Records signals; pids in `stubborn` survive SIGHUP.
    final class FakeProcesses: LegacySessionProcesses {
        let verified: Set<Int32>
        let stubborn: Set<Int32>
        private let state = Mutex<(signals: [(Int32, Int32)], hungUp: Set<Int32>, killed: Set<Int32>)>(([], [], []))

        init(verified: Set<Int32>, stubborn: Set<Int32> = []) {
            self.verified = verified
            self.stubborn = stubborn
        }

        var signals: [(pid: Int32, signal: Int32)] { state.withLock { $0.signals.map { (pid: $0.0, signal: $0.1) } } }

        func isLegacySession(pid: Int32, startedAt: Date) -> Bool { verified.contains(pid) }

        func isRunning(pid: Int32) -> Bool {
            state.withLock { state in
                if state.killed.contains(pid) { return false }
                return !state.hungUp.contains(pid) || stubborn.contains(pid)
            }
        }

        func signalGroup(_ pid: Int32, _ signal: Int32) {
            state.withLock { state in
                state.signals.append((pid, signal))
                if signal == SIGHUP { state.hungUp.insert(pid) }
                if signal == SIGKILL { state.killed.insert(pid) }
            }
        }
    }

    final class FakeApp: LegacyAppControl {
        let quits: Bool
        private let calls = Mutex(0)
        init(quits: Bool = true) { self.quits = quits }
        var quitCalls: Int { calls.withLock { $0 } }
        func quit(timeout: TimeInterval) -> Bool {
            calls.withLock { $0 += 1 }
            return quits
        }
    }

    /// A temporary `Application Support` and home folder, removed at the end of the test.
    final class Sandbox {
        let base: URL
        var support: URL { base.appendingPathComponent("Application Support", isDirectory: true) }
        var home: URL { base.appendingPathComponent("home", isDirectory: true) }
        var legacyRoot: URL { support.appendingPathComponent("Mercury", isDirectory: true) }
        var root: URL { support.appendingPathComponent("Sevinda", isDirectory: true) }

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-migration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    static let fixedNow = Date(timeIntervalSince1970: 1_794_475_200) // 2026-11-12 08:00:00 UTC

    private func migration(_ sandbox: Sandbox, processes: FakeProcesses = FakeProcesses(verified: []), app: FakeApp = FakeApp()) -> LegacyMercuryMigration {
        var migration = LegacyMercuryMigration(supportDirectory: sandbox.support, home: sandbox.home, processes: processes, legacyApp: app)
        migration.hangUpGrace = 0
        migration.now = { Self.fixedNow }
        return migration
    }

    private func sessionJSON(id: String, pid: Int32, running: Bool, dataRoot: String, ended: Bool = false) -> String {
        """
        {"info":{"id":"\(id)","pid":\(pid),"executable":"/bin/zsh","cwd":"/tmp","startedAt":"2026-11-12T07:00:00Z",\
        "isRunning":\(running),"exitStatus":null,"metadata":{"kind":"shell","mercury.dataRoot":"\(dataRoot)",\
        "mercury.session":"\(UUID().uuidString)"}},"endedAt":\(ended ? "\"2026-11-12T07:30:00Z\"" : "null")}
        """
    }

    /// An old install with a workspace, a running session, a Claude account inside the data root, a theme, a Codex
    /// home with the old marker and rule copies, the old helper's session records and the user-level skill.
    private func makeLegacyInstall(_ sandbox: Sandbox) throws -> (workspace: UUID, session: UUID, account: UUID) {
        let root = sandbox.legacyRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try SevindaStore(url: root.appendingPathComponent("mercury.sqlite"))
        let workspace = Workspace(name: "acme-web", path: "/tmp/Acme/acme-web", kind: .git)
        try store.save(workspace)
        let session = AgentSessionRecord(workspaceID: workspace.id, agent: .shell, title: "zsh", cwd: "/tmp/Acme/acme-web",
                                         hostSessionID: "HOST-1", state: .running)
        try store.save(session)
        let account = ManagedAccountRecord(provider: .claude, label: "Work",
                                           homePath: root.appendingPathComponent("claude-profiles/A/home").path)
        try store.save(account)
        try store.setSetting(SettingKey.terminalTheme.rawValue, "mercury-dark")

        let codexHome = root.appendingPathComponent("codex-homes/B/home", isDirectory: true)
        try sandbox.write("B\n", to: codexHome.appendingPathComponent(".mercury-managed-home"))
        try sandbox.write("prefix_rule()", to: codexHome.appendingPathComponent("rules/_mercury-global-default.rules"))
        try sandbox.write("own()", to: codexHome.appendingPathComponent("rules/default.rules"))
        try sandbox.write("# old", to: root.appendingPathComponent("shell-integration/mercury.bashrc"))

        let sessions = root.appendingPathComponent("pty-host/sessions", isDirectory: true)
        try sandbox.write(sessionJSON(id: "HOST-1", pid: 4101, running: true, dataRoot: root.path), to: sessions.appendingPathComponent("HOST-1.json"))
        try sandbox.write("# guide", to: sandbox.home.appendingPathComponent(".claude/skills/mercury-orchestration/SKILL.md"))
        return (workspace.id, session.id, account.id)
    }

    // MARK: - Tests

    @Test func movesTheFolderAfterABackupAndFinishesInTheNewOne() throws {
        let sandbox = try Sandbox()
        let ids = try makeLegacyInstall(sandbox)
        let processes = FakeProcesses(verified: [4101])
        let migration = migration(sandbox, processes: processes)

        guard case .moved(let backup) = migration.moveDataIfNeeded() else { Issue.record("expected a move"); return }
        #expect(backup.lastPathComponent == "Mercury.backup-\(Self.timestamp(Self.fixedNow))")
        #expect(sandbox.exists(backup.appendingPathComponent("mercury.sqlite")))
        #expect(!sandbox.exists(backup.appendingPathComponent(LegacyMercuryMigration.pendingMarkerName)))
        #expect(!sandbox.exists(sandbox.legacyRoot))
        #expect(migration.isPending)
        #expect(processes.signals.map(\.pid) == [4101])
        let permissions = try FileManager.default.attributesOfItem(atPath: sandbox.root.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)

        migration.renameDatabaseIfPending()
        #expect(sandbox.exists(sandbox.root.appendingPathComponent("sevinda.sqlite")))
        #expect(!sandbox.exists(sandbox.root.appendingPathComponent("mercury.sqlite")))

        let store = try SevindaStore(url: sandbox.root.appendingPathComponent("sevinda.sqlite"))
        let defaults = try Self.throwawayDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName) }
        let report = try #require(migration.finishPending(store: store, defaults: defaults.defaults, legacyDefaults: ["diff.layout": "unified"]))
        #expect(report == LegacyMercuryMigration.Report(endedSessions: 1, claudeAccounts: 1, defaultsCopied: 1))
        #expect(!migration.isPending)

        #expect(try store.workspaces().map(\.id) == [ids.workspace])
        let session = try #require(try store.sessions().first { $0.id == ids.session })
        #expect(session.state == .exited)
        #expect(session.endedAt == Self.fixedNow)
        let account = try #require(try store.accounts().first { $0.id == ids.account })
        #expect(account.homePath == sandbox.root.appendingPathComponent("claude-profiles/A/home").path)
        #expect(try store.setting(SettingKey.terminalTheme.rawValue) == "sevinda-dark")
        #expect(defaults.defaults.string(forKey: "diff.layout") == "unified")

        let codexHome = sandbox.root.appendingPathComponent("codex-homes/B/home", isDirectory: true)
        #expect(sandbox.exists(codexHome.appendingPathComponent(".sevinda-managed-home")))
        #expect(!sandbox.exists(codexHome.appendingPathComponent(".mercury-managed-home")))
        #expect(!sandbox.exists(codexHome.appendingPathComponent("rules/_mercury-global-default.rules")))
        #expect(sandbox.exists(codexHome.appendingPathComponent("rules/default.rules")))
        #expect(!sandbox.exists(sandbox.root.appendingPathComponent("pty-host/sessions")))
        #expect(!sandbox.exists(sandbox.root.appendingPathComponent("shell-integration/mercury.bashrc")))

        let skills = sandbox.home.appendingPathComponent(".claude/skills", isDirectory: true)
        #expect(sandbox.exists(skills.appendingPathComponent("sevinda-orchestration/SKILL.md")))
        #expect(!sandbox.exists(skills.appendingPathComponent("mercury-orchestration")))
    }

    /// The old helper keeps a live socket in `orchestration/`; `FileManager.copyItem` refuses sockets, which blocked
    /// the move on every launch. The backup skips it, and the move (a rename) takes it along.
    @Test func aLiveSocketInTheOldFolderDoesNotBlockTheMove() throws {
        let sandbox = try Sandbox()
        _ = try makeLegacyInstall(sandbox)
        let orchestration = sandbox.legacyRoot.appendingPathComponent("orchestration", isDirectory: true)
        try FileManager.default.createDirectory(at: orchestration, withIntermediateDirectories: true)
        try sandbox.write("{}", to: orchestration.appendingPathComponent("state.json"))
        let socketPath = orchestration.appendingPathComponent("broker.sock").path
        let fd = try Self.listeningSocket(at: socketPath)
        defer { close(fd) }

        guard case .moved(let backup) = migration(sandbox).moveDataIfNeeded() else { Issue.record("expected a move"); return }
        #expect(sandbox.exists(backup.appendingPathComponent("orchestration/state.json")))
        #expect(!sandbox.exists(backup.appendingPathComponent("orchestration/broker.sock")))
        #expect(sandbox.exists(sandbox.root.appendingPathComponent("orchestration/state.json")))
    }

    /// A bound Unix socket at `path`, falling back to a named pipe when the path is too long for `sun_path`; either is
    /// a special file `copyItem` cannot copy.
    private static func listeningSocket(at path: String) throws -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            #expect(mkfifo(path, 0o600) == 0)
            return -1
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(result == 0)
        return fd
    }

    @Test func runningItAgainChangesNothing() throws {
        let sandbox = try Sandbox()
        _ = try makeLegacyInstall(sandbox)
        let migration = migration(sandbox, processes: FakeProcesses(verified: [4101]))
        guard case .moved = migration.moveDataIfNeeded() else { Issue.record("expected a move"); return }
        migration.renameDatabaseIfPending()
        let store = try SevindaStore(url: sandbox.root.appendingPathComponent("sevinda.sqlite"))
        let defaults = try Self.throwawayDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName) }
        #expect(migration.finishPending(store: store, defaults: defaults.defaults, legacyDefaults: nil) != nil)
        let before = try FileManager.default.subpathsOfDirectory(atPath: sandbox.support.path).sorted()

        let processes = FakeProcesses(verified: [4101])
        let app = FakeApp()
        let again = self.migration(sandbox, processes: processes, app: app)
        #expect(again.moveDataIfNeeded() == .nothingToMove)
        again.renameDatabaseIfPending()
        #expect(again.finishPending(store: store, defaults: defaults.defaults, legacyDefaults: ["x": 1]) == nil)
        #expect(defaults.defaults.object(forKey: "x") == nil)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: sandbox.support.path).sorted() == before)
        #expect(processes.signals.isEmpty)
        #expect(app.quitCalls == 0)
    }

    @Test func bothInstallsWithADatabaseAreLeftAlone() throws {
        let sandbox = try Sandbox()
        _ = try makeLegacyInstall(sandbox)
        _ = try SevindaStore(url: sandbox.root.appendingPathComponent("sevinda.sqlite"))
        let before = try FileManager.default.subpathsOfDirectory(atPath: sandbox.support.path).sorted()
        let processes = FakeProcesses(verified: [4101])
        let app = FakeApp()

        #expect(migration(sandbox, processes: processes, app: app).moveDataIfNeeded() == .bothExist)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: sandbox.support.path).sorted() == before)
        #expect(processes.signals.isEmpty)
        #expect(app.quitCalls == 0)
    }

    @Test func aSevindaFolderWithoutDatabaseIsKeptAside() throws {
        let sandbox = try Sandbox()
        _ = try makeLegacyInstall(sandbox)
        try sandbox.write("{}", to: sandbox.root.appendingPathComponent("hooks/claude-settings.json"))

        guard case .moved = migration(sandbox).moveDataIfNeeded() else { Issue.record("expected a move"); return }
        let aside = sandbox.support.appendingPathComponent("Sevinda.before-migration-\(Self.timestamp(Self.fixedNow))")
        #expect(sandbox.exists(aside.appendingPathComponent("hooks/claude-settings.json")))
        #expect(sandbox.exists(sandbox.root.appendingPathComponent("mercury.sqlite")))
    }

    @Test func anExistingBackupIsNeverOverwritten() throws {
        let sandbox = try Sandbox()
        _ = try makeLegacyInstall(sandbox)
        let taken = sandbox.support.appendingPathComponent("Mercury.backup-\(Self.timestamp(Self.fixedNow))")
        try sandbox.write("keep", to: taken.appendingPathComponent("note.txt"))

        guard case .moved(let backup) = migration(sandbox).moveDataIfNeeded() else { Issue.record("expected a move"); return }
        #expect(backup.lastPathComponent == "\(taken.lastPathComponent)-2")
        #expect(try String(contentsOf: taken.appendingPathComponent("note.txt"), encoding: .utf8) == "keep")
        #expect(!sandbox.exists(taken.appendingPathComponent("mercury.sqlite")))
    }

    @Test func nothingMovesWhileTheOldAppKeepsRunning() throws {
        let sandbox = try Sandbox()
        _ = try makeLegacyInstall(sandbox)
        let processes = FakeProcesses(verified: [4101])
        let before = try FileManager.default.subpathsOfDirectory(atPath: sandbox.support.path).sorted()

        guard case .blocked = migration(sandbox, processes: processes, app: FakeApp(quits: false)).moveDataIfNeeded() else {
            Issue.record("expected the move to be blocked"); return
        }
        #expect(try FileManager.default.subpathsOfDirectory(atPath: sandbox.support.path).sorted() == before)
        #expect(processes.signals.isEmpty)
    }

    @Test func onlyVerifiedSessionsOfTheOldDataRootAreEnded() throws {
        let sandbox = try Sandbox()
        let root = sandbox.legacyRoot
        let sessions = root.appendingPathComponent("pty-host/sessions", isDirectory: true)
        try sandbox.write(sessionJSON(id: "A", pid: 501, running: true, dataRoot: root.path), to: sessions.appendingPathComponent("A.json"))
        try sandbox.write(sessionJSON(id: "B", pid: 502, running: true, dataRoot: root.path), to: sessions.appendingPathComponent("B.json"))
        // Another data root sharing the old helper (a test build): not ours.
        try sandbox.write(sessionJSON(id: "C", pid: 503, running: true, dataRoot: "/tmp/other-root"), to: sessions.appendingPathComponent("C.json"))
        // Already ended, and a pid the system gave to another process since.
        try sandbox.write(sessionJSON(id: "D", pid: 504, running: false, dataRoot: root.path, ended: true), to: sessions.appendingPathComponent("D.json"))
        try sandbox.write(sessionJSON(id: "E", pid: 505, running: true, dataRoot: root.path), to: sessions.appendingPathComponent("E.json"))
        try sandbox.write("not json", to: sessions.appendingPathComponent("F.json"))

        let processes = FakeProcesses(verified: [501, 502, 503, 504], stubborn: [502])
        #expect(migration(sandbox, processes: processes).endLegacySessions() == 2)
        let signals = processes.signals
        #expect(Set(signals.filter { $0.signal == SIGHUP }.map(\.pid)) == [501, 502])
        #expect(signals.filter { $0.signal == SIGKILL }.map(\.pid) == [502])
        #expect(!signals.contains { [503, 504, 505].contains($0.pid) })
    }

    @Test func leftoverHelperRecordsAreCleanedOnlyWhenAlone() throws {
        let sandbox = try Sandbox()
        // The old helper wrote its exit records after the move; Sevinda already has its database.
        _ = try SevindaStore(url: sandbox.root.appendingPathComponent("sevinda.sqlite"))
        try sandbox.write("{}", to: sandbox.legacyRoot.appendingPathComponent("pty-host/sessions/A.json"))
        #expect(migration(sandbox).moveDataIfNeeded() == .nothingToMove)
        #expect(!sandbox.exists(sandbox.legacyRoot))

        try sandbox.write("{}", to: sandbox.legacyRoot.appendingPathComponent("pty-host/sessions/A.json"))
        try sandbox.write("mine", to: sandbox.legacyRoot.appendingPathComponent("notes.txt"))
        #expect(migration(sandbox).moveDataIfNeeded() == .nothingToMove)
        #expect(sandbox.exists(sandbox.legacyRoot.appendingPathComponent("notes.txt")))
    }

    /// The real check: a live process whose parent is not the old helper (here, a child of the test) is never taken
    /// for one of its sessions, so its pid is never signaled.
    @Test func systemCheckRejectsProcessesTheOldHelperDidNotStart() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        let system = SystemLegacySessionProcesses()
        #expect(system.isRunning(pid: child.processIdentifier))
        #expect(!system.isLegacySession(pid: child.processIdentifier, startedAt: Date()))
        #expect(!system.isLegacySession(pid: 0, startedAt: Date()))
    }

    @Test func oldDefaultsAreCopiedAndWin() throws {
        let sandbox = try Sandbox()
        let defaults = try Self.throwawayDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.suiteName) }
        // Left by a test run or a launch that could not move the data yet; the user's old choice wins.
        defaults.defaults.set("split", forKey: "diff.layout")
        defaults.defaults.set("kept", forKey: "only.new")
        let copied = migration(sandbox).copyDefaults(
            from: ["diff.layout": "unified", "inspector.shown": true, "tabs.sessionOrder": ["workspace:1": ["a", "b"]]],
            to: defaults.defaults
        )
        #expect(copied == 3)
        #expect(defaults.defaults.string(forKey: "diff.layout") == "unified")
        #expect(defaults.defaults.string(forKey: "only.new") == "kept")
        #expect(defaults.defaults.bool(forKey: "inspector.shown"))
        #expect(defaults.defaults.dictionary(forKey: "tabs.sessionOrder")?["workspace:1"] as? [String] == ["a", "b"])
    }

    @Test func overriddenDataRootNeverMigrates() {
        #expect(LegacyMercuryMigration.live(environment: ["SEVINDA_DATA_ROOT": "/tmp/x"]) == nil)
        #expect(LegacyMercuryMigration.live(environment: [:]) != nil)
    }

    @Test func noticeAsksClaudeAccountsToSignInAgainOnlyWhenThereAreSome() {
        let none = LegacyMercuryMigration.notice(for: .init(endedSessions: 2, claudeAccounts: 0, defaultsCopied: 3))
        let some = LegacyMercuryMigration.notice(for: .init(endedSessions: 0, claudeAccounts: 1, defaultsCopied: 0))
        #expect(none.title == "Mercury is now Sevinda")
        #expect(!none.message.contains("Claude"))
        #expect(some.message.contains("Claude"))
    }

    // MARK: - Helpers

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private struct ThrowawayDefaults {
        let suiteName: String
        let defaults: UserDefaults
        func removePersistentDomain(forName name: String) { defaults.removePersistentDomain(forName: name) }
    }

    private static func throwawayDefaults() throws -> ThrowawayDefaults {
        let name = "sevinda-migration-tests-\(UUID().uuidString)"
        return ThrowawayDefaults(suiteName: name, defaults: try #require(UserDefaults(suiteName: name)))
    }
}
