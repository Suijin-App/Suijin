import Foundation
import SevindaGit
import Testing
@testable import SevindaDiff

struct SideBySideLayoutTests {
    private func hunk(_ lines: [DiffLine]) -> FileDiff {
        FileDiff(oldPath: "f.swift", newPath: "f.swift", hunks: [
            DiffHunk(header: "@@ -1 +1 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: lines),
        ])
    }

    private func c(_ text: String, _ old: Int, _ new: Int) -> DiffLine { DiffLine(kind: .context, text: text, oldLine: old, newLine: new) }
    private func d(_ text: String, _ old: Int) -> DiffLine { DiffLine(kind: .deleted, text: text, oldLine: old, newLine: nil) }
    private func a(_ text: String, _ new: Int) -> DiffLine { DiffLine(kind: .added, text: text, oldLine: nil, newLine: new) }

    /// Compact picture of the rows: "kind:text" per side.
    private func picture(_ layout: SideBySideLayout) -> [String] {
        func cell(_ line: DiffLayout.Line) -> String {
            switch line.kind {
            case .hunkHeader: "@"
            case .context: "=\(line.text)"
            case .added: "+\(line.text)"
            case .deleted: "-\(line.text)"
            case .padding: "."
            case .noNewlineMarker: "\\"
            }
        }
        return layout.rows.map { "\(cell($0.left)) | \(cell($0.right))" }
    }

    @Test func interleavedChangesAlign() {
        let layout = SideBySideLayout(diff: hunk([
            c("a", 1, 1),
            d("b", 2), d("c", 3), a("B", 2),
            c("d", 4, 3),
            a("e", 4), a("f", 5),
            c("g", 5, 6),
            d("h", 6),
            d("i", 7), a("I", 7), a("J", 8), a("K", 9),
        ]))
        #expect(picture(layout) == [
            "@ | @",
            "=a | =a",
            "-b | +B",
            "-c | .",
            "=d | =d",
            ". | +e",
            ". | +f",
            "=g | =g",
            "-h | +I",
            "-i | +J",
            ". | +K",
        ])
        #expect(layout.left.rows.count == layout.right.rows.count)
        #expect(layout.left.rows.map(\.oldLine) == [nil, 1, 2, 3, 4, nil, nil, 5, 6, 7, nil])
        #expect(layout.right.rows.map(\.newLine) == [nil, 1, 2, nil, 3, 4, 5, 6, 7, 8, 9])
        // The left column numbers old lines only, the right one new lines only.
        #expect(layout.left.rows.allSatisfy { $0.newLine == nil })
        #expect(layout.right.rows.allSatisfy { $0.oldLine == nil })
    }

    @Test func deletionAfterAdditionStartsANewBlock() {
        let layout = SideBySideLayout(diff: hunk([a("x", 1), d("y", 1), a("z", 2)]))
        #expect(picture(layout) == ["@ | @", ". | +x", "-y | +z"])
    }

    @Test func noNewlineMarkerStaysUnderItsLine() {
        let marker = DiffLine(kind: .noNewlineMarker, text: "\\ No newline at end of file", oldLine: nil, newLine: nil)
        let layout = SideBySideLayout(diff: hunk([d("old", 1), marker, a("new", 1)]))
        #expect(picture(layout) == ["@ | @", "-old | +new", "\\ | ."])
        let both = SideBySideLayout(diff: hunk([c("same", 1, 1), marker]))
        #expect(picture(both) == ["@ | @", "=same | =same", "\\ | \\"])
    }

    @Test func pairedLinesGetWordChanges() throws {
        let layout = SideBySideLayout(diff: Fixtures.swiftDiff)
        // Row 2 pairs `let name = "old"` with `let name = "new"`.
        let changes = try #require(layout.wordChanges[2])
        #expect(changes.old == [NSRange(location: 12, length: 3)])
        #expect(changes.new == [NSRange(location: 12, length: 3)])
        #expect(layout.wordChanges.keys.allSatisfy { layout.rows[$0].left.kind == .deleted && layout.rows[$0].right.kind == .added })
    }

    @Test func columnsHighlightFromTheirOwnSide() {
        let layout = SideBySideLayout(diff: Fixtures.swiftDiff)
        #expect(layout.left.contextSide == .old && layout.right.contextSide == .new)
        // The left column's reconstructed old side is the whole old text of the hunks.
        #expect(layout.left.oldSideText == "import Foundation\nlet name = \"old\"\n/* begin\nfunc run() {}\nreturn 1\n}")
        #expect(layout.right.newSideText == "import Foundation\nlet name = \"new\"\n/* begin\n   end */\nfunc run() {}\nreturn 2\n}")
        let spans = layout.left.documentSpans(oldSide: [HighlightSpan(range: NSRange(location: 0, length: 6), token: .keyword)],
                                              newSide: [])
        #expect(spans == [HighlightSpan(range: NSRange(location: layout.left.rows[1].range.location, length: 6), token: .keyword)])
    }

    @Test func binaryDiffHasNoRows() {
        let layout = SideBySideLayout(diff: FileDiff(oldPath: "a.png", newPath: "a.png", isBinary: true))
        #expect(layout.rows.isEmpty && layout.left.rows.isEmpty && layout.right.rows.isEmpty)
    }
}
