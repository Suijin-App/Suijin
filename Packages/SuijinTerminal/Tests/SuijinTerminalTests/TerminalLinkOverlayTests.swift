import AppKit
import Foundation
import MetalKit
import Testing
@testable import SuijinTerminal

@Suite("Link overlay geometry")
struct TerminalCellGeometryTests {
    let geometry = TerminalCellGeometry(cellSize: CGSize(width: 8, height: 16), viewHeight: 160, baselineOffset: 4,
                                        underlinePosition: -2, scale: 2)

    @Test("cells map to rects counted from the top")
    func rects() {
        #expect(geometry.rect(row: 0, columns: 2..<5) == CGRect(x: 16, y: 144, width: 24, height: 16))
        #expect(geometry.rect(row: 9, columns: 0..<1) == CGRect(x: 0, y: 0, width: 8, height: 16))
    }

    @Test("the underline sits below the baseline, inside the cell, on whole pixels")
    func underline() {
        let thin = geometry.underline(row: 0, columns: 2..<5, thickness: 1)
        #expect(thin == CGRect(x: 16, y: 145, width: 24, height: 1))
        let thick = geometry.underline(row: 0, columns: 2..<5, thickness: 2)
        #expect(thick.maxY == thin.maxY && thick.height == 2)
        // A font whose underline would fall below the cell stays inside it.
        let low = TerminalCellGeometry(cellSize: CGSize(width: 8, height: 16), viewHeight: 160, baselineOffset: 1,
                                       underlinePosition: -3, scale: 2)
        #expect(low.underline(row: 0, columns: 0..<1, thickness: 2).minY == 144)
    }

    @Test("points map back to cells; outside the grid is nil")
    func cells() {
        #expect(geometry.cell(at: CGPoint(x: 17, y: 150), rows: 10, columns: 80)! == (0, 2))
        #expect(geometry.cell(at: CGPoint(x: 1, y: 1), rows: 10, columns: 80)! == (9, 0))
        #expect(geometry.cell(at: CGPoint(x: 1, y: 1), rows: 5, columns: 80) == nil)
        #expect(geometry.cell(at: CGPoint(x: 900, y: 150), rows: 10, columns: 80) == nil)
    }
}

@Suite("Link scan timing")
struct TerminalLinkScanTimingTests {
    @Test("a continuous flood never makes a scan due while it flows")
    func flood() {
        var timing = TerminalLinkScanTiming()
        var time: TimeInterval = 100
        for _ in 0..<1000 {
            timing.noteChange(at: time, bytes: 4096)
            #expect(timing.dueTime! > time)
            time += 0.005
        }
        // Once it stops, the scan follows the quiet period.
        #expect(timing.dueTime! == time - 0.005 + timing.quietPeriod)
    }

    @Test("output that only trickles in is scanned at the latest after the maximum delay")
    func trickle() {
        var timing = TerminalLinkScanTiming()
        for step in 0..<20 { timing.noteChange(at: 100 + Double(step) * 0.08, bytes: 120) }
        #expect(timing.dueTime == 100 + timing.maximumDelay)
        timing.scanned()
        #expect(timing.dueTime == nil)
    }
}

