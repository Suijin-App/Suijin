import Foundation
import GRDB
import Testing
@testable import SevindaCore

@Suite struct WorkspaceAppearanceTests {
    @Test(arguments: [WorkspaceIcon.symbol("server.rack"), .emoji("🚀"), .image("A1B2.png")])
    func iconAndColorRoundTrip(_ icon: WorkspaceIcon) throws {
        let store = try MercuryStore.inMemory()
        let workspace = Workspace(name: "api", path: "/tmp/api", kind: .git, icon: icon, color: "teal")
        try store.save(workspace)
        #expect(try store.workspaces() == [workspace])
    }

    /// A database made by the first release (migration v1 only) is backed up, then migrated, and keeps its rows.
    @Test func upgradingAnExistingDatabaseBacksItUpFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mercury-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("mercury.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try Migrations.migrator.migrate(old, upTo: "v1")
        let id = UUID()
        try old.write { db in
            try db.execute(sql: "INSERT INTO workspace (id, name, path, kind, sortOrder, createdAt) VALUES (?, 'old', '/tmp/old', 'folder', 0, 0)",
                           arguments: [id])
        }
        try old.close()

        let store = try MercuryStore(url: url)
        #expect(try store.workspaces().map(\.name) == ["old"])
        #expect(try store.workspaces().first?.icon == nil)
        let backup = url.appendingPathExtension("backup-v1")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let backupColumns = try DatabaseQueue(path: backup.path).read { try $0.columns(in: "workspace").map(\.name) }
        #expect(!backupColumns.contains("icon"))

        // Opening an up-to-date database makes no further backup.
        try FileManager.default.removeItem(at: backup)
        _ = try MercuryStore(url: url)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }
}
