import AppKit
import Testing
@testable import Sevinda

/// Zooming and panning an image with a mouse: ⌘ or ⌥ with the wheel zooms around the pointer, a plain wheel scrolls,
/// a double-click switches between fitted and actual size, and dragging pans a zoomed image. Everything runs in a
/// window that is never shown, with events handed to the view directly, so nothing takes the user's focus.
@MainActor
struct ImageZoomTests {
    /// A 2000×1500 image in a 400×300 pane, fitted (0.2×).
    private func makeView() -> (NSWindow, CenteringScrollView) {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let scrollView = CenteringScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 32
        let imageView = PassThroughImageView()
        let image = NSImage(size: NSSize(width: 2000, height: 1500))
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        scrollView.documentView = imageView
        window.contentView = scrollView
        scrollView.magnification = scrollView.fitMagnification(for: image.size)
        return (window, scrollView)
    }

    private func wheel(_ deltaY: Int32, flags: CGEventFlags, at point: NSPoint, in window: NSWindow) -> NSEvent {
        let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)!
        cgEvent.flags = flags
        cgEvent.location = window.convertPoint(toScreen: point)
        return NSEvent(cgEvent: cgEvent)!
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    @Test func commandWheelZoomsAndPlainWheelDoesNot() {
        let (window, view) = makeView()
        let start = view.magnification
        view.scrollWheel(with: wheel(3, flags: .maskCommand, at: NSPoint(x: 200, y: 150), in: window))
        #expect(view.magnification > start * 1.2)
        let zoomed = view.magnification
        view.scrollWheel(with: wheel(-3, flags: .maskAlternate, at: NSPoint(x: 200, y: 150), in: window))
        #expect(view.magnification < zoomed)
        let before = view.magnification
        view.scrollWheel(with: wheel(3, flags: [], at: NSPoint(x: 200, y: 150), in: window))
        #expect(view.magnification == before)
    }

    @Test func doubleClickSwitchesBetweenFitAndActualSize() {
        let (window, view) = makeView()
        let fit = view.magnification
        view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 200, y: 150), clicks: 2, in: window))
        #expect(abs(view.magnification - 1) < 0.001)
        view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 200, y: 150), clicks: 2, in: window))
        #expect(abs(view.magnification - fit) < 0.001)
    }

    @Test func draggingPansAZoomedImage() {
        let (window, view) = makeView()
        view.magnification = 1
        view.contentView.scroll(to: NSPoint(x: 800, y: 600))
        let origin = view.contentView.bounds.origin
        view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 200, y: 150), in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 150, y: 120), in: window))
        view.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 150, y: 120), in: window))
        #expect(view.contentView.bounds.origin.x == origin.x + 50)
        #expect(view.contentView.bounds.origin.y == origin.y + 30)
    }

    @Test func theImageTakesNoClicks() {
        let (_, view) = makeView()
        #expect(view.documentView?.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }
}
