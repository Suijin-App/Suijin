import AppKit
import Foundation
import MercuryCore
import MercuryTerminal
import Testing
@testable import Mercury

/// Rearranging panes: dropping a dragged pane on another pane's edge or middle, on the title-bar tab group, a drag
/// that ends without a drop, and the ⌃⌥⌘ arrow moves; every change is stored.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PaneDragTests {
    let root: URL
    let folder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mercury-drag-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private var databaseURL: URL { root.appendingPathComponent("data/mercury.sqlite") }

    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () async throws -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return (try? await condition()) == true
    }

    /// A split tab of three panes in a row, [s0 | s1 | s2], over session records only (no processes).
    private func makeRow() async throws -> (AppModel, SessionContext, [UUID]) {
        let model = AppModel(store: try MercuryStore(url: databaseURL), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspaceID = try #require(model.workspaces.first).id
        var ids: [UUID] = []
        for index in 0..<3 {
            let record = AgentSessionRecord(workspaceID: workspaceID, worktreeID: nil, agent: .shell, accountID: nil,
                                            title: "s\(index)", cwd: folder.path, state: .exited)
            await model.upsert(record)
            ids.append(record.id)
        }
        try model.insertPane(ids[1], beside: ids[0], edge: .right)
        try model.insertPane(ids[2], beside: ids[1], edge: .right)
        return (model, .workspace(workspaceID), ids)
    }

    @Test func aPaneTakesNoDropOfItselfAndNothingWithoutADrag() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, ids) = try await makeRow()
        #expect(!model.canDropDraggedPane(onto: ids[1]))
        #expect(!model.dropDraggedPane(onto: ids[1], placement: .center))

        model.paneDrag.begin(ids[0])
        #expect(!model.canDropDraggedPane(onto: ids[0]))
        #expect(model.canDropDraggedPane(onto: ids[1]))
        // The pointer over a zone, then off the pane.
        model.paneDrag.hover(ids[1], placement: .edge(.left))
        #expect(model.paneDrag.target == .init(pane: ids[1], placement: .edge(.left)))
        model.paneDrag.hover(ids[1], placement: nil)
        #expect(model.paneDrag.target == nil)
        model.paneDrag.hover(ids[2], placement: .center)
        // Leaving another pane does not clear this one's preview.
        model.paneDrag.leave(ids[1])
        #expect(model.paneDrag.target?.pane == ids[2])

        // A drag that ends without a drop (Esc, released elsewhere) changes nothing.
        let before = model.layout(containing: ids[0])
        model.paneDrag.end()
        #expect(model.paneDrag.source == nil && model.paneDrag.target == nil)
        #expect(model.layout(containing: ids[0]) == before)

        // Nothing lands while a pane is zoomed.
        model.toggleZoom(ids[2])
        model.paneDrag.begin(ids[0])
        #expect(!model.canDropDraggedPane(onto: ids[1]))
        model.paneDrag.end()
    }

    @Test func droppingOnAnEdgePlacesThePaneThereAndStoresTheLayout() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, ids) = try await makeRow()
        model.paneDrag.begin(ids[0])
        model.paneDrag.hover(ids[2], placement: .edge(.bottom))
        #expect(model.dropDraggedPane(onto: ids[2], placement: .edge(.bottom)))
        let layout = try #require(model.layout(containing: ids[0]))
        #expect(layout.root == .split(axis: .sideBySide,
                                      children: [.pane(ids[1]), .split(axis: .stacked, children: [.pane(ids[2]), .pane(ids[0])], fractions: [0.5, 0.5])],
                                      fractions: [0.5, 0.5]))
        #expect(layout.focused == ids[0])
        #expect(model.paneDrag.source == nil && model.paneDrag.target == nil)

        // The new arrangement comes back after a relaunch.
        #expect(await eventually {
            let reopened = AppModel(store: try MercuryStore(url: databaseURL), dataRoot: root.appendingPathComponent("data"))
            await reopened.load()
            return reopened.layout(containing: ids[0])?.root == layout.root
        })
    }

    @Test func droppingInTheMiddleSwapsAndTheDraggedPaneKeepsTheKeyboard() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, ids) = try await makeRow()
        let layoutID = try #require(model.layout(containing: ids[0])).id
        model.setPaneFractions([0.5, 0.3, 0.2], at: [], in: layoutID)
        model.focusPane(ids[1])
        model.paneDrag.begin(ids[0])
        #expect(model.dropDraggedPane(onto: ids[2], placement: .center))
        let layout = try #require(model.paneLayouts[layoutID])
        #expect(layout.panes == [ids[2], ids[1], ids[0]])
        #expect(layout.split(at: [])?.fractions.map { ($0 * 10).rounded() / 10 } == [0.5, 0.3, 0.2])
        #expect(layout.focused == ids[0])
    }

    @Test func droppingOnTheTabBarMovesThePaneToATabOfItsOwn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, ids) = try await makeRow()
        model.paneDrag.begin(ids[1])
        #expect(model.canDropDraggedPaneOnTabBar(in: context))
        #expect(!model.canDropDraggedPaneOnTabBar(in: .workspace(UUID())))
        #expect(model.dropDraggedPaneOnTabBar(in: context))
        #expect(model.layout(containing: ids[1]) == nil)
        #expect(model.layout(containing: ids[0])?.panes == [ids[0], ids[2]])
        #expect(model.currentTab(in: context) == .session(ids[1]))
        #expect(model.paneDrag.source == nil)
        // A plain tab's session is no pane to drop.
        model.paneDrag.begin(ids[1])
        #expect(!model.canDropDraggedPaneOnTabBar(in: context))
        model.paneDrag.end()
    }

    @Test func controlOptionCommandArrowsSwapTheTypedInPaneWithItsNeighbor() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, ids) = try await makeRow()
        let arrow = { (code: Int) in String(UnicodeScalar(UInt16(code))!) }
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .numericPad, .function]
        let right = TerminalKeyRouter.route(key: arrow(NSRightArrowFunctionKey), modifiers: modifiers)
        #expect(right == .movePane(.right))
        // Typed in s0's terminal: s0 trades places with s1 and keeps the keyboard.
        #expect(model.handle(right, in: context, from: ids[0]))
        #expect(model.layout(containing: ids[0])?.panes == [ids[1], ids[0], ids[2]])
        #expect(model.activeSession(in: context) == ids[0])
        // At the tab's edge nothing moves; the shortcut is still Mercury's, never the agent's.
        let up = TerminalKeyRouter.route(key: arrow(NSUpArrowFunctionKey), modifiers: modifiers)
        #expect(model.handle(up, in: context, from: ids[0]))
        #expect(model.layout(containing: ids[0])?.panes == [ids[1], ids[0], ids[2]])
        // The menu command acts on the focused pane.
        #expect(model.moveFocusedPane(in: context, toward: .left))
        #expect(model.layout(containing: ids[0])?.panes == [ids[0], ids[1], ids[2]])
        #expect(!model.moveFocusedPane(in: context, toward: .left))
    }
}
