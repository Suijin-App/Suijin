import Foundation
import SevindaCore
import Testing
@testable import Sevinda

/// The bulk and restart actions behind the sidebar's context menus, on real shell sessions.
@MainActor
@Suite(.serialized)
struct SidebarMenuActionTests {
    private func makeModel() async throws -> (AppModel, SessionContext, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-menu-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        await model.runtimes.bootstrap()
        return (model, .workspace(try #require(model.workspaces.first).id), root)
    }

    @Test func closeSessionsEndsEveryOneGiven() async throws {
        let (model, context, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        var ids: [UUID] = []
        for _ in 0..<3 { ids.append(try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))) }
        #expect(model.tabSessions(in: context).count == 3)
        await model.closeSessions(Array(ids.prefix(2)))
        #expect(model.tabSessions(in: context).map(\.id) == [ids[2]])
        await model.closeSessions([ids[2]])
        #expect(model.tabSessions(in: context).isEmpty)
        #expect(ids.allSatisfy { model.runtimes.runtime(for: $0) == nil })
    }

    @Test func startAgainReplacesAnEndedSession() async throws {
        let (model, context, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
        model.runtimes.runtime(for: id)?.terminal.send("exit\n")
        for _ in 0..<50 where model.runtimes.activity(of: try #require(model.sessions.first { $0.id == id })).isEnded == false {
            try await Task.sleep(for: .milliseconds(100))
        }
        let ended = try #require(model.sessions.first { $0.id == id })
        #expect(model.runtimes.activity(of: ended).isEnded)
        await model.startAgain(ended)
        let sessions = model.tabSessions(in: context)
        #expect(sessions.count == 1 && sessions[0].id != id && sessions[0].agent == .shell)
        #expect(model.runtimes.runtime(for: sessions[0].id) != nil)
        await model.closeSessions(sessions.map(\.id))
    }
}
