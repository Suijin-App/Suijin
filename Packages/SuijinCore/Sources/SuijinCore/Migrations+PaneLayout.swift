import GRDB

extension Migrations {
    /// Pane layouts of split tabs (`v6_pane_layout`): one row per tab, the tree as JSON (`PaneLayout`).
    static func registerPaneLayoutMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6_pane_layout") { db in
            try db.create(table: "pane_layout") { t in
                t.primaryKey("id", .blob)
                // A layout goes with its workspace or worktree, like the sessions it shows.
                t.column("workspaceID", .blob).notNull().indexed()
                    .references("workspace", onDelete: .cascade)
                t.column("worktreeID", .blob).indexed()
                    .references("worktree", onDelete: .cascade)
                t.column("layout", .text).notNull()
                t.column("updatedAt", .double).notNull()
            }
        }
    }
}
