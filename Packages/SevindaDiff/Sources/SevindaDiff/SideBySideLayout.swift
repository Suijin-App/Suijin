import Foundation
import SevindaGit

/// The aligned two-column form of a file diff: the old version on the left, the new one on the right, one row per
/// visual line in both columns so they always have the same height.
///
/// Context lines appear in both columns. Within a change, the run of deleted lines and the run of added lines that
/// follows it are paired row by row (so a modified line sits next to its new version); the shorter run is filled
/// with padding rows. Paired lines get word-level change ranges.
public struct SideBySideLayout: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        public var left: DiffLayout.Line
        public var right: DiffLayout.Line
    }

    public let rows: [Row]
    /// The left column (old version); context rows are colored from the old side.
    public let left: DiffLayout
    /// The right column (new version).
    public let right: DiffLayout
    /// Word changes of paired deleted/added rows, by row index; ranges are relative to the line.
    public let wordChanges: [Int: WordDiff.Result]

    public init(diff: FileDiff) {
        let rows = Self.alignedRows(of: diff)
        var wordChanges: [Int: WordDiff.Result] = [:]
        for (index, row) in rows.enumerated() where row.left.kind == .deleted && row.right.kind == .added {
            let result = WordDiff.changes(old: row.left.text, new: row.right.text)
            if result != .none { wordChanges[index] = result }
        }

        self.rows = rows
        self.wordChanges = wordChanges
        left = DiffLayout(lines: rows.map(\.left), contextSide: .old)
        right = DiffLayout(lines: rows.map(\.right), contextSide: .new)
    }

    /// The aligned rows alone, without layouts or word changes.
    static func alignedRows(of diff: FileDiff) -> [Row] {
        var rows: [Row] = []
        if !diff.isBinary {
            let marker = DiffLayout.noNewlineText
            let padding = DiffLayout.Line(kind: .padding, text: "")
            for hunk in diff.hunks {
                let header = DiffLayout.Line(kind: .hunkHeader, text: hunk.header)
                rows.append(Row(left: header, right: header))
                var deleted: [DiffLayout.Line] = []
                var added: [DiffLayout.Line] = []
                func flush() {
                    for index in 0..<max(deleted.count, added.count) {
                        rows.append(Row(left: index < deleted.count ? deleted[index] : padding,
                                        right: index < added.count ? added[index] : padding))
                    }
                    deleted.removeAll()
                    added.removeAll()
                }
                // Which side the previous line was on, so a "no newline" marker lands under that line.
                var lastSide: DiffLineKind = .context
                for line in hunk.lines {
                    switch line.kind {
                    case .deleted:
                        // A deletion after additions starts a new change block.
                        if !added.isEmpty { flush() }
                        deleted.append(DiffLayout.Line(kind: .deleted, text: line.text, oldLine: line.oldLine))
                        lastSide = .deleted
                    case .added:
                        added.append(DiffLayout.Line(kind: .added, text: line.text, newLine: line.newLine))
                        lastSide = .added
                    case .context:
                        flush()
                        rows.append(Row(left: DiffLayout.Line(kind: .context, text: line.text, oldLine: line.oldLine),
                                        right: DiffLayout.Line(kind: .context, text: line.text, newLine: line.newLine)))
                        lastSide = .context
                    case .noNewlineMarker:
                        let note = DiffLayout.Line(kind: .noNewlineMarker, text: marker)
                        switch lastSide {
                        case .deleted: deleted.append(note)
                        case .added: added.append(note)
                        case .context, .noNewlineMarker:
                            flush()
                            rows.append(Row(left: note, right: note))
                        }
                    }
                }
                flush()
            }
        }
        return rows
    }
}
