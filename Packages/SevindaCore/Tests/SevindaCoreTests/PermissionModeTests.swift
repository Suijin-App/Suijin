import Foundation
import GRDB
import Testing
@testable import SevindaCore

struct PermissionModeTests {
    @Test func eachAgentOffersItsOwnModes() {
        #expect(AgentPermissionMode.modes(for: .claude) == [.ask, .acceptEdits, .plan, .bypass])
        #expect(AgentPermissionMode.modes(for: .codex) == [.ask, .auto, .readOnly, .bypass])
        #expect(AgentPermissionMode.modes(for: .shell).isEmpty)
        #expect(AgentPermissionMode.allCases.filter(\.isDangerous) == [.bypass])
    }

    @Test func aChoiceWinsOverTheSettingAndAnythingTheAgentLacksMeansAsk() {
        // No choice: the stored default.
        #expect(AgentPermissionMode.resolve(choice: nil, setting: nil, for: .claude) == .ask)
        #expect(AgentPermissionMode.resolve(choice: nil, setting: "plan", for: .claude) == .plan)
        #expect(AgentPermissionMode.resolve(choice: nil, setting: "readOnly", for: .codex) == .readOnly)
        // A default of the other agent, an unknown value, a shell.
        #expect(AgentPermissionMode.resolve(choice: nil, setting: "plan", for: .codex) == .ask)
        #expect(AgentPermissionMode.resolve(choice: nil, setting: "yolo", for: .claude) == .ask)
        #expect(AgentPermissionMode.resolve(choice: nil, setting: "bypass", for: .shell) == .ask)
        // A choice overrides the default, including an explicit Ask over a dangerous default.
        #expect(AgentPermissionMode.resolve(choice: .acceptEdits, setting: "bypass", for: .claude) == .acceptEdits)
        #expect(AgentPermissionMode.resolve(choice: .ask, setting: "bypass", for: .codex) == .ask)
        #expect(AgentPermissionMode.resolve(choice: .auto, setting: "bypass", for: .claude) == .ask)
    }

    @Test func onlyAnAgentStartedWithoutChecksSkipsPermissions() {
        let workspace = UUID()
        func record(_ agent: AgentKind, _ mode: AgentPermissionMode?) -> AgentSessionRecord {
            AgentSessionRecord(workspaceID: workspace, agent: agent, title: "t", cwd: "/tmp", permissionMode: mode)
        }
        #expect(record(.claude, .bypass).skipsPermissions)
        #expect(record(.codex, .bypass).skipsPermissions)
        #expect(!record(.claude, nil).skipsPermissions)
        #expect(!record(.claude, .acceptEdits).skipsPermissions)
        #expect(!record(.codex, .auto).skipsPermissions)
        #expect(!record(.shell, .bypass).skipsPermissions)
        #expect(record(.codex, .plan).effectivePermissionMode == .ask)
        #expect(record(.claude, nil).effectivePermissionMode == .ask)
    }

    @Test func permissionModeRoundTrips() throws {
        let store = try SevindaStore.inMemory()
        let workspace = Workspace(name: "Repo", path: "/tmp/repo", kind: .git)
        try store.save(workspace)
        var session = AgentSessionRecord(workspaceID: workspace.id, agent: .codex, title: "Codex", cwd: "/tmp/repo")
        try store.save(session)
        #expect(try store.sessions().first?.permissionMode == nil)
        for mode in AgentPermissionMode.allCases {
            session.permissionMode = mode
            try store.save(session)
            #expect(try store.sessions() == [session])
        }
    }

    @Test func anExistingDatabaseUpgradesWithNullMeaningAsk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-v7-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", ".backup-v7_agent_session_id"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        // A database as the previous version left it, with a session in it.
        let workspace = UUID(), session = UUID()
        let queue = try DatabaseQueue(path: url.path)
        try Migrations.migrator.migrate(queue, upTo: "v7_agent_session_id")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO workspace (id, name, path, kind, createdAt, sortOrder) VALUES (?, 'Repo', '/tmp/repo', 'git', 0, 0)",
                           arguments: [workspace])
            try db.execute(sql: """
                INSERT INTO agent_session (id, workspaceID, agent, title, cwd, state, createdAt, agentSessionID)
                VALUES (?, ?, 'claude', 'Claude', '/tmp/repo', 'exited', 0, '0f4c3a52-7d1e-4b8a-9c2d-5e6f7a8b9c0d')
                """, arguments: [session, workspace])
        }
        try queue.close()

        let store = try SevindaStore(url: url)
        let upgraded = try #require(try store.sessions().first)
        #expect(upgraded.id == session && upgraded.agentSessionID == "0f4c3a52-7d1e-4b8a-9c2d-5e6f7a8b9c0d")
        #expect(upgraded.permissionMode == nil && upgraded.effectivePermissionMode == .ask && !upgraded.skipsPermissions)
        let backup = url.appendingPathExtension("backup-v7_agent_session_id")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try DatabaseQueue(path: backup.path).read { db in
            try !db.columns(in: "agent_session").contains { $0.name == "permissionMode" }
        })
    }
}
