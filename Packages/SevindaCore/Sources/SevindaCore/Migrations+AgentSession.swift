import GRDB

extension Migrations {
    /// The agent's own conversation id on each session (`v7_agent_session_id`), for resuming an ended session. Existing
    /// sessions get NULL: their id was never recorded.
    static func registerAgentSessionMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7_agent_session_id") { db in
            try db.alter(table: "agent_session") { t in
                t.add(column: "agentSessionID", .text)
            }
        }
    }
}
