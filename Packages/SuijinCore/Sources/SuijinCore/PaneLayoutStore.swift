import Foundation
import GRDB

/// A tab's stored pane layout. It belongs to the context its sessions run in (a workspace's folder or main checkout,
/// or a worktree), and goes with it. Panes whose session no longer exists are dropped when the layout is restored.
public struct PaneLayoutRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { layout.id }
    public var workspaceID: UUID
    /// Nil for the workspace's own folder or main checkout.
    public var worktreeID: UUID?
    public var layout: PaneLayout
    public var updatedAt: Date

    public init(workspaceID: UUID, worktreeID: UUID?, layout: PaneLayout, updatedAt: Date = Date()) {
        self.workspaceID = workspaceID
        self.worktreeID = worktreeID
        self.layout = layout
        self.updatedAt = updatedAt
    }
}

extension PaneLayoutRecord: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "pane_layout" }

    fileprivate enum Field: String, ColumnExpression { case id, workspaceID, worktreeID, layout, updatedAt }

    public init(row: Row) throws {
        let json: String = row[Field.layout]
        workspaceID = row[Field.workspaceID]
        worktreeID = row[Field.worktreeID]
        layout = try JSONDecoder().decode(PaneLayout.self, from: Data(json.utf8))
        updatedAt = Date(timeIntervalSinceReferenceDate: row[Field.updatedAt])
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Field.id] = id
        container[Field.workspaceID] = workspaceID
        container[Field.worktreeID] = worktreeID
        container[Field.layout] = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
        // Seconds since 2001-01-01, as the other tables store dates.
        container[Field.updatedAt] = updatedAt.timeIntervalSinceReferenceDate
    }
}

extension SuijinStore {
    /// Every stored layout. A row whose layout cannot be read (written by a newer Suijin, damaged) is left out.
    public func paneLayouts() throws -> [PaneLayoutRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM pane_layout ORDER BY updatedAt")
            return rows.compactMap { try? PaneLayoutRecord(row: $0) }
        }
    }

    public func save(_ record: PaneLayoutRecord) throws {
        try dbQueue.write { db in try record.save(db) }
    }

    public func deletePaneLayout(id: UUID) throws {
        _ = try dbQueue.write { db in try PaneLayoutRecord.deleteOne(db, key: id) }
    }
}
