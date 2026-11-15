import CoreGraphics
import Foundation

/// How a split arranges its children: side by side (left to right) or stacked (top to bottom).
public enum PaneAxis: String, Codable, Hashable, Sendable {
    case sideBySide
    case stacked
}

/// A side of a pane: where a new or moved pane goes, and the direction keyboard navigation looks in.
public enum PaneEdge: String, Codable, Hashable, Sendable, CaseIterable {
    case left, right, top, bottom

    /// The split axis that places a pane on this side.
    public var axis: PaneAxis { self == .left || self == .right ? .sideBySide : .stacked }
    /// Left and top come before the pane in its split.
    var isLeading: Bool { self == .left || self == .top }
}

/// Where a dragged pane lands on another pane: beside it on one side, or in its place (the two swap).
public enum PanePlacement: Hashable, Sendable {
    case edge(PaneEdge)
    case center
}

/// One node of a pane tree: a pane showing a session, or a split of two or more nodes along one axis. `fractions`
/// holds each child's share of the split's length; they are positive and add up to 1.
public indirect enum PaneNode: Hashable, Sendable {
    case pane(UUID)
    case split(axis: PaneAxis, children: [PaneNode], fractions: [Double])
}

/// Why a pane operation was refused. The app words these for the user.
public enum PaneLayoutError: Error, Equatable, Sendable {
    /// The tab already holds `PaneLayout.maxPanes` panes.
    case full
    /// The pane is not in this layout.
    case unknownPane
    /// The session is already a pane of this layout.
    case duplicatePane
    /// A pane cannot be placed relative to itself.
    case samePane
}

/// One tab's arrangement of terminal panes: a tree of splits whose leaves are session ids, the pane with the keyboard
/// and a pane shown alone (zoomed) while the others keep their places.
///
/// Every operation is pure and returns a new layout, normalized: no split has fewer than two children, a split never
/// holds a split of its own axis (it holds that split's children instead, so dividers resize naturally), and every
/// split's fractions are positive and add up to 1.
public struct PaneLayout: Codable, Hashable, Sendable, Identifiable {
    /// Most panes a tab holds.
    public static let maxPanes = 10
    /// The smallest share a pane keeps of its split when fractions are set from outside (a divider drag).
    public static let minimumFraction = 0.02

    /// The tab's identity; it outlives any of its panes.
    public var id: UUID
    public private(set) var root: PaneNode
    /// The session of the pane that has (or last had) the keyboard; always one of the panes.
    public private(set) var focused: UUID
    /// A pane shown alone over the whole tab; the others keep their places for when it is restored.
    public private(set) var zoomed: UUID?

    /// A layout of one pane.
    public init(id: UUID = UUID(), pane: UUID) {
        self.id = id
        root = .pane(pane)
        focused = pane
    }

    /// A layout from a stored or built tree; normalized, the focus moved to the first pane when it names none of them.
    /// Nil when the tree holds no pane.
    public init?(id: UUID, root: PaneNode, focused: UUID?, zoomed: UUID?) {
        guard let root = Self.normalize(root) else { return nil }
        let panes = root.panes
        self.id = id
        self.root = root
        self.focused = focused.flatMap { panes.contains($0) ? $0 : nil } ?? panes[0]
        self.zoomed = zoomed.flatMap { panes.contains($0) ? $0 : nil }
    }

    // MARK: Reading

    /// Every pane in reading order (left to right, top to bottom, depth first).
    public var panes: [UUID] { root.panes }
    public var paneCount: Int { root.paneCount }
    public var isFull: Bool { paneCount >= Self.maxPanes }
    public func contains(_ pane: UUID) -> Bool { root.contains(pane) }

    /// Each pane's frame in a unit square (origin top left, y growing downward).
    public var frames: [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        root.collectFrames(in: CGRect(x: 0, y: 0, width: 1, height: 1), into: &result)
        return result
    }

    /// The pane next to `pane` on `edge`: among the panes touching that side, the one sharing the most length with it,
    /// then the nearest to its middle, then the first in reading order. Nil at the tab's edge.
    public func neighbor(of pane: UUID, toward edge: PaneEdge) -> UUID? {
        let frames = frames
        guard let origin = frames[pane] else { return nil }
        let epsilon = 1e-9
        var best: (id: UUID, overlap: Double, distance: Double)?
        // In reading order, and only a strictly better candidate replaces the best so far: ties go the same way
        // every time.
        for candidate in panes where candidate != pane {
            guard let frame = frames[candidate] else { continue }
            let touches: Bool
            let overlap: Double
            let distance: Double
            switch edge {
            case .left, .right:
                touches = edge == .left ? abs(frame.maxX - origin.minX) < epsilon : abs(frame.minX - origin.maxX) < epsilon
                overlap = min(frame.maxY, origin.maxY) - max(frame.minY, origin.minY)
                distance = abs(frame.midY - origin.midY)
            case .top, .bottom:
                touches = edge == .top ? abs(frame.maxY - origin.minY) < epsilon : abs(frame.minY - origin.maxY) < epsilon
                overlap = min(frame.maxX, origin.maxX) - max(frame.minX, origin.minX)
                distance = abs(frame.midX - origin.midX)
            }
            guard touches, overlap > epsilon else { continue }
            if let current = best, current.overlap > overlap + epsilon
                || (abs(current.overlap - overlap) <= epsilon && current.distance <= distance) {
                continue
            }
            best = (candidate, overlap, distance)
        }
        return best?.id
    }

