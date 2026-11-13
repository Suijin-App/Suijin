import AppKit
import Foundation
import Testing
@testable import SuijinTerminal

/// Measurements for path links, printed rather than asserted tightly: the time one scan of a full, dense screen takes
/// on the main thread (and its detection off it), and how fast long output is fed with detection on and off. Runs when `SUIJIN_PERF=1`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUIJIN_PERF"] == "1"))
struct TerminalLinkPerformanceTests {
    private func makeWindow(width: CGFloat = 1600, height: CGFloat = 1000) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: width, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return (window, window.contentView!)
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    @Test func scanTimePerPass() async throws {
        let (window, content) = makeWindow()
        defer { window.close() }
        let view = SuijinTerminalView(frame: content.bounds)
        content.addSubview(view)
        view.linkResolver = { $0.map { _ in nil } }
        // Every row full of candidates: paths with line suffixes, links, elided paths, quoted paths.
        var text = ""
        for row in 0..<view.gridSize.rows {
            text += "M Sources/Feature\(row)/View\(row).swift:\(row):4 https://example.com/\(row) …/x/\(row).md `docs/a b\(row).md` src/a\(row).ts"
            text += String(repeating: " y/z\(row).c", count: 8) + "\r\n"
        }
        let bytes = Array(text.utf8)
        view.feed(byteArray: bytes[...])
        var durations: [Duration] = []
        var detection: [Duration] = []
        for _ in 0..<200 {
            view.scanLinksNow()
            durations.append(try #require(view.lastLinkScanDuration))
            let clock = ContinuousClock()
            detection.append(clock.measure { _ = TerminalPathDetector.matches(in: view.screenRows().rows) })
        }
        detection.sort()
        durations.sort()
        let dense = (durations[durations.count / 2], durations[durations.count * 95 / 100], durations.last!)
        // A typical agent screen: some paths among prose.
        view.feed(byteArray: Array("\u{1b}[2J\u{1b}[H".utf8)[...])
        var prose = ""
        for row in 0..<view.gridSize.rows {
            prose += row % 4 == 0 ? "⏺ Update(App/Features/Files/FileTabs.swift) with 3 additions\r\n" : "  The change keeps the tree in step with the viewer and adds a test.\r\n"
        }
        view.feed(byteArray: Array(prose.utf8)[...])
        var typical: [Duration] = []
        for _ in 0..<200 {
            view.scanLinksNow()
            typical.append(try #require(view.lastLinkScanDuration))
        }
        typical.sort()
        print("PERF detection off the main thread, dense: median \(detection[100]) p95 \(detection[190])")
        print("PERF main-thread scan grid \(view.gridSize.cols)x\(view.gridSize.rows): dense median \(dense.0) p95 \(dense.1) max \(dense.2); typical median \(typical[100]) p95 \(typical[190]) max \(typical.last!)")
        #expect(dense.0 < .milliseconds(2))
    }

    /// Feeds `bytes` through a session and the shared scheduler, as a running program's output arrives.
    private func feed(_ bytes: [UInt8], label: String, links: Bool) async throws -> String {
        let (window, content) = makeWindow(width: 1200, height: 800)
        defer { window.close() }
        let engine = ScriptedEngine()
        let session = TerminalSession(engine: engine)
        session.view.frame = content.bounds
        content.addSubview(session.view)
        session.view.setGPURendering(true)
        if links { session.view.linkResolver = { $0.map { _ in nil } } }
        try await session.start(launch("/bin/echo"))
        try await Task.sleep(for: .milliseconds(300))
        let scansBefore = session.view.linkScanCount
        let cpuBefore = Self.cpuSeconds()
        let start = ContinuousClock.now
        var worstGap: Duration = .zero
        var last = ContinuousClock.now
        // Like a pipe: 64 KB at a time while the reader keeps up.
        var offset = 0
        while session.fedByteCount < bytes.count {
            if offset < bytes.count, session.pendingByteCount < 1024 * 1024 {
                let end = min(bytes.count, offset + 64 * 1024)
                engine.emit(Array(bytes[offset..<end]))
                offset = end
            }
            try await Task.sleep(for: .milliseconds(1))
            let now = ContinuousClock.now
            worstGap = max(worstGap, now - last)
            last = now
        }
        let elapsed = ContinuousClock.now - start
        let cpu = Self.cpuSeconds() - cpuBefore
        var result = "\(label) links \(links ? "on " : "off"): \(bytes.count / 1_000_000) MB in \(elapsed), \(String(format: "%.0f", Double(bytes.count) / 1_000_000 / (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))) MB/s, CPU \(String(format: "%.2f", cpu)) s, worst main-thread gap \(worstGap)"
        result += ", scans during output \(session.view.linkScanCount - scansBefore)"
        #expect(session.view.linkScanCount - scansBefore <= 1, "one scan at most, as the output ends")
        return result
    }

    @Test func feedThroughput() async throws {
        let yes = Array(String(repeating: "y\r\n", count: 50_000_000 / 3).utf8)
        var log: [UInt8] = []
        var index = 0
        while log.count < 50_000_000 {
            log += Array("[\(index)/99999] Compiling Sources/Module\(index % 40)/File\(index).swift:\(index % 900):4 warning: unused\r\n".utf8)
            index += 1
        }
        var lines: [String] = []
        for round in 0..<2 {
            for links in [false, true] {
                lines.append(try await feed(yes, label: "yes #\(round)", links: links))
                lines.append(try await feed(log, label: "build log #\(round)", links: links))
            }
        }
        for line in lines { print("PERF feed " + line) }
    }
}
