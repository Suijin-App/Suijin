import CoreGraphics

/// Where a pane dragged over another one lands, from the pointer's place in the target pane. The pane is divided into
/// five zones: a band along each edge (`edgeBand` of the pane's width or height) places the dragged pane on that side,
/// and the middle swaps the two. Where two bands meet (a corner) the nearer edge wins, measured as a share of the
/// pane's size so a wide pane and a tall pane behave the same.
extension PanePlacement {
    /// The share of a pane's width (left and right) or height (top and bottom) each edge band covers.
    public static let edgeBand = 0.25

    /// The placement for a pointer at `point` in a pane of `size` (origin top left, y growing downward). Nil when the
    /// point is outside the pane or the pane has no area.
    public init?(dropAt point: CGPoint, in size: CGSize) {
        guard let nearest = PaneEdge.nearest(to: point, in: size) else { return nil }
        self = nearest.distance < Self.edgeBand ? .edge(nearest.edge) : .center
    }

    /// The part of the target pane (`bounds`, origin top left) the dragged pane would take: the half on the placement's
    /// side, or the whole pane for a swap. What the drop preview shows.
    public func previewRect(in bounds: CGRect) -> CGRect {
        switch self {
        case .center:
            return bounds
        case .edge(let edge):
            let halfWidth = bounds.width / 2
            let halfHeight = bounds.height / 2
            switch edge {
            case .left: return CGRect(x: bounds.minX, y: bounds.minY, width: halfWidth, height: bounds.height)
            case .right: return CGRect(x: bounds.minX + halfWidth, y: bounds.minY, width: halfWidth, height: bounds.height)
            case .top: return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: halfHeight)
            case .bottom: return CGRect(x: bounds.minX, y: bounds.minY + halfHeight, width: bounds.width, height: halfHeight)
            }
        }
    }
}

/// Where a tab dragged over a pane lands: a tab has no place to swap, so the whole pane is divided into four zones,
/// one per edge, and the edge nearest to the pointer takes the drop.
extension PaneEdge {
    /// The edge nearest to a pointer at `point` in a pane of `size` (origin top left, y growing downward). Nil when
    /// the point is outside the pane or the pane has no area.
    public init?(nearestTo point: CGPoint, in size: CGSize) {
        guard let nearest = Self.nearest(to: point, in: size) else { return nil }
        self = nearest.edge
    }

    /// The nearest edge and the pointer's distance to it as a share of the pane's width or height, so a wide pane and
    /// a tall pane behave the same.
    static func nearest(to point: CGPoint, in size: CGSize) -> (edge: PaneEdge, distance: Double)? {
        guard size.width > 0, size.height > 0, point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
        let x = Double(point.x / size.width)
        let y = Double(point.y / size.height)
        // In this order, so ties (the exact diagonal of a corner, the middle) always resolve the same way.
        let distances: [(edge: PaneEdge, distance: Double)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        var nearest = distances[0]
        for candidate in distances.dropFirst() where candidate.distance < nearest.distance { nearest = candidate }
        return nearest
    }
}
