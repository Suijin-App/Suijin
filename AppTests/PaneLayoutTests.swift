import Foundation
import SevindaCore
import Testing
@testable import Sevinda

/// Split tabs in the app model: adding, closing, moving and focusing panes, their place among the tabs, and the
/// layout coming back after a relaunch.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PaneLayoutTests {
    let root: URL
    let folder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-layout-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () throws -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return (try? condition()) == true
    }

    /// A model on a database file in the temporary folder, with one folder workspace and `count` session records
    /// (no processes).
    private func makeModel(sessions count: Int, store: SevindaStore? = nil) async throws -> (AppModel, SessionContext, [UUID]) {
        let store = try store ?? SevindaStore(url: root.appendingPathComponent("data/sevinda.sqlite"))
        let model = AppModel(store: store, dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspaceID = try #require(model.workspaces.first).id
        var ids: [UUID] = []
        for index in 0..<count {
            let record = AgentSessionRecord(workspaceID: workspaceID, worktreeID: nil, agent: index == 0 ? .claude : .shell,
                                            accountID: nil, title: "s\(index)", cwd: folder.path)
            await model.upsert(record)
            ids.append(record.id)
        }
        return (model, .workspace(workspaceID), ids)
    }

    @Test func panesFormOneTabInPlaceOfTheFirstAndGoBackToAPlainTab() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, ids) = try await makeModel(sessions: 4)
        UserDefaults.standard.removeObject(forKey: "tabs.sessionOrder")
        model.sessionOrder = [:]
        model.moveTab(.session(ids[3]), onto: .session(ids[0]), in: context)
        #expect(model.sessionTabs(in: context) == [.session(ids[3]), .session(ids[0]), .session(ids[1]), .session(ids[2])])

        // s1 joins s0's tab, which becomes a split tab in s0's place, selected, with s1 focused.
        try model.insertPane(ids[1], beside: ids[0], edge: .right)
        let layout = try #require(model.layout(containing: ids[0]))
        #expect(model.sessionTabs(in: context) == [.session(ids[3]), .panes(layout.id), .session(ids[2])])
        #expect(model.currentTab(in: context) == .panes(layout.id))
        #expect(model.activeSession(in: context) == ids[1])
        #expect(model.tabSessions(in: context).map(\.id) == [ids[3], ids[0], ids[1], ids[2]])

        // Selecting a pane's session selects its tab and focuses the pane.
        model.selectedTab[context] = .session(ids[3])
        model.selectedTab[context] = .session(ids[0])
        #expect(model.selectedTab[context] == .panes(layout.id))
        #expect(model.activeSession(in: context) == ids[0])

        // Dragging the split tab moves it like any tab.
        model.moveTab(.panes(layout.id), onto: .session(ids[3]), in: context)
        #expect(model.sessionTabs(in: context) == [.panes(layout.id), .session(ids[3]), .session(ids[2])])
        #expect(DetailTab(dragPayload: DetailTab.panes(layout.id).dragPayload!) == .panes(layout.id))

        // Closing a pane of two leaves a plain tab in the same place, still selected.
        await model.closeSession(ids[0])
        #expect(model.layout(containing: ids[1]) == nil)
        #expect(model.paneLayouts.isEmpty)
        #expect(model.sessionTabs(in: context) == [.session(ids[1]), .session(ids[3]), .session(ids[2])])
        #expect(model.currentTab(in: context) == .session(ids[1]))
        #expect(await eventually { try model.store.paneLayouts().isEmpty })
    }

    @Test func movingFocusingZoomingAndTakingAPaneOut() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, ids) = try await makeModel(sessions: 4)
        try model.insertPane(ids[1], beside: ids[0], edge: .right)
        try model.insertPane(ids[2], beside: ids[1], edge: .bottom)
        let id = try #require(model.layout(containing: ids[0])).id
        // [s0 | (s1 / s2)]
        #expect(model.activeSession(in: context) == ids[2])
        #expect(model.focusNeighborPane(in: context, toward: .top))
        #expect(model.activeSession(in: context) == ids[1])
        #expect(model.focusNeighborPane(in: context, toward: .left))
        #expect(model.activeSession(in: context) == ids[0])
        #expect(!model.focusNeighborPane(in: context, toward: .left))

        #expect(model.movePane(ids[0], toward: .right))
        #expect(model.paneLayouts[id]?.panes == [ids[1], ids[0], ids[2]])
        try model.movePane(ids[2], to: ids[1], placement: .edge(.left))
        #expect(model.paneLayouts[id]?.panes.first == ids[2])

        model.setPaneFractions([0.8, 0.2], at: [], in: id)
        model.equalizePanes(id)
        let shares = try #require(model.paneLayouts[id]?.split(at: [])?.fractions)
        #expect(shares.allSatisfy { abs($0 - 1 / Double(shares.count)) < 1e-9 })

        model.toggleZoom(ids[1])
        #expect(model.visiblePanes(in: context) == [ids[1]])
        // The keyboard going to a hidden pane ends the zoom.
        model.focusPane(ids[0])
        #expect(model.visiblePanes(in: context).count == 3)

        model.movePaneToNewTab(ids[2])
        #expect(model.paneLayouts[id]?.panes.count == 2)
        #expect(model.sessionTabs(in: context) == [.panes(id), .session(ids[2]), .session(ids[3])])
        #expect(model.currentTab(in: context) == .session(ids[2]))
    }

    @Test func layoutFractionsAndFocusSurviveARelaunch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, ids) = try await makeModel(sessions: 4)
        try model.insertPane(ids[1], beside: ids[0], edge: .right)
        try model.insertPane(ids[2], beside: ids[1], edge: .bottom)
        let layoutID = try #require(model.layout(containing: ids[0])).id
        model.setPaneFractions([0.7, 0.3], at: [], in: layoutID)
        model.focusPane(ids[1])
        let expected = try #require(model.paneLayouts[layoutID])
        #expect(await eventually { try model.store.paneLayouts().map(\.layout) == [expected] })

        // A session deleted while the app was closed loses its pane; the others keep theirs.
        try model.store.deleteSession(id: ids[2])
        let reopened = AppModel(store: try SevindaStore(url: root.appendingPathComponent("data/sevinda.sqlite")),
                                dataRoot: root.appendingPathComponent("data"))
        await reopened.load()
        let restored = try #require(reopened.paneLayouts[layoutID])
        #expect(restored.panes == [ids[0], ids[1]])
        #expect(abs((restored.split(at: [])?.fractions.first ?? 0) - 0.7) < 1e-9)
        #expect(restored.focused == ids[1])
        #expect(reopened.sessionTabs(in: context) == [.panes(layoutID), .session(ids[3])])

        // With one pane left the stored layout goes, and the tab is a plain one again.
        try reopened.store.deleteSession(id: ids[0])
        let third = AppModel(store: try SevindaStore(url: root.appendingPathComponent("data/sevinda.sqlite")),
                             dataRoot: root.appendingPathComponent("data"))
        await third.load()
        #expect(third.paneLayouts.isEmpty)
        #expect(third.sessionTabs(in: context) == [.session(ids[1]), .session(ids[3])])
        #expect(await eventually { try third.store.paneLayouts().isEmpty })
    }

    /// ⌘D and ⇧⌘D on real shells: the new pane runs the focused pane's agent, next to it, and a tab holds ten panes.
    @Test func splittingAddsPanesUpToTen() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        await model.runtimes.bootstrap()
        let first = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))

        let second = try #require(await model.newPane(in: context, edge: .right))
        #expect(model.sessions.first { $0.id == second }?.agent == .shell)
        #expect(model.layout(containing: first)?.panes == [first, second])
        #expect(model.activeSession(in: context) == second)

        model.split(in: context, axis: .stacked)
        #expect(await eventually { model.layout(containing: first)?.paneCount == 3 })
        let third = try #require(model.layout(containing: first)?.focused)
        #expect(model.layout(containing: first)?.root
                == .split(axis: .sideBySide, children: [.pane(first), .split(axis: .stacked, children: [.pane(second), .pane(third)],
                                                                               fractions: [0.5, 0.5])], fractions: [0.5, 0.5]))
        for _ in 3..<PaneLayout.maxPanes { _ = await model.newPane(in: context, edge: .right) }
        #expect(model.layout(containing: first)?.paneCount == PaneLayout.maxPanes)
        #expect(!model.canAddPane(beside: first))
        #expect(await model.newPane(in: context, edge: .right) == nil)
        #expect(model.presentedError != nil)
        #expect(model.sessions.count == PaneLayout.maxPanes)
        #expect(model.sessionTabs(in: context).count == 1)

        await model.closeSessions(model.sessions.map(\.id))
        #expect(model.paneLayouts.isEmpty)
    }
}