@Suite("Link overlay in a terminal view", .serialized)
@MainActor
struct TerminalLinkViewTests {
    private func makeView() -> (NSWindow, SuijinTerminalView) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = SuijinTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        window.contentView?.addSubview(view)
        return (window, view)
    }

    private func feed(_ view: SuijinTerminalView, _ text: String) {
        let bytes = Array(text.utf8)
        view.feed(byteArray: bytes[...])
        view.noteOutputFed(byteCount: bytes.count)
    }

    @Test("verified paths and web links are shown; missing paths and elided paths are not")
    func scan() async throws {
        let (window, view) = makeView()
        defer { window.close() }
        var asked: [String] = []
        view.linkResolver = { matches in
            asked += matches.map(\.text)
            return matches.map { $0.text == "/tmp/x.md" ? TerminalFileTarget(path: "/tmp/x.md", isDirectory: false, line: $0.line) : nil }
        }
        feed(view, "see /tmp/x.md:3 and https://example.com/a\r\nmissing/b.md and …/cut/c.swift\r\n")
        view.scanLinksNow()
        #expect(await waitUntil(timeout: .seconds(2)) { view.shownLinks.count == 2 })
        let links = view.shownLinks
        #expect(links.map(\.match.displayText) == ["/tmp/x.md:3", "https://example.com/a"])
        #expect(links.first?.target == .file(TerminalFileTarget(path: "/tmp/x.md", isDirectory: false, line: 3)))
        #expect(links.first?.match.segments == [.init(row: 0, columns: 4..<15)])
        #expect(!asked.contains("…/cut/c.swift"), "elided paths are never resolved")
        #expect(asked.contains("missing/b.md"))
        #expect(view.lastLinkScanDuration! < .milliseconds(20))

        // Clearing the screen drops the links without waiting for a scan.
        feed(view, "\u{1b}[2J\u{1b}[H")
        #expect(await waitUntil(timeout: .seconds(2)) { view.shownLinks.isEmpty })
    }

    @Test("nothing is scanned while output streams; one scan follows the pause")
    func debounce() async throws {
        let (window, view) = makeView()
        defer { window.close() }
        view.linkResolver = { $0.map { _ in nil } }
        #expect(await waitUntil(timeout: .seconds(2)) { view.linkScanCount == 1 }, "the first scan of an empty screen")
        let before = view.linkScanCount
        for index in 0..<1000 {
            feed(view, "line \(index) of a long build log at Sources/App/File\(index).swift:\(index)\r\n")
            if index % 10 == 0 { try await Task.sleep(for: .milliseconds(5)) }
            if index % 100 == 0 { #expect(view.linkScanCount == before, "scanned during output at chunk \(index)") }
        }
        #expect(view.linkScanCount == before)
        #expect(await waitUntil(timeout: .seconds(2)) { view.linkScanCount == before + 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(view.linkScanCount == before + 1, "one scan, not one per chunk")
    }

    @Test("turned off, nothing is scanned or drawn")
    func disabled() async throws {
        let (window, view) = makeView()
        defer { window.close() }
        feed(view, "see /tmp/x.md\r\n")
        view.scanLinksNow()
        try await Task.sleep(for: .milliseconds(200))
        #expect(view.linkScanCount == 0 && view.shownLinks.isEmpty)
        view.linkResolver = { $0.map { TerminalFileTarget(path: $0.text, isDirectory: false) } }
        #expect(await waitUntil(timeout: .seconds(2)) { view.shownLinks.count == 1 })
        view.linkResolver = nil
        #expect(view.shownLinks.isEmpty)
    }

    @Test("the overlay takes no clicks and stays above the Metal surface")
    func overlayPlacement() async throws {
        let (window, view) = makeView()
        defer { window.close() }
        let overlay = view.linkController.overlay
        #expect(overlay.hitTest(NSPoint(x: 10, y: 10)) == nil)
        let surface = MTKView(frame: view.bounds)
        view.addSubview(surface, positioned: .below, relativeTo: nil)
        #expect(await waitUntil(timeout: .seconds(1)) {
            view.subviews.firstIndex(of: overlay) == view.subviews.firstIndex(of: surface).map { $0 + 1 }
        })
        #expect(view.subviews.last { $0 is TerminalLinkOverlay || String(describing: type(of: $0)) == "CaretView" } !== overlay,
                "below the caret")
        #expect(view.hitTest(NSPoint(x: 200, y: 150)) === view)
    }

    @Test("a wrapped path is underlined on each row")
    func wrapped() async throws {
        let (window, view) = makeView()
        defer { window.close() }
        view.linkResolver = { $0.map { TerminalFileTarget(path: $0.text, isDirectory: false) } }
        let columns = view.gridSize.cols
        let path = "/" + String(repeating: "a", count: columns) + "/b.md"
        feed(view, "x \(path)\r\n")
        view.scanLinksNow()
        #expect(await waitUntil(timeout: .seconds(2)) { view.shownLinks.first?.match.text == path })
        #expect(view.shownLinks.first?.match.segments.map(\.row) == [0, 1])
        #expect(view.linkController.overlay.marks.first?.underlines.count == 2)
    }
}
