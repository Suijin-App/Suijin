import Foundation
import GRDB
import Testing
@testable import SevindaCore

/// The pane tree's operations: every result is normalized, sizes are shared as described and the limit holds.
struct PaneLayoutTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    private func approx(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    private func fractions(_ layout: PaneLayout, at path: [Int] = []) -> [Double] {
        layout.split(at: path)?.fractions ?? []
    }

    @Test func insertingOnEachEdgePlacesThePaneThereAndFocusesIt() throws {
        let base = PaneLayout(pane: a)
        let right = try base.inserting(b, beside: a, edge: .right)
        #expect(right.root == .split(axis: .sideBySide, children: [.pane(a), .pane(b)], fractions: [0.5, 0.5]))
        #expect(right.focused == b)
        #expect(try base.inserting(b, beside: a, edge: .left).panes == [b, a])
        #expect(try base.inserting(b, beside: a, edge: .bottom).root == .split(axis: .stacked, children: [.pane(a), .pane(b)], fractions: [0.5, 0.5]))
        #expect(try base.inserting(b, beside: a, edge: .top).panes == [b, a])
    }

    @Test func insertingAlongTheSameAxisJoinsTheSplitInsteadOfNesting() throws {
        let layout = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right).inserting(c, beside: b, edge: .right)
        #expect(layout.root == .split(axis: .sideBySide, children: [.pane(a), .pane(b), .pane(c)], fractions: [0.5, 0.25, 0.25]))
        // Across the axis, the target becomes a nested split in its own place.
        let nested = try layout.inserting(d, beside: b, edge: .bottom)
        #expect(nested.root == .split(axis: .sideBySide,
                                      children: [.pane(a), .split(axis: .stacked, children: [.pane(b), .pane(d)], fractions: [0.5, 0.5]), .pane(c)],
                                      fractions: [0.5, 0.25, 0.25]))
        #expect(nested.paneCount == 4)
    }

    @Test func tenPanesAtMostAndNoDuplicates() throws {
        var layout = PaneLayout(pane: a)
        var last = a
        for _ in 1..<PaneLayout.maxPanes {
            let next = UUID()
            layout = try layout.inserting(next, beside: last, edge: .right)
            last = next
        }
        #expect(layout.paneCount == 10)
        #expect(layout.isFull)
        #expect(throws: PaneLayoutError.full) { try layout.inserting(UUID(), beside: a, edge: .bottom) }
        #expect(throws: PaneLayoutError.duplicatePane) { try PaneLayout(pane: a).inserting(a, beside: a, edge: .right) }
        #expect(throws: PaneLayoutError.unknownPane) { try PaneLayout(pane: a).inserting(b, beside: c, edge: .right) }
        #expect(approx(fractions(layout).reduce(0, +) == 1 ? [1] : [fractions(layout).reduce(0, +)], [1]))
    }

    @Test func removingGivesTheRoomBackAndCollapsesSingleChildSplits() throws {
        let row = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right).inserting(c, beside: b, edge: .right)
        let withoutB = try #require(try row.removing(b))
        #expect(withoutB.panes == [a, c])
        #expect(approx(fractions(withoutB), [0.5 / 0.75, 0.25 / 0.75]))

        // A nested split left with one pane disappears, and a same-axis split it leaves behind merges upward.
        let nested = try row.inserting(d, beside: b, edge: .bottom)
        let collapsed = try #require(try nested.removing(d))
        #expect(collapsed.root == row.root)

        let deep = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right)
            .inserting(c, beside: b, edge: .bottom).inserting(d, beside: c, edge: .right)
        // [a | (b / (c | d))]: removing b leaves (c | d) inside the side-by-side root, merged into it.
        let merged = try #require(try deep.removing(b))
        #expect(merged.root == .split(axis: .sideBySide, children: [.pane(a), .pane(c), .pane(d)], fractions: [0.5, 0.25, 0.25]))

        #expect(try PaneLayout(pane: a).removing(a) == nil)
        #expect(throws: PaneLayoutError.unknownPane) { try row.removing(e) }
    }

    @Test func removingTheFocusedPaneFocusesThePaneThatGrowsIntoItsRoom() throws {
        let row = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right).inserting(c, beside: b, edge: .right)
        #expect(try row.focusing(b).removing(b)?.focused == a)
        #expect(try row.focusing(a).removing(a)?.focused == b)
        // Another pane keeps the focus it had.
        #expect(try row.focusing(c).removing(a)?.focused == c)
        // A zoomed pane that closes ends the zoom.
        #expect(try row.togglingZoom(b).removing(b)?.zoomed == nil)
    }

    @Test func movingToAnEdgeOrTheCenter() throws {
        let row = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right).inserting(c, beside: b, edge: .right)
        let moved = try row.moving(a, to: c, placement: .edge(.bottom))
        #expect(moved.panes == [b, c, a])
        #expect(moved.focused == a)
        #expect(moved.root == .split(axis: .sideBySide,
                                     children: [.pane(b), .split(axis: .stacked, children: [.pane(c), .pane(a)], fractions: [0.5, 0.5])],
                                     fractions: [0.25 / 0.5, 0.25 / 0.5]))

        let left = try row.moving(c, to: a, placement: .edge(.left))
        #expect(left.panes == [c, a, b])

        // The center swaps, keeping every size.
        let swapped = try row.moving(a, to: c, placement: .center)
        #expect(swapped.root == .split(axis: .sideBySide, children: [.pane(c), .pane(b), .pane(a)], fractions: [0.5, 0.25, 0.25]))
        #expect(throws: PaneLayoutError.samePane) { try row.moving(a, to: a, placement: .center) }
    }

    @Test func equalizeAndSetFractions() throws {
        let nested = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right).inserting(c, beside: b, edge: .right)
            .inserting(d, beside: b, edge: .bottom)
        let equal = nested.equalized()
        #expect(approx(fractions(equal), [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        #expect(approx(fractions(equal, at: [1]), [0.5, 0.5]))

        let resized = equal.settingFractions([2, 1, 1], at: [])
        #expect(approx(fractions(resized), [0.5, 0.25, 0.25]))
        // Clamped to the minimum share, and a wrong count or path is ignored.
        #expect(fractions(resized.settingFractions([1, 0, 0], at: []))[1] >= PaneLayout.minimumFraction * 0.9)
        #expect(resized.settingFractions([1, 1], at: []) == resized)
        #expect(resized.settingFractions([1, 1], at: [0]) == resized)
        #expect(resized.settingFractions([.nan, 1, 1], at: []) == resized)
    }

    @Test func neighborsFollowTheGeometry() throws {
        // [a | (b / c)] with d under the whole row: a left half, b and c the right half, d along the bottom.
        let layout = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right).inserting(c, beside: b, edge: .bottom)
        let grid = try layout.inserting(d, beside: a, edge: .bottom)
        #expect(layout.neighbor(of: b, toward: .left) == a)
        #expect(layout.neighbor(of: c, toward: .left) == a)
        #expect(layout.neighbor(of: b, toward: .bottom) == c)
        #expect(layout.neighbor(of: c, toward: .top) == b)
        #expect(layout.neighbor(of: a, toward: .left) == nil)
        #expect(layout.neighbor(of: b, toward: .top) == nil)
        // a is now stacked over d inside the left half.
        #expect(grid.neighbor(of: a, toward: .bottom) == d)
        #expect(grid.neighbor(of: d, toward: .right) == c)
        // Equal overlap and distance: the first in reading order, every time.
        for _ in 0..<20 { #expect(layout.neighbor(of: a, toward: .right) == b) }
    }

    @Test func zoomAndFocus() throws {
        let layout = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right)
        let zoomed = try layout.togglingZoom(a)
        #expect(zoomed.zoomed == a && zoomed.focused == a)
        #expect(try zoomed.togglingZoom(a).zoomed == nil)
        // Adding a pane ends the zoom so the new pane shows.
        #expect(try zoomed.inserting(c, beside: a, edge: .right).zoomed == nil)
        #expect(throws: PaneLayoutError.unknownPane) { try layout.focusing(c) }
        // Focusing the zoomed pane keeps the zoom; focusing a hidden pane ends it.
        #expect(try zoomed.focusing(a).zoomed == a)
        #expect(try zoomed.focusing(b).zoomed == nil)
    }

    @Test func retainingDropsMissingSessions() throws {
        let layout = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right).inserting(c, beside: b, edge: .bottom)
        let kept = try #require(layout.retaining([a, c]))
        #expect(kept.root == .split(axis: .sideBySide, children: [.pane(a), .pane(c)], fractions: [0.5, 0.5]))
        #expect(layout.retaining([]) == nil)
    }

    @Test func codingRoundTripsAndRepairsStoredTrees() throws {
        let layout = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right).inserting(c, beside: b, edge: .bottom)
            .settingFractions([0.7, 0.3], at: []).togglingZoom(b)
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(PaneLayout.self, from: data) == layout)

        // A tree written badly (one-child split, repeated pane, wrong fractions, unknown focus) comes back normalized.
        let id = UUID()
        let json = """
        {"id":"\(id)","focused":"\(UUID())","root":{"axis":"stacked","fractions":[5],
         "children":[{"axis":"stacked","children":[{"pane":"\(a)"},{"pane":"\(b)"},{"pane":"\(a)"}]}]}}
        """
        let repaired = try JSONDecoder().decode(PaneLayout.self, from: Data(json.utf8))
        #expect(repaired.root == .split(axis: .stacked, children: [.pane(a), .pane(b)], fractions: [0.5, 0.5]))
        #expect(repaired.focused == a)
        let empty = """
        {"id":"\(id)","root":{"axis":"stacked","children":[]}}
        """
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PaneLayout.self, from: Data(empty.utf8)) }
    }
}

