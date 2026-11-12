import AppKit
import Foundation
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
