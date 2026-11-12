import CoreGraphics
import Testing
@testable import SevindaCore

/// Drop zones of a pane: four edge bands and the middle, the nearer edge in a corner, nothing outside the pane, and
/// the preview covering the half (or whole) the dragged pane would take.
struct PaneDropZoneTests {
    let size = CGSize(width: 800, height: 400)

    private func placement(_ x: CGFloat, _ y: CGFloat) -> PanePlacement? {
        PanePlacement(dropAt: CGPoint(x: x, y: y), in: size)
    }

    @Test func edgeBandsAndTheMiddle() {
        #expect(placement(10, 200) == .edge(.left))
        #expect(placement(790, 200) == .edge(.right))
        #expect(placement(400, 10) == .edge(.top))
        #expect(placement(400, 390) == .edge(.bottom))
        #expect(placement(400, 200) == .center)
        // The band ends at a quarter of the pane's length on its axis.
        #expect(placement(199, 200) == .edge(.left))
        #expect(placement(201, 200) == .center)
        #expect(placement(400, 99) == .edge(.top))
        #expect(placement(400, 101) == .center)
    }

    @Test func cornersGoToTheNearerEdgeAsAShareOfTheSize() {
        // 5 % from the left, 20 % from the top: left wins although the top is fewer points away.
        #expect(placement(40, 80) == .edge(.left))
        // 20 % from the right, 2.5 % from the bottom.
        #expect(placement(640, 390) == .edge(.bottom))
        // The exact diagonal always resolves the same way.
        for _ in 0..<10 { #expect(placement(0, 0) == .edge(.left)) }
    }

    @Test func nothingOutsideThePaneOrForAnEmptyPane() {
        #expect(placement(-1, 200) == nil)
        #expect(placement(400, 401) == nil)
        #expect(PanePlacement(dropAt: CGPoint(x: 0, y: 0), in: .zero) == nil)
        #expect(PanePlacement(dropAt: CGPoint(x: CGFloat.nan, y: 10), in: size) == nil)
    }

    @Test func previewCoversWhereThePaneLands() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 400)
        #expect(PanePlacement.edge(.left).previewRect(in: bounds) == CGRect(x: 10, y: 20, width: 400, height: 400))
        #expect(PanePlacement.edge(.right).previewRect(in: bounds) == CGRect(x: 410, y: 20, width: 400, height: 400))
        #expect(PanePlacement.edge(.top).previewRect(in: bounds) == CGRect(x: 10, y: 20, width: 800, height: 200))
        #expect(PanePlacement.edge(.bottom).previewRect(in: bounds) == CGRect(x: 10, y: 220, width: 800, height: 200))
        #expect(PanePlacement.center.previewRect(in: bounds) == bounds)
    }
}
