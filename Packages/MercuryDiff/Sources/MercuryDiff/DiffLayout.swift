import Foundation
import MercuryGit

/// The text model behind `DiffTextView`: one row per displayed line, the document string, and the
/// reconstructed old/new file sides used for syntax highlighting.
///
/// Highlighting the reconstructed sides (instead of each diff line alone) keeps multi-line tokens such
/// as block comments and strings correct; `documentSpans(oldSide:newSide:)` maps the results back.
/// All offsets are UTF-16 units, matching `NSString`/TextKit.
public struct DiffLayout: Sendable, Hashable {
    public enum RowKind: Sendable, Hashable {
        case hunkHeader, context, added, deleted, noNewlineMarker
        /// An empty filler row in a side-by-side column, opposite a line that exists only on the other side.
        case padding
    }

    /// Which reconstructed side colors context rows: the new side in a unified diff and in the right column of a
    /// side-by-side diff, the old side in the left column.
    public enum ContextSide: Sendable, Hashable { case old, new }

    /// One displayed line before layout.
    public struct Line: Sendable, Hashable {
        public var kind: RowKind
        public var text: String
        public var oldLine: Int?
        public var newLine: Int?

        public init(kind: RowKind, text: String, oldLine: Int? = nil, newLine: Int? = nil) {
            self.kind = kind
            self.text = text
            self.oldLine = oldLine
            self.newLine = newLine
        }
    }

    public struct Row: Sendable, Hashable {
        public var kind: RowKind
        public var oldLine: Int?
        public var newLine: Int?
        /// Range of the row's text in `text`, without the trailing newline.
        public var range: NSRange
        /// Where this row's text starts in `oldSideText`, when the row belongs to the old side.
        public var oldSideLocation: Int?
        /// Where this row's text starts in `newSideText`, when the row belongs to the new side.
        public var newSideLocation: Int?
    }

    public let rows: [Row]
    /// Rows joined with `\n`; no trailing newline.
    public let text: String
    /// Context and deleted lines, in order, joined with `\n`.
    public let oldSideText: String
    /// Context and added lines, in order, joined with `\n`.
    public let newSideText: String
    /// The largest line number shown in either gutter column (0 when there are none).
    public let maxLineNumber: Int
    public let contextSide: ContextSide
    /// Start offset of each row in `text`, for binary search.
    private let rowStarts: [Int]

    /// The unified layout of `diff`: hunk headers, then each hunk's lines in diff order.
    public init(diff: FileDiff) {
        self.init(lines: Self.unifiedLines(of: diff), contextSide: .new)
    }

    public init(lines: [Line], contextSide: ContextSide) {
        var rows: [Row] = []
        var rowStarts: [Int] = []
        var text = ""
        var oldSide = ""
        var newSide = ""
        var textLength = 0
        var oldLength = 0
        var newLength = 0
        var maxLineNumber = 0
        var hasOldLine = false
        var hasNewLine = false
        rows.reserveCapacity(lines.count)
        rowStarts.reserveCapacity(lines.count)

        for line in lines {
            let kind = line.kind
            if !rows.isEmpty {
                text.append("\n")
                textLength += 1
            }
            let length = line.text.utf16.count
            var oldLocation: Int?
            var newLocation: Int?
            if kind == .context || kind == .deleted {
                if hasOldLine {
                    oldSide.append("\n")
                    oldLength += 1
                }
                hasOldLine = true
                oldLocation = oldLength
                oldSide.append(line.text)
                oldLength += length
            }
            if kind == .context || kind == .added {
                if hasNewLine {
                    newSide.append("\n")
                    newLength += 1
                }
                hasNewLine = true
                newLocation = newLength
                newSide.append(line.text)
                newLength += length
            }
            rowStarts.append(textLength)
            rows.append(Row(kind: kind, oldLine: line.oldLine, newLine: line.newLine,
                            range: NSRange(location: textLength, length: length),
                            oldSideLocation: oldLocation, newSideLocation: newLocation))
            text.append(line.text)
            textLength += length
            maxLineNumber = max(maxLineNumber, line.oldLine ?? 0, line.newLine ?? 0)
        }

        self.rows = rows
        self.rowStarts = rowStarts
        self.text = text
        self.oldSideText = oldSide
        self.newSideText = newSide
        self.maxLineNumber = maxLineNumber
        self.contextSide = contextSide
    }

