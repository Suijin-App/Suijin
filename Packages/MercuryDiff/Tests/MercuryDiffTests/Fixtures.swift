import MercuryGit

enum Fixtures {
    /// A diff with every row kind, including a block comment that starts in a context line and ends in an
    /// added line, so cross-line highlighting can be checked.
    static let swiftDiff = FileDiff(oldPath: "Sources/App.swift", newPath: "Sources/App.swift", hunks: [
        DiffHunk(header: "@@ -1,4 +1,5 @@ struct App", oldStart: 1, oldCount: 4, newStart: 1, newCount: 5, lines: [
            DiffLine(kind: .context, text: "import Foundation", oldLine: 1, newLine: 1),
            DiffLine(kind: .deleted, text: "let name = \"old\"", oldLine: 2, newLine: nil),
            DiffLine(kind: .added, text: "let name = \"new\"", oldLine: nil, newLine: 2),
            DiffLine(kind: .context, text: "/* begin", oldLine: 3, newLine: 3),
            DiffLine(kind: .added, text: "   end */", oldLine: nil, newLine: 4),
            DiffLine(kind: .context, text: "func run() {}", oldLine: 4, newLine: 5),
            DiffLine(kind: .noNewlineMarker, text: "\\ No newline at end of file", oldLine: nil, newLine: nil),
        ]),
        DiffHunk(header: "@@ -40,2 +41,2 @@", oldStart: 40, oldCount: 2, newStart: 41, newCount: 2, lines: [
            DiffLine(kind: .deleted, text: "return 1", oldLine: 40, newLine: nil),
            DiffLine(kind: .added, text: "return 2", oldLine: nil, newLine: 41),
            DiffLine(kind: .context, text: "}", oldLine: 41, newLine: 42),
        ]),
    ])

    /// A diff of `lineCount` lines alternating context, deleted and added rows across hunks of 50 lines.
    static func largeSwiftDiff(lineCount: Int) -> FileDiff {
        var hunks: [DiffHunk] = []
        var old = 1
        var new = 1
        var produced = 0
        while produced < lineCount {
            var lines: [DiffLine] = []
            let oldStart = old
            let newStart = new
            for index in 0..<min(50, lineCount - produced) {
                switch index % 5 {
                case 1:
                    lines.append(DiffLine(kind: .deleted, text: "    let value\(old) = compute(\"\(old)\") // old", oldLine: old, newLine: nil))
                    old += 1
                case 2:
                    lines.append(DiffLine(kind: .added, text: "    let value\(new) = try await compute(\"\(new)\", fast: true) // new", oldLine: nil, newLine: new))
                    new += 1
                default:
                    lines.append(DiffLine(kind: .context, text: "    func step\(old)() -> Int { return \(old) * 2 }", oldLine: old, newLine: new))
                    old += 1
                    new += 1
                }
            }
            produced += lines.count
            hunks.append(DiffHunk(header: "@@ -\(oldStart),\(old - oldStart) +\(newStart),\(new - newStart) @@",
                                  oldStart: oldStart, oldCount: old - oldStart,
                                  newStart: newStart, newCount: new - newStart, lines: lines))
        }
        return FileDiff(oldPath: "Big.swift", newPath: "Big.swift", hunks: hunks)
    }
}
