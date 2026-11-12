import MercuryGit
import Testing
@testable import MercuryDiff

/// Expected strings are written by hand from Orca's format, never computed with the production code.
struct DiffNoteFormatterTests {
    struct Note: DiffNoteFormattable {
        var filePath: String
        var startLine: Int?
        var lineNumber: Int
        var body: String
    }

    @Test func singleLine() {
        let note = Note(filePath: "Sources/App.swift", startLine: nil, lineNumber: 12, body: "Use a guard here")
        #expect(DiffNoteFormatter.format(note) == """
        File: Sources/App.swift
        Line: 12
        User comment: "Use a guard here"
        """)
    }

    @Test func rangeOfLines() {
        let note = Note(filePath: "a/b.ts", startLine: 3, lineNumber: 7, body: "Extract this")
        #expect(DiffNoteFormatter.format(note) == "File: a/b.ts\nLines: 3-7\nUser comment: \"Extract this\"")
    }

    @Test func rangeStartingAndEndingOnTheSameLineIsOneLine() {
        let note = Note(filePath: "x.py", startLine: 5, lineNumber: 5, body: "ok")
        #expect(DiffNoteFormatter.format(note) == "File: x.py\nLine: 5\nUser comment: \"ok\"")
    }

    @Test func wholeFile() {
        let note = Note(filePath: "README.md", startLine: nil, lineNumber: 0, body: "Reword the intro")
        #expect(DiffNoteFormatter.format(note) == "File: README.md\nScope: file\nUser comment: \"Reword the intro\"")
    }

    @Test func escapesBackslashQuoteAndLineBreaks() {
        let note = Note(filePath: "c.swift", startLine: nil, lineNumber: 1,
                        body: #"Say "hi" \n literally"# + "\nthen\r\nmore\rend")
        // Raw string: every backslash below is a literal character in the pasted text.
        #expect(DiffNoteFormatter.format(note) == #"""
        File: c.swift
        Line: 1
        User comment: "Say \"hi\" \\n literally\nthen\r\nmore\rend"
        """#)
    }

    @Test func severalNotesAreSeparatedByOneEmptyLine() {
        let notes = [
            Note(filePath: "a.swift", startLine: nil, lineNumber: 2, body: "one"),
            Note(filePath: "a.swift", startLine: 4, lineNumber: 9, body: "two"),
            Note(filePath: "b.md", startLine: nil, lineNumber: 0, body: "three"),
        ]
        #expect(DiffNoteFormatter.format(notes) == """
        File: a.swift
        Line: 2
        User comment: "one"

        File: a.swift
        Lines: 4-9
        User comment: "two"

        File: b.md
        Scope: file
        User comment: "three"
        """)
        #expect(DiffNoteFormatter.format([Note]()) == "")
    }
}

struct DiffNoteAnchoringTests {
    @Test func anchorNormalizesRanges() {
        #expect(DiffNoteAnchor(from: 9, to: 4) == DiffNoteAnchor(startLine: 4, lineNumber: 9))
        #expect(DiffNoteAnchor(from: 4, to: 4).startLine == nil)
        #expect(DiffNoteAnchor(startLine: 6, lineNumber: 6).startLine == nil)
        #expect(DiffNoteAnchor.file.isFile)
        #expect(DiffNoteAnchor(startLine: 2, lineNumber: 4).lines == 2...4)
    }

    @Test func newSideLinesSkipDeletedLines() {
        let lines = DiffNoteAnchoring.newSideLines(of: Fixtures.swiftDiff)
        #expect(lines.keys.sorted() == [1, 2, 3, 4, 5, 41, 42])
        #expect(lines[2] == "let name = \"new\"")
    }

    @Test func identityDetectsChangedOrMissingLines() {
        let lines = [1: "a", 2: "b", 3: "c"]
        let anchor = DiffNoteAnchor(startLine: 1, lineNumber: 2)
        let identity = DiffNoteAnchoring.identity(of: anchor, in: lines)
        #expect(identity != nil)
        #expect(DiffNoteAnchoring.identity(of: anchor, in: [1: "a", 2: "b"]) == identity)
        #expect(!DiffNoteAnchoring.isStale(anchor, identity: identity, in: [1: "a", 2: "b", 7: "z"]))
        #expect(DiffNoteAnchoring.isStale(anchor, identity: identity, in: [1: "a", 2: "B"]))
        #expect(DiffNoteAnchoring.isStale(anchor, identity: identity, in: [2: "b"]))
        // Joined text must not collide: ["ab", ""] versus ["a", "b"].
        #expect(DiffNoteAnchoring.identity(of: anchor, in: [1: "ab", 2: ""]) != identity)
        #expect(DiffNoteAnchoring.identity(of: .file, in: lines) == nil)
        #expect(!DiffNoteAnchoring.isStale(.file, identity: "x", in: [:]))
        #expect(!DiffNoteAnchoring.isStale(anchor, identity: nil, in: [:]))
    }

    @Test func clampStopsAtTheFirstGap() {
        let commentable: Set<Int> = [1, 2, 3, 4, 10, 11, 12]
        #expect(DiffNoteAnchoring.clampFocus(anchor: 2, focus: 11, commentable: commentable) == 4)
        #expect(DiffNoteAnchoring.clampFocus(anchor: 11, focus: 1, commentable: commentable) == 10)
        #expect(DiffNoteAnchoring.clampFocus(anchor: 3, focus: 1, commentable: commentable) == 1)
        #expect(DiffNoteAnchoring.clampFocus(anchor: 3, focus: 3, commentable: commentable) == 3)
    }
}

struct DiffNotePlacementTests {
    @Test func placeableLinesMatchBothModes() {
        #expect(DiffNoteAnchoring.placeableLines(of: Fixtures.swiftDiff, mode: .unified) == [1, 2, 3, 4, 5, 41, 42])
        #expect(DiffNoteAnchoring.placeableLines(of: Fixtures.swiftDiff, mode: .sideBySide) == [1, 2, 3, 4, 5, 41, 42])
        let emptyLast = FileDiff(oldPath: "a", newPath: "a", hunks: [
            DiffHunk(header: "@@ -1 +1,2 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 2, lines: [
                DiffLine(kind: .context, text: "x", oldLine: 1, newLine: 1),
                DiffLine(kind: .added, text: "", oldLine: nil, newLine: 2),
            ]),
        ])
        #expect(DiffNoteAnchoring.placeableLines(of: emptyLast, mode: .unified) == [1])
        #expect(DiffNoteAnchoring.placeableLines(of: emptyLast, mode: .sideBySide) == [1])
    }
}
