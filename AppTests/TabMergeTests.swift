import Foundation
import SuijinCore
import SwiftUI
import Testing
@testable import Suijin

/// Moving a whole tab into another tab as panes (a tab dropped on a pane, or Move Tab to Selected Tab): a plain tab
/// becomes one pane, a split tab keeps its arrangement, the moved tab leaves the tab bar, and the result is stored.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct TabMergeTests {
    let root: URL
    let folder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-merge-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private var databaseURL: URL { root.appendingPathComponent("data/suijin.sqlite") }

    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () async throws -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return (try? await condition()) == true
    }

    /// `count` plain session tabs over session records only (no processes).
    private func makeTabs(_ count: Int) async throws -> (AppModel, SessionContext, [UUID]) {
        let model = AppModel(store: try SuijinStore(url: databaseURL), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspaceID = try #require(model.workspaces.first).id
        var ids: [UUID] = []
        for index in 0..<count {
            let record = AgentSessionRecord(workspaceID: workspaceID, worktreeID: nil, agent: .shell, accountID: nil,
                                            title: "s\(index)", cwd: folder.path, state: .exited)
            await model.upsert(record)
            ids.append(record.id)
        }
        return (model, .workspace(workspaceID), ids)
    }

    private func sessionTabs(_ model: AppModel, _ context: SessionContext) -> [DetailTab] {
        model.tabList(in: context).filter { $0.orderKey != nil }
    }

    @Test func aPlainTabBecomesAPaneOfAnotherPlainTabInThatTabsPlace() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, ids) = try await makeTabs(3)
        #expect(model.canMergeTab(.session(ids[2]), beside: ids[0]))
        try model.mergeTab(.session(ids[2]), beside: ids[0], edge: .left)

        let layout = try #require(model.layout(containing: ids[0]))
        #expect(layout.root == .split(axis: .sideBySide, children: [.pane(ids[2]), .pane(ids[0])], fractions: [0.5, 0.5]))
        #expect(layout.focused == ids[2])
        // The split tab stands where the target's tab stood; the moved tab is gone.
        #expect(sessionTabs(model, context) == [.panes(layout.id), .session(ids[1])])
        #expect(model.currentTab(in: context) == .panes(layout.id))

        // Onto a pane of the split tab, on the side asked for.
        try model.mergeTab(.session(ids[1]), beside: ids[0], edge: .bottom)
        let grown = try #require(model.paneLayouts[layout.id])
        #expect(grown.root == .split(axis: .sideBySide,
                                     children: [.pane(ids[2]), .split(axis: .stacked, children: [.pane(ids[0]), .pane(ids[1])], fractions: [0.5, 0.5])],
                                     fractions: [0.5, 0.5]))
        #expect(sessionTabs(model, context) == [.panes(layout.id)])

        // The merged arrangement comes back after a relaunch.
        // The save lands on its own task: wait for it by reading the file, without an app model, whose load would
        // write layouts of its own beside the ones under test. Then a relaunch must bring the arrangement back.
        #expect(await eventually { try SuijinStore(url: databaseURL).paneLayouts().contains { $0.layout.root == grown.root } })
        let reopened = AppModel(store: try SuijinStore(url: databaseURL), dataRoot: root.appendingPathComponent("data"))
        await reopened.load()
        #expect(reopened.layout(containing: ids[1])?.root == grown.root)
    }

    @Test func aSplitTabMovesAsAGroupAndItsOwnLayoutIsDeleted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, ids) = try await makeTabs(5)
        // Two split tabs, [s0 | s1] and [s2 / s3] with s2 taking 70 %, and the plain tab s4.
        try model.insertPane(ids[1], beside: ids[0], edge: .right)
        try model.insertPane(ids[3], beside: ids[2], edge: .bottom)
        let first = try #require(model.layout(containing: ids[0]))
        let second = try #require(model.layout(containing: ids[2]))
        model.setPaneFractions([0.7, 0.3], at: [], in: second.id)
        model.focusPane(ids[2])

        // Onto a plain tab: it becomes a split tab in its own place, holding the group as it was.
        #expect(model.canMergeTab(.panes(second.id), beside: ids[4]))
        try model.mergeTab(.panes(second.id), beside: ids[4], edge: .right)
        let merged = try #require(model.layout(containing: ids[4]))
        #expect(merged.root == .split(axis: .sideBySide,
                                      children: [.pane(ids[4]), .split(axis: .stacked, children: [.pane(ids[2]), .pane(ids[3])], fractions: [0.7, 0.3])],
                                      fractions: [0.5, 0.5]))
        #expect(merged.focused == ids[2])
        #expect(model.paneLayouts[second.id] == nil)
        #expect(sessionTabs(model, context) == [.panes(first.id), .panes(merged.id)])
        #expect(model.currentTab(in: context) == .panes(merged.id))

        // Onto a pane of another split tab; no pane is ever in two layouts.
        try model.mergeTab(.panes(merged.id), beside: ids[1], edge: .bottom)
        let all = try #require(model.paneLayouts[first.id])
        #expect(all.paneCount == 5)
        #expect(model.paneLayouts.count == 1)
        #expect(sessionTabs(model, context) == [.panes(first.id)])
        #expect(Set(ids).allSatisfy { model.layout(containing: $0)?.id == first.id })

        // Only the surviving layout is stored.
        #expect(await eventually {
            let stored = try SuijinStore(url: databaseURL).paneLayouts()
            return stored.count == 1 && stored.first?.layout.root == all.root
        })
    }

    @Test func aTabMergesOnlyIntoAnotherSessionTabOfItsContextWithRoom() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, ids) = try await makeTabs(12)
        // Itself, Changes and files, a pane that is no tab, an unknown session.
        #expect(!model.canMergeTab(.session(ids[0]), beside: ids[0]))
        #expect(!model.canMergeTab(.changes, beside: ids[0]))
        #expect(!model.canMergeTab(.file("/tmp/a.txt"), beside: ids[0]))
        #expect(!model.canMergeTab(.session(ids[0]), beside: UUID()))
        #expect(throws: PaneLayoutError.samePane) { try model.mergeTab(.session(ids[0]), beside: ids[0], edge: .right) }
        #expect(throws: PaneLayoutError.unknownPane) { try model.mergeTab(.changes, beside: ids[0], edge: .right) }

        // A tab of nine panes takes one more tab, then no other; a split tab that would pass ten is refused whole.
        for index in 1..<9 { try model.mergeTab(.session(ids[index]), beside: ids[0], edge: .right) }
        let nine = try #require(model.layout(containing: ids[0]))
        #expect(!model.canMergeTab(.session(ids[1]), beside: ids[0]))
        #expect(!model.canMergeTab(.panes(nine.id), beside: ids[3]))
        try model.insertPane(ids[10], beside: ids[9], edge: .right)
        let pair = try #require(model.layout(containing: ids[9]))
        #expect(!model.canMergeTab(.panes(pair.id), beside: ids[0]))
        #expect(throws: PaneLayoutError.full) { try model.mergeTab(.panes(pair.id), beside: ids[0], edge: .right) }
        #expect(model.paneLayouts[pair.id] == pair)
        #expect(model.canMergeTab(.session(ids[11]), beside: ids[0]))
        try model.mergeTab(.session(ids[11]), beside: ids[0], edge: .bottom)
        #expect(!model.canMergeTab(.session(ids[9]), beside: ids[0]))
        #expect(sessionTabs(model, context).count == 2)

        // A session of another context.
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        await model.addWorkspace(at: other)
        let otherID = try #require(model.workspaces.first { $0.path == other.path }).id
        let stranger = AgentSessionRecord(workspaceID: otherID, worktreeID: nil, agent: .shell, accountID: nil,
                                          title: "x", cwd: other.path, state: .exited)
        await model.upsert(stranger)
        #expect(!model.canMergeTab(.session(stranger.id), beside: ids[9]))
    }

    @Test func mergingIntoAZoomedTabShowsEveryPaneAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, ids) = try await makeTabs(5)
        try model.insertPane(ids[1], beside: ids[0], edge: .right)
        model.toggleZoom(ids[0])
        #expect(model.layout(containing: ids[0])?.zoomed == ids[0])
        try model.mergeTab(.session(ids[2]), beside: ids[0], edge: .bottom)
        #expect(model.layout(containing: ids[0])?.zoomed == nil)

        try model.insertPane(ids[4], beside: ids[3], edge: .right)
        let pair = try #require(model.layout(containing: ids[3]))
        model.toggleZoom(ids[0])
        try model.mergeTab(.panes(pair.id), beside: ids[0], edge: .top)
        #expect(model.layout(containing: ids[0])?.zoomed == nil)
        #expect(model.layout(containing: ids[0])?.paneCount == 5)
    }

    @Test func aMergedTabThatWasReorderedComesBackRightAfterTheSplitTab() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, ids) = try await makeTabs(4)
        // The tab order is dragged, so every tab is listed in it: s3, s0, s1, s2.
        model.moveTab(.session(ids[3]), onto: .session(ids[0]), in: context)
        try model.mergeTab(.session(ids[3]), beside: ids[2], edge: .right)
        let layout = try #require(model.layout(containing: ids[2]))
        #expect(sessionTabs(model, context) == [.session(ids[0]), .session(ids[1]), .panes(layout.id)])

        // Taken out again, the pane's tab follows the split tab's place, not the place it had before the merge.
        model.movePaneToNewTab(ids[3])
        #expect(sessionTabs(model, context) == [.session(ids[0]), .session(ids[1]), .session(ids[2]), .session(ids[3])])
    }

    @Test func aDraggedTabLandsOnAPaneOnlyWhileItIsTheOneDragged() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, ids) = try await makeTabs(4)
        try model.insertPane(ids[1], beside: ids[0], edge: .right)
        // Nothing is dragged.
        #expect(!model.canDropDraggedTab(onto: ids[0]))
        #expect(!model.dropDraggedTab(onto: ids[0], edge: .right))

        model.paneDrag.beginTab(.session(ids[2]))
        #expect(model.canDropDraggedTab(onto: ids[0]))
        #expect(model.canDropDraggedTab(onto: ids[3]))
        // Not on the tab's own terminal, and a pane drag is none of it.
        #expect(!model.canDropDraggedTab(onto: ids[2]))
        #expect(!model.canDropDraggedPane(onto: ids[0]))
        model.paneDrag.hover(ids[1], placement: .edge(.bottom))
        #expect(model.paneDrag.target == .init(pane: ids[1], placement: .edge(.bottom)))

        // A pane drag that starts next replaces a tab drag that ended without a drop, and the other way round.
        model.paneDrag.begin(ids[0])
        #expect(model.paneDrag.tab == nil && model.paneDrag.target == nil)
        #expect(!model.canDropDraggedTab(onto: ids[3]))
        model.paneDrag.beginTab(.session(ids[2]))
        #expect(model.paneDrag.source == nil)

        // Dropped on a zoomed pane: the tab shows every pane again, with the dragged tab's session focused.
        model.toggleZoom(ids[1])
        #expect(model.dropDraggedTab(onto: ids[1], edge: .bottom))
        let layout = try #require(model.layout(containing: ids[2]))
        #expect(layout.root == .split(axis: .sideBySide,
                                      children: [.pane(ids[0]), .split(axis: .stacked, children: [.pane(ids[1]), .pane(ids[2])], fractions: [0.5, 0.5])],
                                      fractions: [0.5, 0.5]))
        #expect(layout.zoomed == nil && layout.focused == ids[2])
        #expect(model.paneDrag.tab == nil && model.paneDrag.target == nil)
        #expect(sessionTabs(model, context) == [.panes(layout.id), .session(ids[3])])

        // A Changes or file tab is never taken.
        model.paneDrag.beginTab(.changes)
        #expect(!model.canDropDraggedTab(onto: ids[3]))
        model.paneDrag.beginTab(.file("/tmp/a.txt"))
        #expect(!model.canDropDraggedTab(onto: ids[3]))
        model.paneDrag.end()
    }

    @Test func aPaneOverAnyPartOfTheTabGroupLightsItUpUntilItLeavesEveryPart() {
        let drag = PaneDragState()
        drag.begin(UUID())
        // The pointer moves from the group onto a tab: the tab is entered before or after the group is left.
        drag.hoverTabBar("group", true)
        drag.hoverTabBar("session:a", true)
        drag.hoverTabBar("group", false)
        #expect(!drag.tabBarHover.isEmpty)
        drag.hoverTabBar("session:b", true)
        drag.hoverTabBar("session:a", false)
        #expect(!drag.tabBarHover.isEmpty)
        drag.hoverTabBar("session:b", false)
        #expect(drag.tabBarHover.isEmpty)
        // A drag that ends over the group leaves nothing lit.
        drag.hoverTabBar("group", true)
        drag.end()
        #expect(drag.tabBarHover.isEmpty && drag.source == nil)
    }

    @Test func aTabMovesIntoTheSelectedTabWithoutADrag() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, context, ids) = try await makeTabs(4)
        model.selectedTab[context] = .session(ids[0])
        #expect(model.moveTabToSelectedTabUnavailableReason(showing: ids[0]) == "This tab is already selected")
        #expect(model.moveTabToSelectedTabUnavailableReason(showing: ids[1]) == nil)

        model.moveTabToSelectedTab(showing: ids[1], edge: .right)
        let layout = try #require(model.layout(containing: ids[0]))
        #expect(layout.root == .split(axis: .sideBySide, children: [.pane(ids[0]), .pane(ids[1])], fractions: [0.5, 0.5]))
        #expect(model.selection == context)
        // Either pane of the selected tab stands for it.
        #expect(model.moveTabToSelectedTabUnavailableReason(showing: ids[1]) == "This tab is already selected")

        // A split tab moves whole, whichever of its panes the menu was opened on, beside the focused pane.
        try model.insertPane(ids[3], beside: ids[2], edge: .bottom)
        model.selectedTab[context] = .panes(layout.id)
        model.focusPane(ids[0])
        model.moveTabToSelectedTab(showing: ids[3], edge: .bottom)
        let all = try #require(model.paneLayouts[layout.id])
        #expect(all.panes == [ids[0], ids[2], ids[3], ids[1]])
        #expect(sessionTabs(model, context) == [.panes(layout.id)])

        // Nothing to move into while a file is shown.
        let late = AgentSessionRecord(workspaceID: try #require(model.workspaces.first).id, worktreeID: nil, agent: .shell,
                                      accountID: nil, title: "late", cwd: folder.path, state: .exited)
        await model.upsert(late)
        model.openFiles[context] = ["/tmp/a.txt"]
        model.selectedTab[context] = .file("/tmp/a.txt")
        #expect(model.moveTabToSelectedTabUnavailableReason(showing: late.id) == "Select a session tab to move this tab into it")
        model.moveTabToSelectedTab(showing: late.id, edge: .right)
        #expect(model.layout(containing: late.id) == nil)
    }
}
