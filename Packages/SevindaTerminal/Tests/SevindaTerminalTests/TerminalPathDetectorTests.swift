import Testing
@testable import SevindaTerminal

@Suite("Path detection")
struct TerminalPathDetectorTests {
    private func found(_ lines: [String], columns: Int? = nil) -> [TerminalPathMatch] {
        TerminalPathDetector.matches(in: lines.map { TerminalTextRow($0, columnCount: columns) })
    }

    private func texts(_ line: String) -> [String] { found([line]).map(\.text) }

    @Test("paths, suffixes and quoting", arguments: [
        ("open /abs/a.swift now", "/abs/a.swift", nil, nil),
        ("see ~/x.md", "~/x.md", nil, nil),
        ("src/a.ts:12:4", "src/a.ts", 12, 4),
        ("error at src/a.ts:12:4: unexpected", "src/a.ts", 12, 4),
        ("App/x.swift:42:    let a = 1", "App/x.swift", 42, nil),
        ("Read `docs/plan.md` first", "docs/plan.md", nil, nil),
        ("Wrote \"docs/plan.md\".", "docs/plan.md", nil, nil),
        ("see [the plan](plans/a/plan.md) here", "plans/a/plan.md", nil, nil),
        ("⏺ Update(App/Features/Files/FileTabs.swift)", "App/Features/Files/FileTabs.swift", nil, nil),
        ("Look at @src/index.ts please", "src/index.ts", nil, nil),
        ("open ./run.sh", "./run.sh", nil, nil),
        ("cd ../other/dir", "../other/dir", nil, nil),
        ("edit README.md", "README.md", nil, nil),
        ("Main.cs(10,5): error CS1002", "Main.cs", 10, 5),
        ("lib/a.rb#L7", "lib/a.rb", 7, nil),
        ("file:///tmp/a%20b.txt", "/tmp/a b.txt", nil, nil),
        ("Saved to /tmp/out.txt.", "/tmp/out.txt", nil, nil),
        ("edit .gitignore", ".gitignore", nil, nil),
    ] as [(String, String, Int?, Int?)])
    func recognizes(_ line: String, _ path: String, _ number: Int?, _ column: Int?) throws {
        let match = try #require(found([line]).first { $0.kind == .path }, "\(line)")
        #expect(match.text == path)
        #expect(match.line == number)
        #expect(match.column == column)
    }

    @Test("the match covers the path and its suffix, not surrounding punctuation")
    func cells() throws {
        let match = try #require(found(["x (src/a.ts:12:4)."]).first)
        #expect(match.displayText == "src/a.ts:12:4")
        #expect(match.segments == [.init(row: 0, columns: 3..<16)])
    }

    @Test("spaces only inside quotes")
    func spaces() {
        #expect(texts("open \"My Files/a b.txt\" now").contains("My Files/a b.txt"))
        #expect(texts("open `Docs/Read Me.md`").contains("Docs/Read Me.md"))
        #expect(!texts("open My Files/a b.txt now").contains("My Files/a b.txt"))
        // An apostrophe in prose opens no quote.
        #expect(!texts("don't 'move this/that' around").contains("t "))
    }

    @Test("web links are links, not paths")
    func urls() throws {
        let matches = found(["see https://example.com/a/b.md?x=1, then (http://x.org/wiki/A_(b))."])
        #expect(matches.filter { $0.kind == .url }.map(\.text) == ["https://example.com/a/b.md?x=1", "http://x.org/wiki/A_(b)"])
        #expect(matches.allSatisfy { $0.kind == .url }, "no path inside a link")
    }

    @Test("not paths", arguments: [
        "version 1.2.3", "and/or", "a // comment", "e.g. this", "ratio 3/4", "mailto:a@b.c", "ssh://host/x", "~", "/",
        "hello world", "x...", "a/b…",
    ])
    func rejects(_ line: String) {
        let paths = found([line]).filter { $0.kind != .url }
        // `and/or` and `3/4` read as relative paths on purpose: the resolver drops them when no such file exists.
        if line == "and/or" || line == "ratio 3/4" {
            #expect(paths.map(\.text).allSatisfy { $0 == "and/or" || $0 == "3/4" })
        } else {
            #expect(paths.isEmpty, "\(line) → \(paths.map(\.text))")
        }
    }

    @Test("elided paths", arguments: [
        "Edited …/feature/x.swift", "Edited .../Sources/X.swift", "in ~/…/c.md", "Packages/.../Sources/A.swift",
        "…ure/x.swift",
    ])
    func elided(_ line: String) throws {
        let match = try #require(found([line]).first)
        #expect(match.kind == .elided)
    }