    /// The split at `path` (child indices from the root), if there is one.
    public func split(at path: [Int]) -> (axis: PaneAxis, count: Int, fractions: [Double])? {
        guard case .split(let axis, let children, let fractions)? = root.node(at: path) else { return nil }
        return (axis, children.count, fractions)
    }

    // MARK: Changing

    /// Adds `pane` next to `target` on `edge`, splitting the target's room in half, and focuses it.
    public func inserting(_ pane: UUID, beside target: UUID, edge: PaneEdge) throws -> PaneLayout {
        guard !contains(pane) else { throw PaneLayoutError.duplicatePane }
        guard contains(target) else { throw PaneLayoutError.unknownPane }
        guard !isFull else { throw PaneLayoutError.full }
        var copy = self
        copy.root = Self.normalize(root.inserting(.pane(pane), beside: target, edge: edge))!
        copy.focused = pane
        copy.zoomed = nil
        return copy
    }

    /// Adds every pane of `other` next to `target` on `edge`: the group takes half of the target's room and keeps its
    /// own arrangement. The group's focused pane takes the focus. The result keeps this layout's identity.
    public func inserting(_ other: PaneLayout, beside target: UUID, edge: PaneEdge) throws -> PaneLayout {
        guard other.panes.allSatisfy({ !contains($0) }) else { throw PaneLayoutError.duplicatePane }
        guard contains(target) else { throw PaneLayoutError.unknownPane }
        guard paneCount + other.paneCount <= Self.maxPanes else { throw PaneLayoutError.full }
        var copy = self
        copy.root = Self.normalize(root.inserting(other.root, beside: target, edge: edge))!
        copy.focused = other.focused
        copy.zoomed = nil
        return copy
    }

    /// Removes a pane; its room goes to the panes of its split, in proportion. The focus moves to the pane that took
    /// most of its room when it was focused. Nil when it was the last pane.
    public func removing(_ pane: UUID) throws -> PaneLayout? {
        guard contains(pane) else { throw PaneLayoutError.unknownPane }
        guard let root = root.removing(pane).flatMap(Self.normalize) else { return nil }
        var copy = self
        if focused == pane { copy.focused = self.root.successor(ofRemoved: pane) ?? root.panes[0] }
        if zoomed == pane { copy.zoomed = nil }
        copy.root = root
        return copy
    }

    /// Moves `pane` beside `target` (it takes half of the target's room), or swaps the two (`.center`, each keeping
    /// the other's room). The moved pane keeps the focus.
    public func moving(_ pane: UUID, to target: UUID, placement: PanePlacement) throws -> PaneLayout {
        guard contains(pane), contains(target) else { throw PaneLayoutError.unknownPane }
        guard pane != target else { throw PaneLayoutError.samePane }
        switch placement {
        case .center:
            return try swapping(pane, target)
        case .edge(let edge):
            guard var copy = try removing(pane) else { throw PaneLayoutError.unknownPane }
            copy.root = Self.normalize(copy.root.inserting(.pane(pane), beside: target, edge: edge))!
            copy.focused = pane
            copy.zoomed = nil
            return copy
        }
    }

    /// Exchanges two panes' places; every size stays.
    public func swapping(_ first: UUID, _ second: UUID) throws -> PaneLayout {
        guard contains(first), contains(second) else { throw PaneLayoutError.unknownPane }
        var copy = self
        copy.root = root.mapPanes { $0 == first ? second : $0 == second ? first : $0 }
        return copy
    }

    /// Every split divides its room equally.
    public func equalized() -> PaneLayout {
        var copy = self
        copy.root = root.equalized()
        return copy
    }

    /// Sets the shares of the split at `path` (a divider moved). Values are clamped to `minimumFraction` and scaled
    /// to add up to 1; a wrong count or path changes nothing.
    public func settingFractions(_ fractions: [Double], at path: [Int]) -> PaneLayout {
        guard let current = split(at: path), current.count == fractions.count,
              fractions.allSatisfy({ $0.isFinite }) else { return self }
        var copy = self
        copy.root = root.replacingFractions(at: path[...], with: Self.normalizedFractions(fractions, count: fractions.count))
        return copy
    }

