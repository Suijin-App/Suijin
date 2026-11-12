import Foundation
import GRDB

/// Mercury's persistent state in SQLite. Methods are synchronous and thread-safe (serialized by the
/// underlying `DatabaseQueue`); callers run them off the main thread.
public final class MercuryStore: Sendable {
    /// Internal so feature stores in this module (diff notes) extend `MercuryStore` from their own files.
    let dbQueue: DatabaseQueue

    /// Opens (or creates) the database file at `url`, creating its parent directory, and migrates it.
    /// Opens (or creates) the database at `url`. Before an existing database gets a new migration, it is copied next
    /// to itself as `<name>.backup-<last applied migration>`, so a failed or unwanted migration can be rolled back.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: url.path)
        let queue = try DatabaseQueue(path: url.path, configuration: Self.configuration())
        if existed, try !queue.read({ try Migrations.migrator.hasCompletedMigrations($0) }) {
            let applied = try queue.read { try Migrations.migrator.appliedMigrations($0) }.last ?? "empty"
            let backupURL = url.appendingPathExtension("backup-\(applied)")
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                let backup = try DatabaseQueue(path: backupURL.path)
                try queue.backup(to: backup)
            }
        }
        try self.init(queue: queue)
    }

    /// A private database that lives as long as the store; for tests and previews.
    public static func inMemory() throws -> MercuryStore {
        try MercuryStore(queue: DatabaseQueue(configuration: configuration()))
    }

    private init(queue: DatabaseQueue) throws {
        dbQueue = queue
        try Migrations.migrator.migrate(queue)
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "MercuryStore"
        return configuration
    }

    // MARK: Workspaces

    public func workspaces() throws -> [Workspace] {
        try dbQueue.read { db in
            try Workspace.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
        }
    }

    public func save(_ workspace: Workspace) throws {
        try dbQueue.write { db in try workspace.save(db) }
    }

    /// Also deletes the workspace's worktrees and sessions.
    public func deleteWorkspace(id: UUID) throws {
        _ = try dbQueue.write { db in try Workspace.deleteOne(db, key: id) }
    }

    // MARK: Worktrees

    public func worktrees(workspaceID: UUID) throws -> [WorktreeRecord] {
        try dbQueue.read { db in
            try WorktreeRecord.filter(Column("workspaceID") == workspaceID).order(Column("createdAt")).fetchAll(db)
        }
    }

    public func save(_ worktree: WorktreeRecord) throws {
        try dbQueue.write { db in try worktree.save(db) }
    }

    /// Also deletes the sessions that ran in the worktree.
    public func deleteWorktree(id: UUID) throws {
        _ = try dbQueue.write { db in try WorktreeRecord.deleteOne(db, key: id) }
    }

    // MARK: Sessions

    public func sessions() throws -> [AgentSessionRecord] {
        try dbQueue.read { db in
            try AgentSessionRecord.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func save(_ session: AgentSessionRecord) throws {
        try dbQueue.write { db in try session.save(db) }
    }

    public func deleteSession(id: UUID) throws {
        _ = try dbQueue.write { db in try AgentSessionRecord.deleteOne(db, key: id) }
    }

    // MARK: Accounts

    public func accounts() throws -> [ManagedAccountRecord] {
        try dbQueue.read { db in
            try ManagedAccountRecord.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func save(_ account: ManagedAccountRecord) throws {
        try dbQueue.write { db in try account.save(db) }
    }

    /// Sessions that used the account keep their history with `accountID` cleared.
    public func deleteAccount(id: UUID) throws {
        _ = try dbQueue.write { db in try ManagedAccountRecord.deleteOne(db, key: id) }
    }

    // MARK: Settings

    public func setting(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
        }
    }

    /// Stores `value` under `key`; `nil` removes the setting.
    public func setSetting(_ key: String, _ value: String?) throws {
        try dbQueue.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key])
            }
        }
    }
}
