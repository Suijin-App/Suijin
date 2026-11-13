import Foundation
import GRDB
import Testing
@testable import SuijinCore

@Suite struct StatsStoreTests {
    @Test func freshDatabaseStartsEmptyAndUntracked() throws {
        let store = try SuijinStore.inMemory()
        #expect(try store.suijinStats() == SuijinStats())
    }

    @Test func incrementsAddUpAndStartTrackingOnce() throws {
        let store = try SuijinStore.inMemory()
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        try store.incrementStat(.agentsSpawned, at: first)
        try store.incrementStat(.agentsSpawned, by: 2, at: first.addingTimeInterval(60))
        try store.incrementStat(.agentWorkSeconds, by: 90, at: first.addingTimeInterval(120))
        // Nothing to add, and `trackingSince` is not a counter.
        try store.incrementStat(.agentWorkSeconds, by: 0)
        try store.incrementStat(.agentWorkSeconds, by: -5)
        try store.incrementStat(.trackingSince, by: 10)

        let stats = try store.suijinStats()
        #expect(stats.agentsSpawned == 3)
        #expect(stats.agentWorkSeconds == 90)
        #expect(stats.prsCreated == 0)
        #expect(stats.trackingSince == first)
    }

    @Test func pullRequestsAreCountedOncePerURL() throws {
        let store = try SuijinStore.inMemory()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try store.recordPullRequest(url: "https://github.com/o/r/pull/1", at: date))
        #expect(try !store.recordPullRequest(url: "https://github.com/o/r/pull/1", at: date.addingTimeInterval(5)))
        #expect(try !store.recordPullRequest(url: "  "))
        #expect(try store.recordPullRequest(url: "https://github.com/o/r/pull/2", at: date.addingTimeInterval(10)))

        let stats = try store.suijinStats()
        #expect(stats.prsCreated == 2)
        #expect(stats.trackingSince == date)
    }

    /// A database from before the stats migration is backed up, then backfilled from its stored sessions.
    @Test func migrationBackfillsFromStoredSessions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("suijin.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try Migrations.migrator.migrate(old, upTo: "v3_diff_note")
        let workspace = UUID()
        let oldest = Date(timeIntervalSince1970: 1_690_000_000)
        try old.write { db in
            try db.execute(sql: "INSERT INTO workspace (id, name, path, kind, sortOrder, createdAt) VALUES (?, 'w', '/tmp/w', 'git', 0, 0)",
                           arguments: [workspace])
            let sessions: [(AgentKind, Date)] = [(.claude, oldest.addingTimeInterval(100)), (.codex, oldest.addingTimeInterval(200)),
                                                 (.shell, oldest)]
            for (agent, createdAt) in sessions {
                try db.execute(
                    sql: """
                    INSERT INTO agent_session (id, workspaceID, agent, title, cwd, state, createdAt)
                    VALUES (?, ?, ?, 't', '/tmp/w', 'exited', ?)
                    """,
                    arguments: [UUID(), workspace, agent.rawValue, createdAt.timeIntervalSinceReferenceDate])
            }
        }
        try old.close()

        let store = try SuijinStore(url: url)
        let stats = try store.suijinStats()
        #expect(stats.agentsSpawned == 2)
        #expect(stats.agentWorkSeconds == 0)
        #expect(stats.trackingSince == oldest)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("backup-v3_diff_note").path))

        // Counting continues from the backfilled values; tracking keeps its original start.
        try store.incrementStat(.agentsSpawned)
        #expect(try store.suijinStats().agentsSpawned == 3)
        #expect(try store.suijinStats().trackingSince == oldest)
    }
}
