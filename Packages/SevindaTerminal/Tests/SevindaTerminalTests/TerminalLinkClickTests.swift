import AppKit
import Foundation
import MetalKit
import Testing
@testable import SevindaTerminal

@Suite("Link click rules")
struct TerminalLinkClickRuleTests {
    static let link = TerminalLink(match: TerminalPathMatch(kind: .path, text: "a.md", displayText: "a.md",
                                                            segments: [.init(row: 0, columns: 0..<4)]),
                                   target: .file(TerminalFileTarget(path: "/a.md", isDirectory: false)))
    static let other = TerminalLink(match: TerminalPathMatch(kind: .path, text: "b.md", displayText: "b.md",
                                                             segments: [.init(row: 1, columns: 0..<4)]),
                                    target: .file(TerminalFileTarget(path: "/b.md", isDirectory: false)))

    private func click(_ trigger: TerminalLinkTrigger = .click, count: Int = 1, modifiers: NSEvent.ModifierFlags = [],
                       dragged: Bool = false, selectionBefore: Bool = false, selectionAfter: Bool = false,
                       reports: Bool = false, focused: Bool = true, press: TerminalLink? = link,
                       release: TerminalLink? = link) -> TerminalLinkClick.Decision {
        TerminalLinkClick(trigger: trigger, clickCount: count, modifiers: modifiers, dragged: dragged,
                          selectionWasActive: selectionBefore, selectionIsActive: selectionAfter, reportsMouse: reports,
                          paneWasFocused: focused, pressLink: press, releaseLink: release).decision
    }

    @Test("⌘-click opens at once in either mode, even when the program reads the mouse or the pane was not focused")
    func commandClick() {
        for trigger in TerminalLinkTrigger.allCases {
            #expect(click(trigger, modifiers: .command) == .openNow(Self.link))
            #expect(click(trigger, modifiers: [.command, .numericPad]) == .openNow(Self.link), "device flags do not count")
            #expect(click(trigger, modifiers: .command, reports: true) == .openNow(Self.link))
            #expect(click(trigger, modifiers: .command, focused: false) == .openNow(Self.link))
        }
    }

    @Test("a plain click opens only in Click mode, after the double-click interval")
    func plainClick() {
        #expect(click(.commandClick) == .none)
        #expect(click(.click) == .openAfterDoubleClickInterval(Self.link))
    }

    @Test("selection gestures, other modifiers, mouse reporting and a focusing click never open", arguments: [
        TerminalLinkTrigger.click, .commandClick,
    ])
    func neverOpens(_ trigger: TerminalLinkTrigger) {
        #expect(click(trigger, dragged: true) == .none)
        #expect(click(trigger, modifiers: .command, dragged: true) == .none)
        #expect(click(trigger, count: 2) == .none)
        #expect(click(trigger, count: 3) == .none)
        #expect(click(trigger, count: 2, modifiers: .command) == .none)
        #expect(click(trigger, modifiers: .shift) == .none)
        #expect(click(trigger, modifiers: [.command, .shift]) == .none)
        #expect(click(trigger, modifiers: .option) == .none)
        #expect(click(trigger, modifiers: .control) == .none)
        #expect(click(trigger, selectionBefore: true) == .none)
        #expect(click(trigger, selectionAfter: true) == .none)
        #expect(click(trigger, reports: true) == .none)
        #expect(click(trigger, focused: false) == .none)
        #expect(click(trigger, press: nil, release: nil) == .none)
        #expect(click(trigger, release: Self.other) == .none)
        #expect(click(trigger, modifiers: .command, release: nil) == .none)
    }
}

/// The real view's mouse handlers, driven with synthesized events: what SwiftTerm does with each click (selection,
/// reports to the program) must not change, and links open only as the rules say.
@Suite("Link clicks in a terminal view", .serialized)
@MainActor
struct TerminalLinkClickViewTests {
    @MainActor
    final class Harness {
        let window: NSWindow
        let view: SevindaTerminalView
        let other = NSTextField()
        var opened: [TerminalFileTarget] = []
        var input: [UInt8] = []