    static var noNewlineText: String {
        String(localized: "No newline at end of file", bundle: .module,
               comment: "Marker shown in a diff when a file does not end with a newline")
    }

    private static func unifiedLines(of diff: FileDiff) -> [Line] {
        guard !diff.isBinary else { return [] }
        var lines: [Line] = []
        lines.reserveCapacity(diff.hunks.reduce(0) { $0 + $1.lines.count + 1 })
        let marker = noNewlineText
        for hunk in diff.hunks {
            lines.append(Line(kind: .hunkHeader, text: hunk.header))
            for line in hunk.lines {
                switch line.kind {
                case .context: lines.append(Line(kind: .context, text: line.text, oldLine: line.oldLine, newLine: line.newLine))
                case .added: lines.append(Line(kind: .added, text: line.text, newLine: line.newLine))
                case .deleted: lines.append(Line(kind: .deleted, text: line.text, oldLine: line.oldLine))
                case .noNewlineMarker: lines.append(Line(kind: .noNewlineMarker, text: marker))
                }
            }
        }
        return lines
    }

    /// Index of the row showing new-side line `line`, if any.
    public func rowIndex(newLine line: Int) -> Int? {
        rows.firstIndex { $0.newLine == line }
    }

    /// Index of the row containing the UTF-16 offset `location` in `text` (a newline belongs to the row it ends).
    public func rowIndex(at location: Int) -> Int? {
        guard !rowStarts.isEmpty, location >= 0 else { return nil }
        var low = 0
        var high = rowStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if rowStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Maps spans computed on `oldSideText`/`newSideText` to spans in `text`. Added rows take new-side colors,
    /// deleted rows old-side colors, context rows those of `contextSide`. Input spans must be sorted and non-overlapping, as
    /// `SyntaxHighlighter.highlight` returns them; the result is sorted the same way.
    public func documentSpans(oldSide: [HighlightSpan], newSide: [HighlightSpan]) -> [HighlightSpan] {
        guard !oldSide.isEmpty || !newSide.isEmpty else { return [] }
        var result: [HighlightSpan] = []
        result.reserveCapacity(oldSide.count + newSide.count)
        for row in rows {
            let sideStart: Int
            let spans: [HighlightSpan]
            switch row.kind {
            case .context where contextSide == .old, .deleted:
                guard let start = row.oldSideLocation else { continue }
                sideStart = start
                spans = oldSide
            case .context, .added:
                guard let start = row.newSideLocation else { continue }
                sideStart = start
                spans = newSide
            case .hunkHeader, .noNewlineMarker, .padding:
                continue
            }
            let sideEnd = sideStart + row.range.length
            guard row.range.length > 0 else { continue }
            var index = Self.firstSpan(endingAfter: sideStart, in: spans)
            while index < spans.count, spans[index].range.location < sideEnd {
                let span = spans[index].range
                let lower = max(span.location, sideStart)
                let upper = min(NSMaxRange(span), sideEnd)
                if upper > lower {
                    let shift = row.range.location - sideStart
                    result.append(HighlightSpan(range: NSRange(location: lower + shift, length: upper - lower),
                                                token: spans[index].token))
                }
                index += 1
            }
        }
        return result
    }

    /// First index whose span ends after `location`; spans are sorted and non-overlapping, so ends are sorted too.
    private static func firstSpan(endingAfter location: Int, in spans: [HighlightSpan]) -> Int {
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(spans[mid].range) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
