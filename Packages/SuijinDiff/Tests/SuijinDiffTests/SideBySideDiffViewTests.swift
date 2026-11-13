import AppKit
import SuijinGit
import Testing
@testable import SuijinDiff

@MainActor
struct SideBySideDiffViewTests {
    private func window(for view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.layoutIfNeeded()
        return window
    }

    @Test func columnsHaveEqualHeightsAndScrollTogetherVertically() {
        let view = SideBySideDiffView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        let window = window(for: view, size: view.frame.size)
        defer { window.close() }
        view.setDiff(Fixtures.largeSwiftDiff(lineCount: 600), language: nil)
        window.displayIfNeeded()
        #expect(view.left.layout.rows.count == view.right.layout.rows.count)
        #expect(abs(view.left.textView.frame.height - view.right.textView.frame.height) < 0.5)
        #expect(!view.left.wrapsLines && !view.right.wrapsLines)
        #expect(view.left.gutter.columns == .old && view.right.gutter.columns == .new)

        view.right.textView.scroll(NSPoint(x: 0, y: 3_000))
        #expect(view.left.scrollView.contentView.bounds.origin.y == view.right.scrollView.contentView.bounds.origin.y)
        view.left.textView.scroll(NSPoint(x: 0, y: 1_200))
        #expect(view.right.scrollView.contentView.bounds.origin.y == view.left.scrollView.contentView.bounds.origin.y)
        // Rows at the same index are at the same height far down the document.
        let row = view.left.layout.rows.count - 3
        #expect(view.left.rowFrame(row) != nil)
        #expect(abs((view.left.rowFrame(row)?.minY ?? -1) - (view.right.rowFrame(row)?.minY ?? -2)) < 0.5)
    }

    @Test func horizontalScrollingIsIndependent() {
        let long = String(repeating: "wide ", count: 120)
        let diff = FileDiff(oldPath: "a", newPath: "a", hunks: [
            DiffHunk(header: "@@ -1 +1 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: [
                DiffLine(kind: .deleted, text: "short", oldLine: 1, newLine: nil),
                DiffLine(kind: .added, text: long, oldLine: nil, newLine: 1),
            ]),
        ])
        let view = SideBySideDiffView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let window = window(for: view, size: view.frame.size)
        defer { window.close() }
        view.setDiff(diff, language: nil)
        window.displayIfNeeded()
        // The long line does not wrap: the right text view is wider than its column.
        #expect(view.right.textView.frame.width > view.right.scrollView.contentSize.width + 100)
        #expect(view.right.textView.frame.height < 100)
        view.right.textView.scroll(NSPoint(x: 400, y: 0))
        #expect(view.right.scrollView.contentView.bounds.origin.x > 0)
        #expect(view.left.scrollView.contentView.bounds.origin.x == 0)
    }

    @Test func wordChangesBecomeBackgroundMarks() throws {
        let view = SideBySideDiffView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        view.setDiff(Fixtures.swiftDiff, language: nil)
        let layoutManager = try #require(view.right.textView.textLayoutManager)
        var marked: [NSRange] = []
        layoutManager.enumerateRenderingAttributes(from: layoutManager.documentRange.location, reverse: false) { manager, attributes, range in
            if attributes[.backgroundColor] != nil {
                let start = manager.offset(from: manager.documentRange.location, to: range.location)
                marked.append(NSRange(location: start, length: manager.offset(from: range.location, to: range.endLocation)))
            }
            return true
        }
        let text = view.right.layout.text as NSString
        #expect(marked.map { text.substring(with: $0) }.contains("new"))
    }

    /// A 5,000-line diff in two columns: full layout of both columns, then scroll steps through it.
    @Test func largeDiffStaysFast() async {
        let diff = Fixtures.largeSwiftDiff(lineCount: 5_000)
        let view = SideBySideDiffView(frame: NSRect(x: 0, y: 0, width: 1400, height: 800))
        let window = window(for: view, size: view.frame.size)
        defer { window.close() }
        let clock = ContinuousClock()
        let load = clock.measure {
            view.setDiff(diff, language: nil)
            window.displayIfNeeded()
        }
        var steps: [Duration] = []
        let height = view.right.textView.frame.height
        for step in 1...40 {
            let y = height * CGFloat(step) / 41
            steps.append(clock.measure {
                view.right.textView.scroll(NSPoint(x: 0, y: y))
                window.displayIfNeeded()
            })
        }
        let highlightStart = clock.now
        view.setDiff(diff, language: "swift")
        await view.highlightingCompleted()
        let highlight = clock.now - highlightStart
        let sorted = steps.sorted()
        let average = steps.reduce(.zero, +) / steps.count
        print("[side-by-side] 5,000 lines: load+first display \(load), scroll step avg \(average) p95 \(sorted[37]) max \(sorted[39]), highlight+apply \(highlight)")
        #expect(load < .milliseconds(1_500))
        #expect(average < .milliseconds(50))
        // Background work (two tree-sitter parses) that never blocks scrolling; generous so a loaded machine does not fail it.
        #expect(highlight < .seconds(12))
    }
}