    @Test("soft-wrapped rows join; hard line breaks do not")
    func wrapping() throws {
        let rows = [
            TerminalTextRow("see /Users/me/proj", columnCount: 18),
            TerminalTextRow("ect/a.swift:3 ok", columnCount: 18, isWrapped: true),
        ]
        let match = try #require(TerminalPathDetector.matches(in: rows).first)
        #expect(match.text == "/Users/me/project/a.swift")
        #expect(match.line == 3)
        #expect(match.segments == [.init(row: 0, columns: 4..<18), .init(row: 1, columns: 0..<13)])

        // Three soft-wrapped rows.
        let three = [
            TerminalTextRow("x /aaaaaaaa", columnCount: 11), TerminalTextRow("/bbbbbbbbbb", columnCount: 11, isWrapped: true),
            TerminalTextRow("/c.md done", columnCount: 11, isWrapped: true),
        ]
        let long = try #require(TerminalPathDetector.matches(in: three).first)
        #expect(long.text == "/aaaaaaaa/bbbbbbbbbb/c.md")
        #expect(long.segments.map(\.row) == [0, 1, 2])

        // The same text with a real line break, the upper row not reaching the edge: two separate pieces.
        let hard = [TerminalTextRow("see /Users/me/proj", columnCount: 40), TerminalTextRow("ect/a.swift ok", columnCount: 40)]
        #expect(Set(TerminalPathDetector.matches(in: hard).map(\.text)) == ["/Users/me/proj", "ect/a.swift"])
    }

    @Test("a path an interface broke at the edge is offered whole and in pieces")
    func heuristicJoin() throws {
        let rows = [
            TerminalTextRow("  ⎿  Wrote /Users/me/a/very/long/pa", columnCount: 35),
            TerminalTextRow("     th/to/file.swift", columnCount: 35),
            TerminalTextRow("     more text", columnCount: 35),
        ]
        let texts = Set(TerminalPathDetector.matches(in: rows).map(\.text))
        #expect(texts.contains("/Users/me/a/very/long/path/to/file.swift"))
        #expect(texts.contains("/Users/me/a/very/long/pa"))
        #expect(texts.contains("th/to/file.swift"))
        #expect(!texts.contains { $0.contains("more") })
        // Three rows.
        let three = [
            TerminalTextRow("x /aaaa/bbbb", columnCount: 12), TerminalTextRow("/cccc/dddd/e", columnCount: 12),
            TerminalTextRow("e/f.md", columnCount: 12),
        ]
        #expect(TerminalPathDetector.matches(in: three).map(\.text).contains("/aaaa/bbbb/cccc/dddd/ee/f.md"))
    }

    @Test("the longest verified candidate wins over overlapping pieces")
    func preferred() {
        let rows = [TerminalTextRow("Wrote /a/very/long/pa", columnCount: 21), TerminalTextRow("th/file.swift", columnCount: 21)]
        let all = TerminalPathDetector.matches(in: rows)
        #expect(TerminalPathDetector.preferred(all).map(\.text) == ["/a/very/long/path/file.swift"])
        let pieces = all.filter { $0.segments.count == 1 }
        #expect(TerminalPathDetector.preferred(pieces).count == 2)
    }

    @Test("wide characters keep their columns")
    func wideCharacters() throws {
        let cells = [
            TerminalTextRow.Cell(character: "日", column: 0, width: 2), TerminalTextRow.Cell(character: " ", column: 2),
        ] + Array("a/b.md").enumerated().map { TerminalTextRow.Cell(character: $1, column: 3 + $0) }
        let match = try #require(TerminalPathDetector.matches(in: [TerminalTextRow(cells: cells, columnCount: 20)]).first)
        #expect(match.segments == [.init(row: 0, columns: 3..<9)])
    }

    @Test("over-long runs are ignored")
    func length() {
        let long = "/" + String(repeating: "a/", count: 600) + "b.md"
        #expect(found([long]).isEmpty)
    }

    @Test("explicit hyperlink cells are flagged")
    func explicit() throws {
        let cells = Array("/tmp/a.md").enumerated().map { TerminalTextRow.Cell(character: $1, column: $0, isExplicitLink: true) }
        let match = try #require(TerminalPathDetector.matches(in: [TerminalTextRow(cells: cells, columnCount: 40)]).first)
        #expect(match.touchesExplicitLink)
    }
}
