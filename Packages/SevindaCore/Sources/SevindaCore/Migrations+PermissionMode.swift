import GRDB

extension Migrations {
    /// The permission mode each agent session started with (`v8_permission_mode`), an `AgentPermissionMode` raw value.
    /// Existing sessions get NULL, which means `ask`: before this they always started with the CLI's own prompts.
    static func registerPermissionModeMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8_permission_mode") { db in
            try db.alter(table: "agent_session") { t in
                t.add(column: "permissionMode", .text)
            }
        }
    }
}