    /// Gives `pane` the focus. Focusing a pane hidden by another one's zoom ends the zoom: the keyboard is never in a
    /// pane the user cannot see.
    public func focusing(_ pane: UUID) throws -> PaneLayout {
        guard contains(pane) else { throw PaneLayoutError.unknownPane }
        var copy = self
        copy.focused = pane
        if zoomed != pane { copy.zoomed = nil }
        return copy
    }

    /// Shows `pane` alone, or restores the layout when it already is; zooming focuses it.
    public func togglingZoom(_ pane: UUID) throws -> PaneLayout {
        guard contains(pane) else { throw PaneLayoutError.unknownPane }
        var copy = self
        copy.zoomed = zoomed == pane ? nil : pane
        copy.focused = pane
        return copy
    }

    /// Only the panes in `kept` (sessions that still exist); nil when none is left.
    public func retaining(_ kept: Set<UUID>) -> PaneLayout? {
        var layout: PaneLayout? = self
        for pane in panes where !kept.contains(pane) {
            layout = layout.flatMap { try? $0.removing(pane) }
        }
        return layout
    }

    // MARK: Normalizing

    /// Drops empty splits, lifts single children, merges splits into a parent of the same axis (their fractions
    /// scaled into the parent's share), removes repeated panes and fixes fractions. Nil when no pane is left.
    static func normalize(_ node: PaneNode) -> PaneNode? {
        var seen = Set<UUID>()
        return normalize(node, seen: &seen)
    }

    private static func normalize(_ node: PaneNode, seen: inout Set<UUID>) -> PaneNode? {
        switch node {
        case .pane(let id):
            return seen.insert(id).inserted ? node : nil
        case .split(let axis, let children, let fractions):
            let shares = normalizedFractions(fractions, count: children.count)
            var flatChildren: [PaneNode] = []
            var flatFractions: [Double] = []
            for (child, share) in zip(children, shares) {
                guard let child = normalize(child, seen: &seen) else { continue }
                if case .split(let childAxis, let grandchildren, let childFractions) = child, childAxis == axis {
                    flatChildren += grandchildren
                    flatFractions += childFractions.map { $0 * share }
                } else {
                    flatChildren.append(child)
                    flatFractions.append(share)
                }
            }
            switch flatChildren.count {
            case 0: return nil
            case 1: return flatChildren[0]
            default:
                return .split(axis: axis, children: flatChildren, fractions: normalizedFractions(flatFractions, count: flatChildren.count))
            }
        }
    }

    /// `count` positive shares adding up to 1: missing, non-finite or tiny values become `minimumFraction`, equal
    /// shares when nothing usable is left.
    static func normalizedFractions(_ fractions: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        var values = (0..<count).map { index -> Double in
            let value = index < fractions.count ? fractions[index] : .nan
            return value.isFinite ? max(value, minimumFraction) : minimumFraction
        }
        let total = values.reduce(0, +)
        guard total > 0, values.contains(where: { $0 > minimumFraction }) else {
            return Array(repeating: 1 / Double(count), count: count)
        }
        values = values.map { $0 / total }
        return values
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey { case id, root, focused, zoomed }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let root = try container.decode(PaneNode.self, forKey: .root)
        guard let layout = PaneLayout(id: id, root: root, focused: try container.decodeIfPresent(UUID.self, forKey: .focused),
                                      zoomed: try container.decodeIfPresent(UUID.self, forKey: .zoomed)) else {
            throw DecodingError.dataCorruptedError(forKey: .root, in: container, debugDescription: "A pane layout without panes")
        }
        self = layout
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(root, forKey: .root)
        try container.encode(focused, forKey: .focused)
        try container.encodeIfPresent(zoomed, forKey: .zoomed)
    }
}

/// Stored as `{"pane": "<uuid>"}` or `{"axis": "sideBySide", "children": [...], "fractions": [...]}`.
extension PaneNode: Codable {
    private enum CodingKeys: String, CodingKey { case pane, axis, children, fractions }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(UUID.self, forKey: .pane) {
            self = .pane(id)
        } else {
            self = .split(axis: try container.decode(PaneAxis.self, forKey: .axis),
                          children: try container.decode([PaneNode].self, forKey: .children),
                          fractions: try container.decodeIfPresent([Double].self, forKey: .fractions) ?? [])
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let id):
            try container.encode(id, forKey: .pane)
        case .split(let axis, let children, let fractions):
            try container.encode(axis, forKey: .axis)
            try container.encode(children, forKey: .children)
            try container.encode(fractions, forKey: .fractions)
        }
    }
}

