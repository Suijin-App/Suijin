import Foundation
import SwiftTerm
import Testing

/// Measures how fast SwiftTerm's emulator (no view, no PTY) parses a `yes`-style flood. The numbers are printed so the
/// pin decision can be revisited; the assertion only guards against a pathological regression.
@Suite("Headless throughput")
struct HeadlessThroughputTests {
    private final class SinkDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// `y` is `yes` (2,000,000 lines); the 79-character line is a full-width log line (200,000 lines, to keep debug test
    /// runs short). Both end in "\r\n", as a PTY's line discipline (onlcr) delivers them.
    @Test("flood", arguments: [("y", 2_000_000), (String(repeating: "abcdefghij", count: 8).dropLast().description, 200_000)])
    func flood(text: String, lineCount: Int) {
        let delegate = SinkDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 120, rows: 40, scrollback: 10_000))
        let chunkLines = 8 * 1024
        let line = Array((text + "\r\n").utf8)
        let chunk = [[UInt8]](repeating: line, count: chunkLines).flatMap { $0 }
        var fed = 0
        let elapsed = ContinuousClock().measure {
            while fed < lineCount {
                let lines = min(chunkLines, lineCount - fed)
                terminal.feed(buffer: chunk[0..<(lines * line.count)])
                fed += lines
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let megabytes = Double(lineCount * line.count) / 1_048_576
        print(String(format: "[bench] SwiftTerm headless, %d-byte lines: %d lines (%.2f MB) in %.3f s = %.1f MB/s, %.0f lines/s",
                     line.count, lineCount, megabytes, seconds, megabytes / seconds, Double(lineCount) / seconds))
        #expect(seconds < 300)
    }
}
