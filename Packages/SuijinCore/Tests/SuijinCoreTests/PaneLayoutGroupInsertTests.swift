import Foundation
import Testing
@testable import SuijinCore

/// Adding a whole group of panes (another tab's layout) beside a pane: the group keeps its arrangement, takes half of
/// the target's room, and the limit and the no-duplicates rule hold for the sum.
struct PaneLayoutGroupInsertTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    private func approx(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    /// [c | d] with c taking 70 %, d focused.
    private func group() throws -> PaneLayout {
        try PaneLayout(pane: c).inserting(d, beside: c, edge: .right).settingFractions([0.7, 0.3], at: [])
    }

    @Test func aGroupAcrossTheAxisNestsWithItsOwnShares() throws {
        let merged = try PaneLayout(pane: a).inserting(try group(), beside: a, edge: .bottom)
        #expect(merged.root == .split(axis: .stacked,
                                      children: [.pane(a), .split(axis: .sideBySide, children: [.pane(c), .pane(d)], fractions: [0.7, 0.3])],
                                      fractions: [0.5, 0.5]))
        #expect(try PaneLayout(pane: a).inserting(try group(), beside: a, edge: .top).panes == [c, d, a])
    }

    @Test func aGroupAlongTheAxisJoinsTheSplitAndKeepsItsProportions() throws {
        let base = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right)
        let merged = try base.inserting(try group(), beside: a, edge: .right)
        #expect(merged.panes == [a, c, d, b])
        guard case .split(.sideBySide, let children, let fractions) = merged.root else {
            Issue.record("The group was not merged into the row")
            return
        }
        #expect(children.count == 4)
        // a keeps half of its old half; the group takes the other half, 70 / 30 inside it.
        #expect(approx(fractions, [0.25, 0.175, 0.075, 0.5]))
        #expect(try base.inserting(try group(), beside: a, edge: .left).panes == [c, d, a, b])
    }

    @Test func theGroupsFocusedPaneTakesTheFocusAndAZoomEnds() throws {
        let base = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right).togglingZoom(a)
        #expect(base.zoomed == a)
        let merged = try base.inserting(try group().focusing(c), beside: a, edge: .right)
        #expect(merged.focused == c)
        #expect(merged.zoomed == nil)
        #expect(merged.id == base.id)
    }

    @Test func theSumHoldsTenPanesAtMostWithoutDuplicatesBesideAKnownPane() throws {
        var seven = PaneLayout(pane: a)
        var last = a
        for _ in 1..<7 {
            let next = UUID()
            seven = try seven.inserting(next, beside: last, edge: .right)
            last = next
        }
        var three = PaneLayout(pane: c)
        three = try three.inserting(d, beside: c, edge: .bottom).inserting(e, beside: d, edge: .bottom)
        #expect(try seven.inserting(three, beside: a, edge: .bottom).paneCount == 10)
        let four = try three.inserting(UUID(), beside: c, edge: .right)
        #expect(throws: PaneLayoutError.full) { try seven.inserting(four, beside: a, edge: .bottom) }
        #expect(throws: PaneLayoutError.unknownPane) { try seven.inserting(three, beside: UUID(), edge: .left) }
        let overlapping = try PaneLayout(pane: a).inserting(c, beside: a, edge: .right)
        #expect(throws: PaneLayoutError.duplicatePane) { try overlapping.inserting(three, beside: a, edge: .left) }
    }

    @Test func aMergedLayoutSurvivesCoding() throws {
        let merged = try PaneLayout(pane: a).inserting(b, beside: a, edge: .right).inserting(try group(), beside: b, edge: .bottom)
        let decoded = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(merged))
        #expect(decoded == merged)
    }
}
