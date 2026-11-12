import Foundation
import GRDB
import Testing
@testable import SevindaCore

struct AgentSessionIDTests {
    @Test func agentSessionIDRoundTrips() throws {
        let store = try SevindaStore.inMemory()
        let workspace = Workspace(name: "Repo", path: "/tmp/repo", kind: .git)
        try store.save(workspace)
        var session = AgentSessionRecord(workspaceID: workspace.id, agent: .claude, title: "Claude", cwd: "/tmp/repo")
        try store.save(session)
        #expect(try store.sessions().first?.agentSessionID == nil)
        session.agentSessionID = "0f4c3a52-7d1e-4b8a-9c2d-5e6f7a8b9c0d"
        try store.save(session)
        #expect(try store.sessions() == [session])
    }

    @Test func anExistingDatabaseUpgradesWithTheColumnNullAndABackup() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-v6-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", ".backup-v6_pane_layout"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        // A database as the previous version left it, with a session in it.
        let workspace = UUID(), session = UUID()
        let queue = try DatabaseQueue(path: url.path)
        try Migrations.migrator.migrate(queue, upTo: "v6_pane_layout")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO workspace (id, name, path, kind, createdAt, sortOrder) VALUES (?, 'Repo', '/tmp/repo', 'git', 0, 0)",
                           arguments: [workspace])
            try db.execute(sql: """
                INSERT INTO agent_session (id, workspaceID, agent, title, cwd, state, createdAt)
                VALUES (?, ?, 'claude', 'Claude', '/tmp/repo', 'exited', 0)
                """, arguments: [session, workspace])
        }
        try queue.close()

        let store = try SevindaStore(url: url)
        let upgraded = try #require(try store.sessions().first)
        #expect(upgraded.id == session && upgraded.agentSessionID == nil)
        let backup = url.appendingPathExtension("backup-v6_pane_layout")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try DatabaseQueue(path: backup.path).read { db in
            try !db.columns(in: "agent_session").contains { $0.name == "agentSessionID" }
        })
    }
}
