import Foundation
import GRDB

/// Numbered schema migrations. A shipped migration is never edited; changes go into a new one.
enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "workspace") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .double).notNull()
            }

            try db.create(table: "worktree") { t in
                t.primaryKey("id", .blob)
                t.column("workspaceID", .blob).notNull().indexed()
                    .references("workspace", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("branch", .text).notNull()
                t.column("baseBranch", .text)
                t.column("createdAt", .double).notNull()
            }

            try db.create(table: "managed_account") { t in
                t.primaryKey("id", .blob)
                t.column("provider", .text).notNull()
                t.column("label", .text).notNull()
                t.column("email", .text)
                t.column("organization", .text)
                t.column("homePath", .text).notNull()
                t.column("createdAt", .double).notNull()
            }

            try db.create(table: "agent_session") { t in
                t.primaryKey("id", .blob)
                t.column("workspaceID", .blob).notNull().indexed()
                    .references("workspace", onDelete: .cascade)
                // A session lives in its worktree; removing the worktree removes the session.
                t.column("worktreeID", .blob).indexed()
                    .references("worktree", onDelete: .cascade)
                // Removing an account keeps the session history; it just loses the account link.
                t.column("accountID", .blob).indexed()
                    .references("managed_account", onDelete: .setNull)
                t.column("agent", .text).notNull()
                t.column("title", .text).notNull()
                t.column("cwd", .text).notNull()
                t.column("hostSessionID", .text)
                t.column("state", .text).notNull()
                t.column("exitCode", .integer)
                t.column("createdAt", .double).notNull()
                t.column("endedAt", .double)
            }

            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            // Sidebar appearance of a workspace: its icon (JSON of `WorkspaceIcon`) and badge color.
            try db.alter(table: "workspace") { t in
                t.add(column: "icon", .text)
                t.add(column: "color", .text)
            }
        }
        // Later migrations live next to their feature; the order here is the order they run in.
        registerDiffNoteMigrations(&migrator)          // v3_diff_note
        registerOrchestrationMigrations(&migrator)     // v4_orchestration
        registerStatsMigrations(&migrator)             // v5_stats
        registerPaneLayoutMigrations(&migrator)        // v6_pane_layout
        registerAgentSessionMigrations(&migrator)      // v7_agent_session_id
        return migrator
    }
}
