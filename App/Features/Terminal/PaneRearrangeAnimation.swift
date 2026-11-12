import AppKit
import QuartzCore

/// Slides the panes of a split tab from their old places to their new ones after a rearrangement (a drop, a Move Pane
/// command). The nested split views are rebuilt in AppKit, which cannot animate a view from one split view into
/// another; so every pane's place on screen is noted before the change, and once the new layout is laid out each
/// pane's layer is animated from its old place and size to the new one. Only the layers' transforms animate: the views
/// already sit where they belong, and the terminal views are moved into their new containers, never recreated, so the
/// sessions and their scrollback stay as they are.
@MainActor
enum PaneRearrangeAnimation {
    static let duration: TimeInterval = 0.25
    static let animationKey = "paneRearrange"

    /// Each pane's frame in window coordinates, for the panes of the split tab on screen.
    static func paneFrames(in window: NSWindow) -> [UUID: NSRect] {
        var frames: [UUID: NSRect] = [:]
        for host in paneHosts(in: window) {
            guard let pane = host.pane else { continue }
            frames[pane] = host.convert(host.bounds, to: nil)
        }
        return frames
    }

    /// Animates every pane whose place changed from its frame in `before` (window coordinates) to where it is now.
    /// Returns the panes it animated.
    @discardableResult
    static func animate(from before: [UUID: NSRect], in window: NSWindow) -> Set<UUID> {
        window.contentView?.layoutSubtreeIfNeeded()
        var animated = Set<UUID>()
        for host in paneHosts(in: window) {
            guard let pane = host.pane, let old = before[pane], let superview = host.superview, let layer = host.layer else { continue }
            let new = host.frame
            let from = superview.convert(old, from: nil)
            guard new.width > 1, new.height > 1, from.width > 1, from.height > 1 else { continue }
            let moved = abs(from.minX - new.minX) > 0.5 || abs(from.minY - new.minY) > 0.5
                || abs(from.width - new.width) > 0.5 || abs(from.height - new.height) > 0.5
            guard moved else { continue }
            // A transform that puts the layer (at its new frame) over its old frame, scaled about its anchor point.
            let anchor = layer.anchorPoint
            let tx = (from.minX + anchor.x * from.width) - (new.minX + anchor.x * new.width)
            let ty = (from.minY + anchor.y * from.height) - (new.minY + anchor.y * new.height)
            let transform = CATransform3DScale(CATransform3DMakeTranslation(tx, ty, 0), from.width / new.width, from.height / new.height, 1)
            let animation = CASpringAnimation(perceptualDuration: duration, bounce: 0)
            animation.keyPath = "transform"
            animation.fromValue = NSValue(caTransform3D: transform)
            animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            animation.duration = animation.settlingDuration
            layer.add(animation, forKey: animationKey)
            animated.insert(pane)
        }
        return animated
    }

    /// The hosting views of single panes in the window's split tab.
    private static func paneHosts(in window: NSWindow) -> [PaneHostingView] {
        var hosts: [PaneHostingView] = []
        func visit(_ view: NSView) {
            if let host = view as? PaneHostingView, host.pane != nil {
                hosts.append(host)
                return
            }
            // Lists and text never hold panes; skipping them keeps the walk short.
            if view is NSTableView || view is NSTextView { return }
            view.subviews.forEach(visit)
        }
        if let content = window.contentView { visit(content) }
        return hosts
    }
}

extension AppModel {
    /// Runs a change of a split tab's layout and slides its panes to their new places once it is on screen. No
    /// animation without a window, with Reduce Motion on, or when no pane is on screen.
    @discardableResult
    func rearrangePanes<T>(_ change: () throws -> T) rethrows -> T {
        guard let window = mainWindow, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return try change()
        }
        let before = PaneRearrangeAnimation.paneFrames(in: window)
        let result = try change()
        guard !before.isEmpty else { return result }
        // After SwiftUI has applied the new layout to the split views (at the end of this turn of the run loop).
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            PaneRearrangeAnimation.animate(from: before, in: window)
        }
        return result
    }
}