/// Stored layouts: saved, replaced, deleted with their workspace, and the migration that adds them backs up first.
struct PaneLayoutStoreTests {
    @Test func layoutsRoundTripAndGoWithTheirWorkspace() throws {
        let store = try MercuryStore.inMemory()
        let workspace = Workspace(name: "w", path: "/tmp/w", kind: .folder)
        try store.save(workspace)
        let a = UUID(), b = UUID()
        var record = PaneLayoutRecord(workspaceID: workspace.id, worktreeID: nil,
                                      layout: try PaneLayout(pane: a).inserting(b, beside: a, edge: .right))
        try store.save(record)
        #expect(try store.paneLayouts() == [record])

        record.layout = record.layout.settingFractions([0.3, 0.7], at: [])
        try store.save(record)
        #expect(try store.paneLayouts().map(\.layout) == [record.layout])

        try store.deletePaneLayout(id: record.id)
        #expect(try store.paneLayouts().isEmpty)

        try store.save(record)
        try store.deleteWorkspace(id: workspace.id)
        #expect(try store.paneLayouts().isEmpty)
    }

    @Test func anUnreadableRowIsSkipped() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mercury-panes-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MercuryStore(url: url)
        let workspace = Workspace(name: "w", path: "/tmp/w", kind: .folder)
        try store.save(workspace)
        try store.save(PaneLayoutRecord(workspaceID: workspace.id, worktreeID: nil, layout: PaneLayout(pane: UUID())))
        try DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "INSERT INTO pane_layout (id, workspaceID, layout, updatedAt) VALUES (?, ?, 'not json', 0)",
                           arguments: [UUID(), workspace.id])
        }
        #expect(try store.paneLayouts().count == 1)
    }

    @Test func migratingToPaneLayoutsBacksUpFirst() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mercury-v5-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", ".backup-v5_stats"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        // A database as the previous version left it: every migration up to v5.
        let queue = try DatabaseQueue(path: url.path)
        try Migrations.migrator.migrate(queue, upTo: "v5_stats")
        try queue.close()

        let store = try MercuryStore(url: url)
        #expect(try store.paneLayouts().isEmpty)
        let backup = url.appendingPathExtension("backup-v5_stats")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try DatabaseQueue(path: backup.path).read { try !$0.tableExists("pane_layout") })
    }
}
