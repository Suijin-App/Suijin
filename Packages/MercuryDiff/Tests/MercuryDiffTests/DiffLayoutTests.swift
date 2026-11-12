import Foundation
import MercuryGit
import Testing
@testable import MercuryDiff

struct DiffLayoutTests {
    @Test func rowsCarryKindsAndLineNumbers() {
        let layout = DiffLayout(diff: Fixtures.swiftDiff)
        #expect(layout.rows.map(\.kind) == [
            .hunkHeader, .context, .deleted, .added, .context, .added, .context, .noNewlineMarker,
            .hunkHeader, .deleted, .added, .context,
        ])
        #expect(layout.rows.map(\.oldLine) == [nil, 1, 2, nil, 3, nil, 4, nil, nil, 40, nil, 41])
        #expect(layout.rows.map(\.newLine) == [nil, 1, nil, 2, 3, 4, 5, nil, nil, nil, 41, 42])
        #expect(layout.maxLineNumber == 42)
    }

    @Test func rowRangesSliceTheDocumentText() {
        let layout = DiffLayout(diff: Fixtures.swiftDiff)
        let text = layout.text as NSString
        #expect(text.substring(with: layout.rows[0].range) == "@@ -1,4 +1,5 @@ struct App")
        #expect(text.substring(with: layout.rows[2].range) == "let name = \"old\"")
        #expect(text.substring(with: layout.rows[7].range) == "No newline at end of file")
        #expect(!layout.text.hasSuffix("\n"))
        // Rows are contiguous: each starts one newline after the previous ends.
        for (a, b) in zip(layout.rows, layout.rows.dropFirst()) { #expect(b.range.location == NSMaxRange(a.range) + 1) }
    }

    @Test func changedRowsGetBackgroundsAndContextDoesNot() {
        let layout = DiffLayout(diff: Fixtures.swiftDiff)
        for row in layout.rows {
            let background = DiffTheme.rowBackground(row.kind)
            switch row.kind {
            case .added: #expect(background === DiffTheme.addedBackground)
            case .deleted: #expect(background === DiffTheme.deletedBackground)
            case .hunkHeader: #expect(background === DiffTheme.hunkBackground)
            case .padding: #expect(background === DiffTheme.paddingBackground)
            case .context, .noNewlineMarker: #expect(background == nil)
            }
        }
    }

    @Test func rowLookupCoversEveryCharacterIncludingNewlines() {
        let layout = DiffLayout(diff: Fixtures.swiftDiff)
        for (index, row) in layout.rows.enumerated() {
            #expect(layout.rowIndex(at: row.range.location) == index)
            #expect(layout.rowIndex(at: NSMaxRange(row.range)) == index) // its newline
        }
        #expect(layout.rowIndex(at: -1) == nil)
    }

    @Test func sidesReconstructOldAndNewFiles() {
        let layout = DiffLayout(diff: Fixtures.swiftDiff)
        #expect(layout.oldSideText == "import Foundation\nlet name = \"old\"\n/* begin\nfunc run() {}\nreturn 1\n}")
        #expect(layout.newSideText == "import Foundation\nlet name = \"new\"\n/* begin\n   end */\nfunc run() {}\nreturn 2\n}")
    }

    @Test func sideSpansMapBackToDiffRows() async {
        let layout = DiffLayout(diff: Fixtures.swiftDiff)
        let old = await SyntaxHighlighter.highlight(layout.oldSideText, language: "swift")
        let new = await SyntaxHighlighter.highlight(layout.newSideText, language: "swift")
        let spans = layout.documentSpans(oldSide: old, newSide: new)
        let text = layout.text as NSString
        func tokens(inRow index: Int) -> [(String, TokenKind)] {
            let row = layout.rows[index].range
            return spans.filter { NSIntersectionRange($0.range, row).length > 0 }
                .map { (text.substring(with: $0.range), $0.token) }
        }
        #expect(tokens(inRow: 2).contains { $0.1 == .string && $0.0.contains("old") })
        #expect(tokens(inRow: 3).contains { $0.1 == .string && $0.0.contains("new") })
        // The block comment opened in a context row is still a comment on the added row that closes it.
        #expect(tokens(inRow: 5).contains { $0 == ("   end */", .comment) })
        #expect(tokens(inRow: 0).isEmpty) // hunk header
        for span in spans { #expect(NSMaxRange(span.range) <= text.length) }
    }

    @Test func binaryDiffHasNoRows() {
        let layout = DiffLayout(diff: FileDiff(oldPath: "a.png", newPath: "a.png", isBinary: true))
        #expect(layout.rows.isEmpty)
        #expect(layout.text.isEmpty)
        #expect(layout.rowIndex(at: 0) == nil)
    }

    @Test func fiveThousandLineLayoutIsFast() {
        let diff = Fixtures.largeSwiftDiff(lineCount: 5_000)
        let clock = ContinuousClock()
        var layout: DiffLayout?
        let elapsed = clock.measure { layout = DiffLayout(diff: diff) }
        #expect(layout?.rows.count == 5_100) // 5,000 lines + 100 hunk headers
        // Generous for debug builds and loaded CI machines; measured around 10-20 ms locally.
        #expect(elapsed < .milliseconds(500), "DiffLayout took \(elapsed)")
    }
}
