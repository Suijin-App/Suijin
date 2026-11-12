import AppKit
import MercuryCore
import SwiftUI

/// One split of a pane tree in a system `NSSplitView`: native thin dividers with the resize cursor and live dragging,
/// children sized by the layout's fractions. A divider drag reports the new fractions (`onResize`), a double-click on
/// a divider shares the split equally, and a window resize keeps the fractions. Each child is SwiftUI in its own
/// hosting view. SwiftUI's `HSplitView`/`VSplitView` cannot be given sizes or report them, which persisting the
/// layout needs.
struct PaneSplitView: NSViewRepresentable {
    struct Child {
        /// Stable identity of the child (its first pane), so a child keeps its hosting view across updates.
        let key: UUID
        /// Smallest size the child's panes need along the split's axis.
        let minimumLength: CGFloat
        /// The session when the child is a single pane, nil for a nested split.
        let pane: UUID?
        let content: AnyView
    }

    let axis: PaneAxis
    let fractions: [Double]
    let children: [Child]
    let onResize: ([Double]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PaneSplitContainer {
        let split = PaneSplitContainer()
        split.isVertical = axis == .sideBySide
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.setAccessibilityLabel(String(localized: "Panes"))
        update(split, coordinator: context.coordinator)
        return split
    }

    func updateNSView(_ split: PaneSplitContainer, context: Context) {
        split.isVertical = axis == .sideBySide
        update(split, coordinator: context.coordinator)
    }

    private func update(_ split: PaneSplitContainer, coordinator: Coordinator) {
        coordinator.minimumLengths = children.map(\.minimumLength)
        split.minimumLengths = coordinator.minimumLengths
        split.onResize = onResize
        split.fractions = fractions
        // Reuse each child's hosting view by key; only a child that is new gets a new one.
        var hosts: [PaneHostingView] = []
        for child in children {
            if let host = coordinator.hosts[child.key] {
                host.pane = child.pane
                host.rootView = child.content
                hosts.append(host)
            } else {
                let host = PaneHostingView(rootView: child.content)
                host.pane = child.pane
                // Its size comes from the split view, never from what the content would like.
                host.sizingOptions = []
                coordinator.hosts[child.key] = host
                hosts.append(host)
            }
        }
        let keys = Set(children.map(\.key))
        coordinator.hosts = coordinator.hosts.filter { keys.contains($0.key) }
        if split.arrangedSubviews != hosts {
            for view in split.arrangedSubviews where !hosts.contains(where: { $0 === view }) { split.removeArrangedSubview(view); view.removeFromSuperview() }
            for (index, host) in hosts.enumerated() {
                if split.arrangedSubviews.firstIndex(of: host) != index {
                    if host.superview === split { split.removeArrangedSubview(host) }
                    split.insertArrangedSubview(host, at: index)
                }
            }
        }
        split.applyFractions()
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var hosts: [UUID: PaneHostingView] = [:]
        var minimumLengths: [CGFloat] = []

        /// Keeps the panes on both sides of a divider at least their minimum size.
        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            let start = dividerIndex == 0 ? 0 : position(of: splitView.arrangedSubviews[dividerIndex], in: splitView).end
            let leading = dividerIndex < minimumLengths.count ? minimumLengths[dividerIndex] : 0
            return max(proposedMinimumPosition, start + leading)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            let next = dividerIndex + 1
            guard next < splitView.arrangedSubviews.count else { return proposedMaximumPosition }
            let end = position(of: splitView.arrangedSubviews[next], in: splitView).end
            let trailing = next < minimumLengths.count ? minimumLengths[next] : 0
            return min(proposedMaximumPosition, end - trailing)
        }

        /// A window or parent resize keeps every child's share instead of giving the whole change to one child.
        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            (splitView as? PaneSplitContainer)?.layoutByFractions()
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            (notification.object as? PaneSplitContainer)?.reportIfDragging()
        }

        private func position(of view: NSView, in split: NSSplitView) -> (start: CGFloat, end: CGFloat) {
            split.isVertical ? (view.frame.minX, view.frame.maxX) : (view.frame.minY, view.frame.maxY)
        }
    }
}

/// The hosting view of one child of a split. It names its pane when the child is a single pane, so rearranging can
/// find where each pane is on screen before and after a change (`PaneRearrangeAnimation`).
final class PaneHostingView: NSHostingView<AnyView> {
    var pane: UUID?
}

