import Foundation
import Testing
@testable import SuijinCore

@Suite struct SuijinStoreTests {
    private func makeWorkspace(_ name: String = "repo", sortOrder: Int = 0) -> Workspace {
        Workspace(name: name, path: "/tmp/\(name)", kind: .git, sortOrder: sortOrder)
    }

    @Test func workspaceRoundTripAndUpdate() throws {
        let store = try SuijinStore.inMemory()
        var first = makeWorkspace("b", sortOrder: 1)
        let second = Workspace(name: "a", path: "/tmp/a", kind: .folder, sortOrder: 0)
        try store.save(first)
        try store.save(second)
        #expect(try store.workspaces() == [second, first])

        first.name = "renamed"
        try store.save(first)
        #expect(try store.workspaces().last == first)
        #expect(try store.workspaces().count == 2)
    }

    /// Two connections to one file, as when a second copy of Suijin runs on the same data root: a write that has to wait
    /// for the other connection's read waits instead of failing with "database is locked" and being lost.
    @Test func aWriteWaitsForAnotherConnectionsRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("suijin.sqlite")
        let reader = try SuijinStore(url: url)
        let writer = try SuijinStore(url: url)

        // The reader holds its shared lock for half a second once it has read.
        let holding = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? reader.dbQueue.read { db in
                _ = try Workspace.fetchCount(db)
                holding.signal()
                Thread.sleep(forTimeInterval: 0.5)
            }
            finished.signal()
        }
        #expect(holding.wait(timeout: .now() + 5) == .success)

        let workspace = makeWorkspace()
        try writer.save(workspace)
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(try reader.workspaces() == [workspace])
    }

    @Test func worktreeRoundTrip() throws {
        let store = try SuijinStore.inMemory()
        let workspace = makeWorkspace()
        try store.save(workspace)
        let worktree = WorktreeRecord(workspaceID: workspace.id, path: "/tmp/repo-worktrees/feat", branch: "feat", baseBranch: "main")
        let noBase = WorktreeRecord(workspaceID: workspace.id, path: "/tmp/repo-worktrees/x", branch: "x",
                                    createdAt: worktree.createdAt.addingTimeInterval(1))
        try store.save(worktree)
        try store.save(noBase)
        #expect(try store.worktrees(workspaceID: workspace.id) == [worktree, noBase])
        #expect(try store.worktrees(workspaceID: UUID()).isEmpty)

        try store.deleteWorktree(id: worktree.id)
        #expect(try store.worktrees(workspaceID: workspace.id) == [noBase])
    }

    @Test func sessionRoundTripWithAllFields() throws {
        let store = try SuijinStore.inMemory()
        let workspace = makeWorkspace()
        try store.save(workspace)
        let worktree = WorktreeRecord(workspaceID: workspace.id, path: "/tmp/wt", branch: "wt")
        try store.save(worktree)
        let account = ManagedAccountRecord(provider: .claude, label: "Work", homePath: "/tmp/home")
        try store.save(account)

        var session = AgentSessionRecord(
            workspaceID: workspace.id, worktreeID: worktree.id, agent: .claude, accountID: account.id,
            title: "Fix bug", cwd: "/tmp/wt", hostSessionID: "host-1", state: .running)
        try store.save(session)
        #expect(try store.sessions() == [session])

        session.state = .exited
        session.exitCode = -2
        session.endedAt = Date()
        try store.save(session)
        #expect(try store.sessions() == [session])

        try store.deleteSession(id: session.id)
        #expect(try store.sessions().isEmpty)
    }

    @Test func accountRoundTrip() throws {
        let store = try SuijinStore.inMemory()
        let account = ManagedAccountRecord(provider: .codex, label: "Personal", email: "a@example.com",
                                           organization: "Org", homePath: "/tmp/codex")
        try store.save(account)
        #expect(try store.accounts() == [account])
        try store.deleteAccount(id: account.id)
        #expect(try store.accounts().isEmpty)
    }

    @Test func deletingWorkspaceCascades() throws {
        let store = try SuijinStore.inMemory()
        let workspace = makeWorkspace()
        let other = makeWorkspace("other")
        try store.save(workspace)
        try store.save(other)
        let worktree = WorktreeRecord(workspaceID: workspace.id, path: "/tmp/wt", branch: "wt")
        try store.save(worktree)
        try store.save(AgentSessionRecord(workspaceID: workspace.id, worktreeID: worktree.id, agent: .codex, title: "s1", cwd: "/tmp/wt"))
        try store.save(AgentSessionRecord(workspaceID: workspace.id, agent: .shell, title: "s2", cwd: "/tmp/repo"))
        let kept = AgentSessionRecord(workspaceID: other.id, agent: .claude, title: "s3", cwd: "/tmp/other")
        try store.save(kept)

        try store.deleteWorkspace(id: workspace.id)
        #expect(try store.workspaces() == [other])
        #expect(try store.worktrees(workspaceID: workspace.id).isEmpty)
        #expect(try store.sessions() == [kept])
    }

    @Test func deletingWorktreeOrAccountUpdatesSessions() throws {
        let store = try SuijinStore.inMemory()
        let workspace = makeWorkspace()
        try store.save(workspace)
        let worktree = WorktreeRecord(workspaceID: workspace.id, path: "/tmp/wt", branch: "wt")
        try store.save(worktree)
        let account = ManagedAccountRecord(provider: .claude, label: "Work", homePath: "/tmp/home")
        try store.save(account)
        try store.save(AgentSessionRecord(workspaceID: workspace.id, worktreeID: worktree.id, agent: .claude, title: "in wt", cwd: "/tmp/wt"))
        let main = AgentSessionRecord(workspaceID: workspace.id, agent: .claude, accountID: account.id, title: "main", cwd: "/tmp/repo")
        try store.save(main)

        try store.deleteAccount(id: account.id)
        try store.deleteWorktree(id: worktree.id)
        var expected = main
        expected.accountID = nil
        #expect(try store.sessions() == [expected])
    }

    @Test func sessionForUnknownWorkspaceIsRejected() throws {
        let store = try SuijinStore.inMemory()
        #expect(throws: (any Error).self) {
            try store.save(AgentSessionRecord(workspaceID: UUID(), agent: .shell, title: "orphan", cwd: "/"))
        }
    }

    @Test func settings() throws {
        let store = try SuijinStore.inMemory()
        #expect(try store.setting("theme") == nil)
        try store.setSetting("theme", "dark")
        #expect(try store.setting("theme") == "dark")
        try store.setSetting("theme", "light")
        #expect(try store.setting("theme") == "light")
        try store.setSetting("theme", nil)
        #expect(try store.setting("theme") == nil)
        try store.setSetting("missing", nil)
    }

    @Test func fileDatabasePersistsAcrossReopen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("suijin-core-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = SuijinPaths.database(in: root.appendingPathComponent("nested", isDirectory: true))

        let workspace = makeWorkspace()
        let account = ManagedAccountRecord(provider: .claude, label: "Work", homePath: "/tmp/home")
        do {
            let store = try SuijinStore(url: url)
            try store.save(workspace)
            try store.save(account)
            try store.setSetting("k", "v")
        }
        #expect(FileManager.default.fileExists(atPath: url.path))

        let reopened = try SuijinStore(url: url)
        #expect(try reopened.workspaces() == [workspace])
        #expect(try reopened.accounts() == [account])
        #expect(try reopened.setting("k") == "v")
    }
}