extension PaneNode {
    public var panes: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, let children, _): children.flatMap(\.panes)
        }
    }

    var paneCount: Int {
        switch self {
        case .pane: 1
        case .split(_, let children, _): children.reduce(0) { $0 + $1.paneCount }
        }
    }

    func contains(_ pane: UUID) -> Bool {
        switch self {
        case .pane(let id): id == pane
        case .split(_, let children, _): children.contains { $0.contains(pane) }
        }
    }

    func node(at path: [Int]) -> PaneNode? {
        guard let first = path.first else { return self }
        guard case .split(_, let children, _) = self, children.indices.contains(first) else { return nil }
        return children[first].node(at: Array(path.dropFirst()))
    }

    func collectFrames(in rect: CGRect, into frames: inout [UUID: CGRect]) {
        switch self {
        case .pane(let id):
            frames[id] = rect
        case .split(let axis, let children, let fractions):
            var offset = 0.0
            for (child, share) in zip(children, fractions) {
                let frame = axis == .sideBySide
                    ? CGRect(x: rect.minX + offset * rect.width, y: rect.minY, width: share * rect.width, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + offset * rect.height, width: rect.width, height: share * rect.height)
                child.collectFrames(in: frame, into: &frames)
                offset += share
            }
        }
    }

    /// The tree with `node` (a pane, or a group of panes) beside `target`. Inside a split of the edge's axis the node
    /// joins that split next to the target and takes half the target's share; anywhere else the target becomes a
    /// two-child split. Not normalized: a group split along the same axis is merged into its parent by `normalize`.
    func inserting(_ node: PaneNode, beside target: UUID, edge: PaneEdge) -> PaneNode {
        switch self {
        case .pane(let id):
            guard id == target else { return self }
            let children: [PaneNode] = edge.isLeading ? [node, self] : [self, node]
            return .split(axis: edge.axis, children: children, fractions: [0.5, 0.5])
        case .split(let axis, var children, var fractions):
            if axis == edge.axis, let index = children.firstIndex(of: .pane(target)) {
                let half = fractions[index] / 2
                fractions[index] = half
                let position = edge.isLeading ? index : index + 1
                children.insert(node, at: position)
                fractions.insert(half, at: position)
                return .split(axis: axis, children: children, fractions: fractions)
            }
            return .split(axis: axis, children: children.map { $0.inserting(node, beside: target, edge: edge) }, fractions: fractions)
        }
    }

    /// The tree without `pane`; its share goes to the rest of its split in proportion. Nil when nothing is left.
    /// Not normalized.
    func removing(_ pane: UUID) -> PaneNode? {
        switch self {
        case .pane(let id):
            return id == pane ? nil : self
        case .split(let axis, let children, let fractions):
            var kept: [PaneNode] = []
            var shares: [Double] = []
            for (child, share) in zip(children, fractions) {
                guard let child = child.removing(pane) else { continue }
                kept.append(child)
                shares.append(share)
            }
            guard !kept.isEmpty else { return nil }
            return .split(axis: axis, children: kept, fractions: shares)
        }
    }

    /// The pane that should take the focus when `pane` goes: the nearest pane of the sibling before it (the one that
    /// grows into its room), else of the sibling after it.
    func successor(ofRemoved pane: UUID) -> UUID? {
        guard case .split(_, let children, _) = self else { return nil }
        guard let index = children.firstIndex(where: { $0.contains(pane) }) else { return nil }
        if children[index] != .pane(pane) { return children[index].successor(ofRemoved: pane) }
        if index > 0 { return children[index - 1].panes.last }
        return children.count > 1 ? children[index + 1].panes.first : nil
    }

    func mapPanes(_ transform: (UUID) -> UUID) -> PaneNode {
        switch self {
        case .pane(let id): .pane(transform(id))
        case .split(let axis, let children, let fractions): .split(axis: axis, children: children.map { $0.mapPanes(transform) }, fractions: fractions)
        }
    }

    func equalized() -> PaneNode {
        switch self {
        case .pane: self
        case .split(let axis, let children, _):
            .split(axis: axis, children: children.map { $0.equalized() },
                   fractions: Array(repeating: 1 / Double(children.count), count: children.count))
        }
    }

    func replacingFractions(at path: ArraySlice<Int>, with values: [Double]) -> PaneNode {
        guard case .split(let axis, var children, let fractions) = self else { return self }
        guard let first = path.first else { return .split(axis: axis, children: children, fractions: values) }
        children[first] = children[first].replacingFractions(at: path.dropFirst(), with: values)
        return .split(axis: axis, children: children, fractions: fractions)
    }
}