/// The split view itself: lays its children out by fractions and tells a divider drag from any other resize.
final class PaneSplitContainer: NSSplitView {
    var fractions: [Double] = []
    /// Each child's smallest length; the layout never goes below it while the split has room for all of them.
    var minimumLengths: [CGFloat] = []
    var onResize: (([Double]) -> Void)?
    private var isDraggingDivider = false

    /// Room the children share: the split's length without its dividers.
    private var available: CGFloat {
        let length = isVertical ? bounds.width : bounds.height
        return max(0, length - dividerThickness * CGFloat(max(arrangedSubviews.count - 1, 0)))
    }

    /// The children's current shares.
    private var currentFractions: [Double] {
        let total = available
        guard total > 0 else { return fractions }
        return arrangedSubviews.map { Double((isVertical ? $0.frame.width : $0.frame.height) / total) }
    }

    /// Moves the dividers to the model's fractions unless they already are there (or the user is dragging one).
    func applyFractions() {
        guard !isDraggingDivider, fractions.count == arrangedSubviews.count, available > 0 else { return }
        let current = currentFractions
        guard zip(current, fractions).contains(where: { abs($0 - $1) > 0.002 }) else { return }
        layoutByFractions()
    }

    /// Sizes every child by its fraction, raised to its minimum length with the room taken from the children above
    /// theirs (the last one takes what rounding left).
    func layoutByFractions() {
        let views = arrangedSubviews
        guard !views.isEmpty else { return }
        let shares = fractions.count == views.count ? fractions : Array(repeating: 1 / Double(views.count), count: views.count)
        let total = available
        let lengths = Self.lengths(shares: shares, minimums: minimumLengths, total: total)
        var offset: CGFloat = 0
        for (index, view) in views.enumerated() {
            let length = index == views.count - 1 ? max(0, total - offset) : lengths[index].rounded()
            view.frame = isVertical
                ? NSRect(x: offset, y: 0, width: length, height: bounds.height)
                : NSRect(x: 0, y: offset, width: bounds.width, height: length)
            offset += length + dividerThickness
        }
    }

    /// Lengths for `shares` of `total`: a child under its minimum gets it, paid for by the others in proportion to
    /// what they have above theirs. When even the minimums do not fit, the shares stand.
    static func lengths(shares: [Double], minimums: [CGFloat], total: CGFloat) -> [CGFloat] {
        var lengths = shares.map { CGFloat($0) * total }
        guard minimums.count == lengths.count, minimums.reduce(0, +) <= total else { return lengths }
        for _ in 0..<lengths.count {
            let deficit = zip(lengths, minimums).reduce(0) { $0 + max(0, $1.1 - $1.0) }
            guard deficit > 0.5 else { break }
            let spare = zip(lengths, minimums).reduce(0) { $0 + max(0, $1.0 - $1.1) }
            guard spare > 0 else { break }
            lengths = zip(lengths, minimums).map { length, minimum in
                length < minimum ? minimum : length - (length - minimum) / spare * deficit
            }
        }
        return lengths
    }

    override func layout() {
        super.layout()
        if !isDraggingDivider { layoutByFractions() }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let divider = dividerIndex(at: point) else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            // Double-click: the split shares its room equally.
            let equal = Array(repeating: 1 / Double(arrangedSubviews.count), count: arrangedSubviews.count)
            fractions = equal
            layoutByFractions()
            onResize?(equal)
            return
        }
        _ = divider
        isDraggingDivider = true
        // AppKit tracks the drag inside this call and returns when the button comes up.
        super.mouseDown(with: event)
        isDraggingDivider = false
        reportCurrent()
    }

    /// While a divider moves, the new shares go to the model (which stores them after a pause).
    func reportIfDragging() {
        if isDraggingDivider { reportCurrent() }
    }

    private func reportCurrent() {
        let current = currentFractions
        guard current.count == arrangedSubviews.count, current.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        fractions = current
        onResize?(current)
    }

    /// The divider under a point, with the few points around it that AppKit also lets the user grab.
    private func dividerIndex(at point: NSPoint) -> Int? {
        let views = arrangedSubviews
        guard views.count > 1 else { return nil }
        for index in 0..<(views.count - 1) {
            let end = isVertical ? views[index].frame.maxX : views[index].frame.maxY
            let coordinate = isVertical ? point.x : point.y
            if coordinate >= end - 3, coordinate <= end + dividerThickness + 3 { return index }
        }
        return nil
    }
}
