import Foundation
import SuijinCore
import Testing
@testable import Suijin

/// Reordering tabs by drag and drop: the model side (the drop calls `moveTab`).
@MainActor
@Suite(.serialized)
struct TabOrderTests {
    @Test func movingASessionTabReordersTabsSidebarAndSurvivesARelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-order-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SuijinStore.inMemory()
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

        // Onto itself: nothing moves.
        model.moveTab(.session(ids[1]), onto: .session(ids[1]), in: context)
        #expect(model.tabSessions(in: context).map(\.id) == [ids[2], ids[0], ids[1]])

        // A new session comes after the ordered ones.
        let late = UUID()
        await model.upsert(AgentSessionRecord(id: late, workspaceID: workspaceID, worktreeID: nil, agent: .shell, accountID: nil,
                                              title: "late", cwd: folder.path))
        #expect(model.tabSessions(in: context).last?.id == late)
    }

    @Test func movingAFileTabReordersOpenFiles() {
        let model = AppModel(store: try! SuijinStore.inMemory(), dataRoot: FileManager.default.temporaryDirectory)
        let context = SessionContext.workspace(UUID())
        model.openFiles[context] = ["/a", "/b", "/c"]
        model.moveTab(.file("/a"), onto: .file("/c"), in: context)
        #expect(model.openFiles[context] == ["/b", "/c", "/a"])
        #expect(DetailTab(dragPayload: DetailTab.file("/x y").dragPayload) == .file("/x y"))
        #expect(DetailTab(dragPayload: DetailTab.changes.dragPayload) == .changes)
    }

    /// Every tab moves anywhere: Changes before the sessions, a file between them; new tabs open beside their kind,
    /// and the order is kept across launches.
    @Test func anyTabMovesAnywhere() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-order-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", folder.path]
        try git.run()
        git.waitUntilExit()
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspace = try #require(model.workspaces.first)
        #expect(workspace.kind == .git)
        let context = SessionContext.workspace(workspace.id)
        let a = UUID(), b = UUID()
        for id in [a, b] {
            await model.upsert(AgentSessionRecord(id: id, workspaceID: workspace.id, worktreeID: nil, agent: .shell,
                                                  accountID: nil, title: "s", cwd: folder.path))
        }
        model.openFiles[context] = ["/f"]
        #expect(model.tabList(in: context) == [.session(a), .session(b), .changes, .file("/f")])

        model.moveTab(.changes, onto: .session(a), in: context)
        #expect(model.tabList(in: context) == [.changes, .session(a), .session(b), .file("/f")])
        model.moveTab(.file("/f"), onto: .session(b), in: context)
        #expect(model.tabList(in: context) == [.changes, .session(a), .file("/f"), .session(b)])
        #expect(AppModel.savedTabOrder()[context] == ["changes", "session:\(a)", "file:/f", "session:\(b)"])

        // ⌘1…⌘8 select by the position shown, ⌘9 the last tab, and a number past the last tab changes nothing.
        model.selectTab(number: 1, in: context)
        #expect(model.selectedTab[context] == .changes)
        model.selectTab(number: 3, in: context)
        #expect(model.selectedTab[context] == .file("/f"))
        model.selectTab(number: 5, in: context)
        #expect(model.selectedTab[context] == .file("/f"))
        model.selectTab(number: 9, in: context)
        #expect(model.selectedTab[context] == .session(b))
        // Typed in a terminal, the key arrives as a route.
        #expect(model.handle(.selectTab(2), in: context, from: b))
        #expect(model.selectedTab[context] == .session(a))

        // A new tab opens right after the tab it follows by default: a session after the last session, a file after
        // the last file.
        let c = UUID()
        await model.upsert(AgentSessionRecord(id: c, workspaceID: workspace.id, worktreeID: nil, agent: .shell,
                                              accountID: nil, title: "s", cwd: folder.path))
        model.openFiles[context, default: []].append("/g")
        #expect(model.tabList(in: context) == [.changes, .session(a), .file("/f"), .file("/g"), .session(b), .session(c)])
        model.tabOrder[context] = nil
        model.saveTabOrder()
    }
}
