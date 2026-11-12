import GRDB

extension Migrations {
    /// Diff line notes (`v3_diff_note`).
    static func registerDiffNoteMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3_diff_note") { db in
            try db.create(table: "diff_note") { t in
                t.primaryKey("id", .blob)
                // Notes go with their workspace or worktree.
                t.column("workspaceID", .blob).notNull().indexed()
                    .references("workspace", onDelete: .cascade)
                t.column("worktreeID", .blob).indexed()
                    .references("worktree", onDelete: .cascade)
                t.column("filePath", .text).notNull()
                t.column("oldPath", .text)
                t.column("startLine", .integer)
                t.column("lineNumber", .integer).notNull()
                t.column("body", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double)
                t.column("sentAt", .double)
                t.column("scope", .text).notNull()
                t.column("diffIdentity", .text)
                t.check(sql: "lineNumber >= 0 AND (startLine IS NULL OR (startLine >= 1 AND startLine <= lineNumber))")
            }
        }
    }
}
