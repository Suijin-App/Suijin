import Foundation

extension MarkdownCommentAnchor {
    /// The anchor of `range` (UTF-16) in `text`, with its context and lines; nil for an empty or out-of-bounds range.
    public init?(in text: String, range: NSRange) {
        let string = NSString(string: text)
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location + range.length <= string.length else { return nil }
        self = MarkdownCommentAnchoring.anchor(string, start: range.location, end: range.location + range.length)
    }
}

/// Follows and re-finds comment anchors as their file changes. Every function is pure: it returns a new anchor and
/// never writes anything.
///
/// While the user types, `shift(_:forEdit:)` moves offsets per edit without searching; `refresh(_:in:)` then
/// brings the quote, context and lines in line with the text before the anchor is persisted. When the text is
/// replaced wholesale (reloaded from disk, rewritten by an agent), `resolve(_:in:)` searches for the quote again.
public enum MarkdownCommentAnchoring {
    /// One replacement in a text: `oldLength` UTF-16 units at `location` became `newLength` units.
    public struct Edit: Hashable, Sendable {
        public var location: Int
        public var oldLength: Int
        public var newLength: Int

        public init(location: Int, oldLength: Int, newLength: Int) {
            self.location = location
            self.oldLength = oldLength
            self.newLength = newLength
        }

        /// The edit that replaced `range` with `replacementLength` UTF-16 units.
        public init(range: NSRange, replacementLength: Int) {
            self.init(location: range.location, oldLength: range.length, newLength: replacementLength)
        }
    }

    /// The outcome of `resolve(_:in:)`.
    public struct Resolution: Hashable, Sendable {
        /// Where the comment now sits, or the old anchor marked detached.
        public var anchor: MarkdownCommentAnchor
        /// True when `anchor` differs from the anchor that was resolved and should be saved.
        public var needsPersisting: Bool
    }

    /// Re-finds `anchor` in `text`:
    /// 1. the quote still at its old offsets is kept there;
    /// 2. otherwise a single occurrence of the quote is used; among several, the one whose surroundings best match
    ///    the stored context wins, then the one nearest the old offset, but only when it clearly beats the runner-up;
    /// 3. when the quote is gone, an intact prefix and suffix around a changed middle mean the span was rewritten,
    ///    and the anchor moves to the new middle with an updated quote;
    /// 4. otherwise the anchor is detached and keeps its old quote.
    /// A detached anchor whose quote (or context) reappears attaches again.
    public static func resolve(_ anchor: MarkdownCommentAnchor, in text: String) -> Resolution {
        let string = NSString(string: text)
        if let span = locate(anchor, in: string) {
            let found = self.anchor(string, start: span.start, end: span.end)
            return Resolution(anchor: found, needsPersisting: found != anchor)
        }
        var detached = anchor
        detached.isDetached = true
        return Resolution(anchor: detached, needsPersisting: !anchor.isDetached)
    }

    /// Moves `anchor` across one edit, keeping it on the same text. Text inserted at either boundary stays outside;
    /// an edit inside the span grows or shrinks it; an edit crossing a boundary trims the part it replaced;
    /// replacing exactly the span keeps the anchor on the replacement; deleting (or replacing more than) the whole
    /// span detaches it. Only offsets change: run `refresh(_:in:)` on the edited text before persisting.
    /// Detached anchors and malformed edits are returned unchanged.
    public static func shift(_ anchor: MarkdownCommentAnchor, forEdit edit: Edit) -> MarkdownCommentAnchor {
        guard !anchor.isDetached, edit.location >= 0, edit.oldLength >= 0, edit.newLength >= 0 else { return anchor }
        let start = anchor.startOffset, end = anchor.endOffset
        let editEnd = edit.location + edit.oldLength
        let delta = edit.newLength - edit.oldLength
        var shifted = anchor
        if editEnd <= start {
            // Entirely before the span (an insertion at its start included).
            shifted.startOffset += delta
            shifted.endOffset += delta
        } else if edit.location >= end {
            // Entirely after the span (an insertion at its end included).
            return anchor
        } else if edit.location <= start && editEnd >= end {
            if edit.location == start && editEnd == end && edit.newLength > 0 {
                shifted.endOffset = start + edit.newLength
            } else {
                shifted.isDetached = true
            }
        } else if edit.location < start {
            // Crosses the start: the replaced head is gone, the new text lands before the span.
            shifted.startOffset = edit.location + edit.newLength
            shifted.endOffset += delta
        } else if editEnd > end {
            // Crosses the end: the replaced tail is gone, the new text lands after the span.
            shifted.endOffset = edit.location
        } else {
            // Inside the span.
            shifted.endOffset += delta
        }
        return shifted
    }