        init() {
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            view = SevindaTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
            window.contentView?.addSubview(view)
            window.contentView?.addSubview(other)
            view.onOpenFileLink = { [unowned self] in opened.append($0) }
            view.onInput = { [unowned self] in input += $0 }
            view.linkResolver = { $0.map { $0.text == "docs/a.md" ? TerminalFileTarget(path: "/w/docs/a.md", isDirectory: false) : nil } }
        }

        func feed(_ text: String) {
            let bytes = Array(text.utf8)
            view.feed(byteArray: bytes[...])
            view.noteOutputFed(byteCount: bytes.count)
        }

        /// The middle of the shown link, in window coordinates.
        func linkPoint() throws -> CGPoint {
            let link = try #require(view.shownLinks.first)
            let geometry = try #require(view.cellGeometry())
            let segment = try #require(link.match.segments.first)
            let rect = geometry.rect(row: segment.row - view.getTerminal().buffer.yDisp, columns: segment.columns)
            return view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint, count: Int = 1, modifiers: NSEvent.ModifierFlags = [],
                   timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: timestamp,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }

        func click(at point: CGPoint, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
            view.mouseDown(with: event(.leftMouseDown, at: point, count: count, modifiers: modifiers))
            view.mouseUp(with: event(.leftMouseUp, at: point, count: count, modifiers: modifiers))
        }

        func prepare() async throws {
            window.makeFirstResponder(view)
            feed("open docs/a.md now\r\n")
            view.scanLinksNow()
            #expect(await waitUntil(timeout: .seconds(2)) { view.shownLinks.count == 1 })
            // The pane has had the keyboard for a while.
            try await Task.sleep(for: .milliseconds(20))
        }

        func waitPastDoubleClick() async throws {
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.25))
        }
    }

    @Test("⌘-click opens; a plain click in ⌘-Click mode does nothing new")
    func commandClickMode() async throws {
        let harness = Harness()
        defer { harness.window.close() }
        try await harness.prepare()
        let point = try harness.linkPoint()
        harness.click(at: point)
        try await harness.waitPastDoubleClick()
        #expect(harness.opened.isEmpty)
        harness.click(at: point, modifiers: .command)
        #expect(harness.opened == [TerminalFileTarget(path: "/w/docs/a.md", isDirectory: false)])
    }

    @Test("Click mode: a single click opens after the double-click interval; a double click selects the word instead")
    func clickMode() async throws {
        let harness = Harness()
        defer { harness.window.close() }
        harness.view.linkTrigger = .click
        try await harness.prepare()
        let point = try harness.linkPoint()
        harness.click(at: point)
        #expect(harness.opened.isEmpty, "not before the double-click interval")
        try await harness.waitPastDoubleClick()
        #expect(harness.opened.count == 1)

        harness.click(at: point, count: 1)
        harness.click(at: point, count: 2)
        try await harness.waitPastDoubleClick()
        #expect(harness.opened.count == 1, "a double click opens nothing")
        #expect(harness.view.selectionActive, "and selects as before")

        // With a selection active, a click clears it and opens nothing.
        harness.click(at: point)
        try await harness.waitPastDoubleClick()
        #expect(harness.opened.count == 1)
        #expect(!harness.view.selectionActive)
    }

    @Test("dragging across a link selects text and opens nothing")
    func drag() async throws {
        let harness = Harness()
        defer { harness.window.close() }
        harness.view.linkTrigger = .click
        try await harness.prepare()
        let point = try harness.linkPoint()
        let end = CGPoint(x: point.x + 60, y: point.y)
        harness.view.mouseDown(with: harness.event(.leftMouseDown, at: point))
        harness.view.mouseDragged(with: harness.event(.leftMouseDragged, at: CGPoint(x: point.x + 30, y: point.y)))
        harness.view.mouseDragged(with: harness.event(.leftMouseDragged, at: end))
        harness.view.mouseUp(with: harness.event(.leftMouseUp, at: end))
        try await harness.waitPastDoubleClick()
        #expect(harness.opened.isEmpty)
        #expect(harness.view.selectionActive)
    }

    @Test("a program reading the mouse still gets plain clicks; ⌘-click opens")
    func mouseReporting() async throws {
        let harness = Harness()
        defer { harness.window.close() }
        harness.view.linkTrigger = .click
        try await harness.prepare()
        harness.feed("\u{1b}[?1000h")
        #expect(harness.view.isReportingMouse)
        let point = try harness.linkPoint()
        harness.input.removeAll()
        harness.click(at: point)
        try await harness.waitPastDoubleClick()
        #expect(harness.opened.isEmpty)
        // X10 mouse reports: ESC [ M, then button, column and row bytes; a press and a release.
        #expect(harness.input.count == 12 && harness.input.starts(with: [0x1B, 0x5B, 0x4D]))
        harness.click(at: point, modifiers: .command)
        #expect(harness.opened.count == 1)
    }

    @Test("the click that focuses a pane only focuses it")
    func focusingClick() async throws {
        let harness = Harness()
        defer { harness.window.close() }
        harness.view.linkTrigger = .click
        try await harness.prepare()
        let point = try harness.linkPoint()
        harness.window.makeFirstResponder(harness.other)
        // AppKit makes the clicked view first responder after the press was posted, before delivering it.
        let press = harness.event(.leftMouseDown, at: point, timestamp: ProcessInfo.processInfo.systemUptime - 0.01)
        harness.window.makeFirstResponder(harness.view)
        harness.view.mouseDown(with: press)
        harness.view.mouseUp(with: harness.event(.leftMouseUp, at: point))
        try await harness.waitPastDoubleClick()
        #expect(harness.opened.isEmpty)
        #expect(harness.window.firstResponder === harness.view)
        harness.click(at: point)
        try await harness.waitPastDoubleClick()
        #expect(harness.opened.count == 1, "the next click opens")
    }

    @Test("with detection off, clicks behave exactly as before")
    func disabled() async throws {
        let harness = Harness()
        defer { harness.window.close() }
        harness.view.linkTrigger = .click
        try await harness.prepare()
        let point = try harness.linkPoint()
        harness.view.linkResolver = nil
        var links: [String] = []
        harness.view.onOpenLink = { links.append($0); return true }
        harness.click(at: point)
        harness.click(at: point, modifiers: .command)
        try await harness.waitPastDoubleClick()
        #expect(harness.opened.isEmpty)
        // SwiftTerm's own ⌘-click handling is untouched; it opens only links it highlighted on hover.
        #expect(links.allSatisfy { $0.contains("docs/a.md") })
    }
}

