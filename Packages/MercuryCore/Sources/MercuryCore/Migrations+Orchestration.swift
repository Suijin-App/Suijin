import GRDB

extension Migrations {
    /// Orchestration (`v4_orchestration`) adds no tables to the app's database. Runs, tasks, dispatches and messages
    /// belong to the broker in the PTY host, which keeps delivering while the app is closed; it stores them in
    /// `<dataRoot>/orchestration/state.json` so the database never has two writers. The id stays reserved.
    static func registerOrchestrationMigrations(_ migrator: inout DatabaseMigrator) {}
}
