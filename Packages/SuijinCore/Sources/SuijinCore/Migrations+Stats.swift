import Foundation
import GRDB

extension Migrations {
    /// Suijin's own usage counters (`v5_stats`): named integer counters and the pull requests Suijin created.
    static func registerStatsMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5_stats") { db in
            try db.create(table: "stat_counter") { t in
                t.primaryKey("key", .text)
                t.column("value", .integer).notNull()
            }
            try db.create(table: "stat_pr") { t in
                t.primaryKey("url", .text)
                t.column("createdAt", .datetime).notNull()
            }
            // Backfill from the sessions still stored: every agent session counts as spawned, and tracking starts at
            // the oldest one. Session dates are seconds since 2001-01-01; `trackingSince` is stored in Unix seconds.
            let agents = try Int64.fetchOne(
                db, sql: "SELECT COUNT(*) FROM agent_session WHERE agent != ?", arguments: [AgentKind.shell.rawValue]) ?? 0
            try db.execute(sql: "INSERT INTO stat_counter (key, value) VALUES (?, ?)",
                           arguments: [StatKey.agentsSpawned.rawValue, agents])
            if let earliest = try Double.fetchOne(db, sql: "SELECT MIN(createdAt) FROM agent_session") {
                let unix = Int64((earliest + Date.timeIntervalBetween1970AndReferenceDate).rounded(.down))
                try db.execute(sql: "INSERT INTO stat_counter (key, value) VALUES (?, ?)",
                               arguments: [StatKey.trackingSince.rawValue, unix])
            }
        }
    }
}
