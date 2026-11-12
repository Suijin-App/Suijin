import Foundation
import GRDB

// GRDB conformances. UUIDs use GRDB's native 16-byte blob form (so key lookups match the stored values) and
// dates are stored as seconds since 2001-01-01, `Date`'s own representation, so values round-trip exactly.

extension Workspace: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "workspace" }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSinceReferenceDate }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSinceReferenceDate }
}

extension WorktreeRecord: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "worktree" }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSinceReferenceDate }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSinceReferenceDate }
}

extension AgentSessionRecord: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agent_session" }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSinceReferenceDate }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSinceReferenceDate }
}

extension ManagedAccountRecord: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "managed_account" }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSinceReferenceDate }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSinceReferenceDate }
}
