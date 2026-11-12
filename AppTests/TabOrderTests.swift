import Foundation
import MercuryCore
import Testing
@testable import Mercury

/// Reordering tabs by drag and drop: the model side (the drop calls `moveTab`).
@MainActor
@Suite(.serialized)
struct TabOrderTests {
    @Test func movingASessionTabReordersTabsSidebarAndSurvivesARelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mercury-order-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MercuryStore.inMemory()
        let model = AppModel(store: store, dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        let ids = (0..<3).map { _ in UUID() }
        let workspaceID = try #require(model.workspaces.first).id
        for (index, id) in ids.enumerated() {
            let record = AgentSessionRecord(id: id, workspaceID: workspaceID, worktreeID: nil, agent: .shell, accountID: nil,
                                            title: "s\(index)", cwd: folder.path)
            await model.upsert(record)
        }
        #expect(model.tabSessions(in: context).map(\.id) == ids)

        // The last tab dropped onto the first one takes its place.
        model.moveTab(.session(ids[2]), onto: .session(ids[0]), in: context)
        #expect(model.tabSessions(in: context).map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(model.sidebarSessions(in: context).map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(model.tabList(in: context).first == .session(ids[2]))

        // Kept across launches.
        #expect(AppModel.savedSessionOrder()[context] == [ids[2], ids[0], ids[1]])

        // Across kinds, or onto itself: nothing moves.
        model.moveTab(.session(ids[0]), onto: .changes, in: context)
        model.moveTab(.session(ids[1]), onto: .session(ids[1]), in: context)
        #expect(model.tabSessions(in: context).map(\.id) == [ids[2], ids[0], ids[1]])

        // A new session comes after the ordered ones.
        let late = UUID()
        await model.upsert(AgentSessionRecord(id: late, workspaceID: workspaceID, worktreeID: nil, agent: .shell, accountID: nil,
                                              title: "late", cwd: folder.path))
        #expect(model.tabSessions(in: context).last?.id == late)
    }

    @Test func movingAFileTabReordersOpenFiles() {
        let model = AppModel(store: try! MercuryStore.inMemory(), dataRoot: FileManager.default.temporaryDirectory)
        let context = SessionContext.workspace(UUID())
        model.openFiles[context] = ["/a", "/b", "/c"]
        model.moveTab(.file("/a"), onto: .file("/c"), in: context)
        #expect(model.openFiles[context] == ["/b", "/c", "/a"])
        #expect(DetailTab(dragPayload: DetailTab.file("/x y").dragPayload!) == .file("/x y"))
        #expect(DetailTab.changes.dragPayload == nil)
    }
}