    /// Recomputes the quote, context and lines of an attached anchor from its offsets in `text`. Offsets that no
    /// longer fit the text detach the anchor; a detached anchor is returned unchanged.
    public static func refresh(_ anchor: MarkdownCommentAnchor, in text: String) -> MarkdownCommentAnchor {
        guard !anchor.isDetached else { return anchor }
        let string = NSString(string: text)
        guard anchor.startOffset >= 0, anchor.endOffset > anchor.startOffset, anchor.endOffset <= string.length else {
            var detached = anchor
            detached.isDetached = true
            return detached
        }
        return self.anchor(string, start: anchor.startOffset, end: anchor.endOffset)
    }

    // MARK: Building

    /// The anchor of `start..<end`, which must be a valid non-empty range of `string`.
    static func anchor(_ string: NSString, start: Int, end: Int) -> MarkdownCommentAnchor {
        let prefixStart = boundary(in: string, atOrAfter: max(0, start - MarkdownCommentAnchor.contextLength), limit: start)
        let suffixEnd = boundary(in: string, atOrBefore: min(string.length, end + MarkdownCommentAnchor.contextLength),
                                 limit: end)
        let lines = lineNumbers(in: string, start: start, end: end)
        return MarkdownCommentAnchor(
            quote: string.substring(with: NSRange(location: start, length: end - start)),
            prefix: string.substring(with: NSRange(location: prefixStart, length: start - prefixStart)),
            suffix: string.substring(with: NSRange(location: end, length: suffixEnd - end)),
            startOffset: start, endOffset: end, startLine: lines.start, endLine: lines.end
        )
    }

    /// `offset`, or the end of the composed character it falls inside, never past `limit`; context never starts in
    /// the middle of a surrogate pair or a CRLF.
    private static func boundary(in string: NSString, atOrAfter offset: Int, limit: Int) -> Int {
        guard offset > 0, offset < string.length else { return offset }
        let sequence = string.rangeOfComposedCharacterSequence(at: offset)
        return sequence.location == offset ? offset : min(limit, sequence.location + sequence.length)
    }

    /// `offset`, or the start of the composed character it falls inside, never before `limit`.
    private static func boundary(in string: NSString, atOrBefore offset: Int, limit: Int) -> Int {
        guard offset > 0, offset < string.length else { return offset }
        return max(limit, string.rangeOfComposedCharacterSequence(at: offset).location)
    }

    /// 1-based lines of the first and last character of `start..<end`. LF, CRLF and a lone CR each end a line.
    private static func lineNumbers(in string: NSString, start: Int, end: Int) -> (start: Int, end: Int) {
        var line = 1
        var startLine = 1
        let last = end - 1
        for index in 0..<last {
            if index == start { startLine = line }
            let unit = string.character(at: index)
            if unit == 0x0A || (unit == 0x0D && (index + 1 >= string.length || string.character(at: index + 1) != 0x0A)) {
                line += 1
            }
        }
        if start == last { startLine = line }
        return (startLine, line)
    }

    // MARK: Searching

    private struct Candidate {
        var start: Int
        var end: Int
        /// How many UTF-16 units of the stored prefix and suffix match around the candidate.
        var score: Int
        /// Distance from the anchor's old start offset.
        var distance: Int
    }

    /// The smallest combined prefix and suffix length that may re-anchor a rewritten span.
    private static let minimumRewriteContext = 8

