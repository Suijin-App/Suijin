import Foundation
import SuijinCore
import Testing
@testable import Suijin

/// The New pane runs setting and which agent a new pane starts: the setting, a choice made for one pane, and the
/// focused pane's agent. Live checks only ever start shells; a Claude pane is a record with no process.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct NewPaneAgentTests {
    let root: URL
    let folder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-newpane-\(UUID().uuidString)", isDirectory: true)
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

    /// A model with one folder workspace and a selected Claude session record that has no process.
    private func makeModel() async throws -> (AppModel, SessionContext, AgentSessionRecord) {
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspaceID = try #require(model.workspaces.first).id
        let context = SessionContext.workspace(workspaceID)
        await model.runtimes.bootstrap()
        let claude = AgentSessionRecord(workspaceID: workspaceID, worktreeID: nil, agent: .claude, accountID: nil,
                                        title: "claude", cwd: folder.path)
        await model.upsert(claude)
        model.selection = context
        model.selectedTab[context] = .session(claude.id)
        return (model, context, claude)
    }

    @Test func missingOrUnknownSettingMeansTheFocusedPanesAgent() {
        #expect(NewPaneAgent(setting: nil) == .sameAsFocused)
        #expect(NewPaneAgent(setting: "vim") == .sameAsFocused)
        #expect(NewPaneAgent(setting: "codex") == .codex)
        #expect(NewPaneAgent.sameAsFocused.agent == nil)
        #expect(NewPaneAgent.allCases.compactMap(\.agent) == [.shell, .claude, .codex])
    }

    @Test func resolvedAgentFollowsTheChoiceOrTheTargetPane() {
        for target in AgentKind.allCases {
            #expect(NewPaneAgent.sameAsFocused.resolved(beside: target) == target)
            #expect(NewPaneAgent.shell.resolved(beside: target) == .shell)
            #expect(NewPaneAgent.claude.resolved(beside: target) == .claude)
            #expect(NewPaneAgent.codex.resolved(beside: target) == .codex)
        }
    }

    @Test func settingRoundTripsThroughTheStoreAndTheDefaultIsStoredAsNoValue() async throws {
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.newPaneAgent == .sameAsFocused)
        model.setNewPaneAgent(.shell)
        #expect(model.newPaneAgent == .shell)
        #expect(await eventually { try model.store.setting(SettingKey.newPaneAgent.rawValue) == "shell" })
        let relaunched = AppModel(store: model.store, dataRoot: model.dataRoot)
        await relaunched.loadSettings()
        #expect(relaunched.newPaneAgent == .shell)

        model.setNewPaneAgent(.sameAsFocused)
        #expect(model.setting(.newPaneAgent) == nil)
        #expect(await eventually { try model.store.setting(SettingKey.newPaneAgent.rawValue) == nil })
    }

    /// ⌘D beside a Claude pane with the setting on Shell starts a shell, not another Claude.
    @Test func splitRunsTheSettingRatherThanTheFocusedPanesAgent() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, claude) = try await makeModel()
        model.setNewPaneAgent(.shell)
        model.split(in: context, axis: .sideBySide)
        #expect(await eventually { model.layout(containing: claude.id)?.paneCount == 2 })
        let layout = try #require(model.layout(containing: claude.id))
        let added = try #require(layout.panes.last)
        #expect(layout.panes == [claude.id, added])
        #expect(model.sessions.first { $0.id == added }?.agent == .shell)
        #expect(model.sessions.first { $0.id == added }?.accountID == nil)
        #expect(model.activeSession(in: context) == added)
        await model.closeSessions(model.sessions.map(\.id))
    }

    /// A choice made in the split button's menu wins over the setting; the new pane goes below the focused one.
    @Test func choiceForOnePaneWinsOverTheSetting() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, claude) = try await makeModel()
        model.setNewPaneAgent(.codex)
        let added = try #require(await model.addPane(in: context, axis: .stacked, agent: .shell))
        #expect(model.sessions.first { $0.id == added }?.agent == .shell)
        #expect(model.layout(containing: claude.id)?.root
                == .split(axis: .stacked, children: [.pane(claude.id), .pane(added)], fractions: [0.5, 0.5]))
        await model.closeSessions(model.sessions.map(\.id))
    }

    /// The context menus split beside the pane they belong to, which need not be the focused one.
    @Test func splitBesideAPaneThatIsNotFocused() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, claude) = try await makeModel()
        model.setNewPaneAgent(.shell)
        let second = try #require(await model.addPane(in: context, axis: .sideBySide))
        #expect(model.activeSession(in: context) == second)
        model.split(beside: claude.id, edge: .bottom)
        #expect(await eventually { model.layout(containing: claude.id)?.paneCount == 3 })
        let layout = try #require(model.layout(containing: claude.id))
        let third = try #require(layout.panes.first { $0 != claude.id && $0 != second })
        #expect(layout.root == .split(axis: .sideBySide, children: [
            .split(axis: .stacked, children: [.pane(claude.id), .pane(third)], fractions: [0.5, 0.5]), .pane(second),
        ], fractions: [0.5, 0.5]))
        await model.closeSessions(model.sessions.map(\.id))
    }

    @Test func addingIsUnavailableWithoutASessionTabOrWhenTheTabIsFull() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, claude) = try await makeModel()
        #expect(model.addPaneUnavailableReason(in: context) == nil)
        // A context with no session tab.
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        await model.addWorkspace(at: empty)
        let emptyContext = SessionContext.workspace(try #require(model.workspaces.first { $0.name == "empty" }).id)
        #expect(model.addPaneUnavailableReason(in: emptyContext) != nil)
        #expect(await model.addPane(in: emptyContext, axis: .sideBySide, agent: .shell) == nil)

        for _ in 1..<PaneLayout.maxPanes { _ = await model.addPane(in: context, axis: .sideBySide, agent: .shell) }
        #expect(model.layout(containing: claude.id)?.paneCount == PaneLayout.maxPanes)
        #expect(model.addPaneUnavailableReason(in: context) != nil)
        await model.closeSessions(model.sessions.map(\.id))
    }
}