/// The terminal's behavior with link detection on must match the behavior with it off, gesture for gesture, except for
/// opening links: same selections, same bytes sent to the program, same links SwiftTerm opens itself.
@Suite("Terminal behavior with link detection on and off", .serialized)
@MainActor
struct TerminalLinkParityTests {
    /// Row 0 holds a path, row 1 an OSC 8 link, row 2 a web link.
    static let screen = "open docs/a.md now and more words\r\n\u{1b}]8;;https://example.org/osc\u{1b}\\osc-link\u{1b}]8;;\u{1b}\\ here\r\nsee https://example.com/x ok\r\n"

    private func point(_ harness: TerminalLinkClickViewTests.Harness, row: Int, column: Int) throws -> CGPoint {
        let geometry = try #require(harness.view.cellGeometry())
        let rect = geometry.rect(row: row, columns: column..<(column + 1))
        return harness.view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    private func scroll(_ harness: TerminalLinkClickViewTests.Harness, at point: CGPoint) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
        event.location = harness.window.convertPoint(toScreen: point)
        return try #require(NSEvent(cgEvent: event))
    }

    /// Runs every gesture and records what the terminal did.
    private func record(enabled: Bool, trigger: TerminalLinkTrigger) async throws -> [String] {
        let harness = TerminalLinkClickViewTests.Harness()
        defer { harness.window.close() }
        harness.view.linkTrigger = trigger
        var log: [String] = []
        harness.view.onOpenLink = { log.append("link \($0)"); return true }
        harness.window.makeFirstResponder(harness.view)
        harness.feed(Self.screen)
        if enabled {
            harness.view.scanLinksNow()
            #expect(await waitUntil(timeout: .seconds(2)) { harness.view.shownLinks.count == 2 })
        } else {
            harness.view.linkResolver = nil
        }
        try await Task.sleep(for: .milliseconds(20))
        let view = harness.view
        let onPath = try point(harness, row: 0, column: 7)

        // Drag across the path.
        view.mouseDown(with: harness.event(.leftMouseDown, at: onPath))
        view.mouseDragged(with: harness.event(.leftMouseDragged, at: try point(harness, row: 0, column: 10)))
        view.mouseDragged(with: harness.event(.leftMouseDragged, at: try point(harness, row: 0, column: 20)))
        view.mouseUp(with: harness.event(.leftMouseUp, at: try point(harness, row: 0, column: 20)))
        log.append("drag \(view.getSelection() ?? "-")")
        // Double click, then Shift-click to extend; triple click.
        harness.click(at: onPath, count: 1)
        harness.click(at: onPath, count: 2)
        log.append("double \(view.getSelection() ?? "-")")
        harness.click(at: try point(harness, row: 0, column: 24), modifiers: .shift)
        log.append("extend \(view.getSelection() ?? "-")")
        harness.click(at: onPath, count: 1)
        harness.click(at: onPath, count: 2)
        harness.click(at: onPath, count: 3)
        log.append("triple \(view.getSelection() ?? "-")")
        // A click off any link clears the selection.
        harness.click(at: try point(harness, row: 0, column: 30))
        log.append("cleared \(view.selectionActive)")

        // ⌘-click the OSC 8 link and the web link: SwiftTerm (off) or the overlay (on) hands both to onOpenLink.
        harness.click(at: try point(harness, row: 1, column: 3), modifiers: .command)
        harness.click(at: try point(harness, row: 2, column: 10), modifiers: .command)

        // A program reading the mouse gets clicks, ⇧-clicks and the wheel, on a link or not.
        harness.feed("\u{1b}[?1000h")
        harness.input.removeAll()
        harness.click(at: onPath)
        harness.click(at: try point(harness, row: 0, column: 30))
        view.scrollWheel(with: try scroll(harness, at: onPath))
        log.append("reported \(harness.input)")
        harness.feed("\u{1b}[?1000l")

        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.25))
        log.append("files \(harness.opened.count)")
        return log
    }

    @Test("every gesture does the same with detection on and off", arguments: TerminalLinkTrigger.allCases)
    func sameBehavior(trigger: TerminalLinkTrigger) async throws {
        let off = try await record(enabled: false, trigger: trigger)
        let on = try await record(enabled: true, trigger: trigger)
        #expect(on == off)
        #expect(off.contains("link https://example.org/osc"), "OSC 8 links open as before")
        #expect(off.contains("link https://example.com/x"), "web links open as before")
        #expect(off.first { $0.hasPrefix("double ") } != "double -")
        #expect(off.first { $0.hasPrefix("reported ") } != "reported []")
    }

    @Test("the overlay follows the real Metal surface, stays below the find bar, and comes back with the tab")
    func metalAndFindBar() async throws {
        let harness = TerminalLinkClickViewTests.Harness()
        defer { harness.window.close() }
        try await harness.prepare()
        let view = harness.view
        let overlay = view.linkController.overlay
        view.setGPURendering(true)
        try #require(view.isUsingMetalRenderer, "this Mac has no Metal device")
        #expect(await waitUntil(timeout: .seconds(2)) {
            view.subviews.firstIndex(of: overlay) == view.subviews.lastIndex { $0 is MTKView }.map { $0 + 1 }
        })
        // ⌘F: the find bar draws above the overlay.
        _ = view.perform(.find)
        let bar = try #require(view.subviews.first { String(describing: type(of: $0)).contains("FindBar") })
        #expect(view.subviews.firstIndex(of: bar)! > view.subviews.firstIndex(of: overlay)!)

        // Hidden (out of the window) the Metal surface goes; shown again, it and the links come back.
        let container = try #require(view.superview)
        view.removeFromSuperview()
        #expect(!view.isUsingMetalRenderer)
        container.addSubview(view)
        #expect(view.isUsingMetalRenderer)
        #expect(await waitUntil(timeout: .seconds(2)) {
            !view.shownLinks.isEmpty
                && view.subviews.firstIndex(of: overlay) == view.subviews.lastIndex { $0 is MTKView }.map { $0 + 1 }
        })
        #expect(overlay.marks.count == view.shownLinks.count)
    }
}