    private static func locate(_ anchor: MarkdownCommentAnchor, in string: NSString) -> (start: Int, end: Int)? {
        let quoteLength = (anchor.quote as NSString).length
        guard quoteLength > 0 else { return nil }

        if anchor.startOffset >= 0, anchor.startOffset + quoteLength <= string.length,
           string.compare(anchor.quote, options: .literal,
                          range: NSRange(location: anchor.startOffset, length: quoteLength)) == .orderedSame {
            return (anchor.startOffset, anchor.startOffset + quoteLength)
        }

        let quoteMatches = occurrences(of: anchor.quote, in: string).map { start in
            Candidate(start: start, end: start + quoteLength,
                      score: contextScore(anchor, in: string, start: start, end: start + quoteLength),
                      distance: abs(start - anchor.startOffset))
        }
        if !quoteMatches.isEmpty {
            return best(of: quoteMatches).map { ($0.start, $0.end) }
        }
        return rewrittenSpan(anchor, in: string, quoteLength: quoteLength)
    }

    /// The span between an intact prefix and suffix whose middle changed. An empty prefix stands for the start of
    /// the text and an empty suffix for its end, as when the quote touched either.
    private static func rewrittenSpan(_ anchor: MarkdownCommentAnchor, in string: NSString,
                                      quoteLength: Int) -> (start: Int, end: Int)? {
        let prefixLength = (anchor.prefix as NSString).length
        let suffixLength = (anchor.suffix as NSString).length
        guard prefixLength + suffixLength >= minimumRewriteContext else { return nil }
        // A rewrite may grow the span, but not swallow the rest of the file.
        let maximumLength = quoteLength * 3 + 256

        let starts = prefixLength == 0 ? [0] : occurrences(of: anchor.prefix, in: string).map { $0 + prefixLength }
        var candidates: [Candidate] = []
        for start in starts {
            let end: Int
            if suffixLength == 0 {
                end = string.length
            } else {
                let found = string.range(of: anchor.suffix, options: .literal,
                                         range: NSRange(location: start, length: string.length - start))
                guard found.location != NSNotFound else { continue }
                end = found.location
            }
            guard end > start, end - start <= maximumLength else { continue }
            let middle = string.substring(with: NSRange(location: start, length: end - start))
            guard !middle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            candidates.append(Candidate(start: start, end: end, score: 0, distance: abs(start - anchor.startOffset)))
        }
        return best(of: candidates).map { ($0.start, $0.end) }
    }

    /// The only candidate, or the one that clearly beats the runner-up: more matching context, or with equal
    /// context, at most half the runner-up's distance from the old offset. Nil when unsure.
    private static func best(of candidates: [Candidate]) -> Candidate? {
        guard candidates.count > 1 else { return candidates.first }
        let ranked = candidates.sorted { ($0.score, -$0.distance) > ($1.score, -$1.distance) }
        let first = ranked[0], second = ranked[1]
        if first.score > second.score || first.distance * 2 < second.distance { return first }
        return nil
    }

    /// UTF-16 units of the stored prefix matching right before `start`, plus those of the suffix right after `end`.
    private static func contextScore(_ anchor: MarkdownCommentAnchor, in string: NSString, start: Int, end: Int) -> Int {
        let prefix = anchor.prefix as NSString, suffix = anchor.suffix as NSString
        var before = 0
        while before < prefix.length, start - 1 - before >= 0,
              string.character(at: start - 1 - before) == prefix.character(at: prefix.length - 1 - before) {
            before += 1
        }
        var after = 0
        while after < suffix.length, end + after < string.length,
              string.character(at: end + after) == suffix.character(at: after) {
            after += 1
        }
        return before + after
    }

    /// Start offsets of every (possibly overlapping) literal occurrence of `needle`.
    private static func occurrences(of needle: String, in string: NSString) -> [Int] {
        let needleLength = (needle as NSString).length
        guard needleLength > 0 else { return [] }
        var starts: [Int] = []
        var from = 0
        while from + needleLength <= string.length {
            let found = string.range(of: needle, options: .literal,
                                     range: NSRange(location: from, length: string.length - from))
            guard found.location != NSNotFound else { break }
            starts.append(found.location)
            from = found.location + 1
        }
        return starts
    }
}
