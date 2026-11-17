import AppKit

/// A test window that stays off every screen, so the app tests run without covering the developer's display. It
/// starts there, and it is not moved back: AppKit otherwise brings a titled window onto a screen when it is ordered
/// front, which undoes a plain `setFrameOrigin` to a far-away point.
///
/// Windows that a caller captures with `screencapture -l` (Liquid Glass does not draw into `cacheDisplay`) have to be
/// on screen and keep using `NSWindow`.
final class OffscreenWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
