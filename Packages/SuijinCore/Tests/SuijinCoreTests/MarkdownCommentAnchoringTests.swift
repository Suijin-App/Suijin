import Foundation
import Testing
@testable import SuijinCore

@Suite struct MarkdownCommentAnchoringTests {
    private static let document = """
        # Guide

        Install the tool with the package manager of your platform.

        Run the tool once to create its configuration file.

        Report problems on the issue tracker.

        """

    /// The anchor of the `occurrence`-th (0-based) literal match of `quote` in `text`.
    private func anchor(_ quote: String, in text: String, occurrence: Int = 0) throws -> MarkdownCommentAnchor {
        let string = text as NSString
        var from = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = string.range(of: quote, options: .literal, range: NSRange(location: from, length: string.length - from))
            try #require(found.location != NSNotFound)
            from = found.location + 1
        }
        return try #require(MarkdownCommentAnchor(in: text, range: found))
    }

    /// Replaces `range` of `text` and reports the edit, as a text view would.
    private func apply(_ replacement: String, at range: NSRange, to text: inout String) -> MarkdownCommentAnchoring.Edit {
        text = (text as NSString).replacingCharacters(in: range, with: replacement)
        return .init(range: range, replacementLength: (replacement as NSString).length)
    }

    private func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle, options: .literal)
    }

    // MARK: Building

    @Test func buildsAnAnchorWithContextAndLines() throws {
        let text = Self.document
        let made = try anchor("create its configuration", in: text)
        #expect(made.quote == "create its configuration")
        #expect(made.range == range(of: "create its configuration", in: text))
        #expect(made.startLine == 5 && made.endLine == 5 && !made.isDetached)
        #expect(made.prefix.hasSuffix("Run the tool once to ") && made.prefix.utf16.count <= 64)
        #expect(made.suffix.hasPrefix(" file.") && made.suffix.utf16.count <= 64)

        let spanning = try anchor("platform.\n\nRun", in: text)
        #expect(spanning.startLine == 3 && spanning.endLine == 5)
        let first = try #require(MarkdownCommentAnchor(in: text, range: NSRange(location: 0, length: 7)))
        #expect(first.prefix.isEmpty && first.startLine == 1 && first.endLine == 1)
    }

    @Test func rejectsEmptyAndOutOfBoundsRanges() {
        #expect(MarkdownCommentAnchor(in: "abc", range: NSRange(location: 1, length: 0)) == nil)
        #expect(MarkdownCommentAnchor(in: "abc", range: NSRange(location: 2, length: 2)) == nil)
        #expect(MarkdownCommentAnchor(in: "abc", range: NSRange(location: NSNotFound, length: 1)) == nil)
    }

    @Test func aQuoteEndingInANewlineEndsOnThatLine() throws {
        let made = try anchor("Install the tool with the package manager of your platform.\n", in: Self.document)
        #expect(made.startLine == 3 && made.endLine == 3)
    }

    // MARK: Resolving

    @Test func anUnchangedTextKeepsTheAnchor() throws {
        let made = try anchor("create its configuration", in: Self.document)
        let resolution = MarkdownCommentAnchoring.resolve(made, in: Self.document)
        #expect(resolution.anchor == made && !resolution.needsPersisting)
    }

    @Test func anEditAboveMovesTheAnchor() throws {
        let made = try anchor("create its configuration", in: Self.document)
        let text = "Intro line.\n\n" + Self.document
        let resolution = MarkdownCommentAnchoring.resolve(made, in: text)
        #expect(resolution.needsPersisting && !resolution.anchor.isDetached)
        #expect(resolution.anchor.range == range(of: "create its configuration", in: text))
        #expect(resolution.anchor.startLine == 7 && resolution.anchor.quote == made.quote)
    }

    @Test func anEditFarBelowChangesNothing() throws {
        let made = try anchor("Install the tool", in: Self.document)
        let text = Self.document + "\nAppendix\n\n" + String(repeating: "More text. ", count: 20)
        let resolution = MarkdownCommentAnchoring.resolve(made, in: text)
        #expect(resolution.anchor == made && !resolution.needsPersisting)
    }

    @Test func anInsertionInsideTheQuoteKeepsTheGrownSpan() throws {
        let made = try anchor("create its configuration file", in: Self.document)
        let text = Self.document.replacingOccurrences(of: "its configuration", with: "its default configuration")
        let resolution = MarkdownCommentAnchoring.resolve(made, in: text)
        #expect(!resolution.anchor.isDetached && resolution.needsPersisting)
        #expect(resolution.anchor.quote == "create its default configuration file")
        #expect(resolution.anchor.range == range(of: "create its default configuration file", in: text))
    }

    @Test func aRewrittenMiddleMovesTheAnchorToTheNewText() throws {
        let made = try anchor("Run the tool once to create its configuration file.", in: Self.document)
        let rewritten = "On first launch the tool writes a configuration file next to it."
        let text = Self.document.replacingOccurrences(of: made.quote, with: rewritten)
        let resolution = MarkdownCommentAnchoring.resolve(made, in: text)
        #expect(!resolution.anchor.isDetached && resolution.anchor.quote == rewritten)
        #expect(resolution.anchor.range == range(of: rewritten, in: text))
        #expect(resolution.anchor.startLine == 5 && resolution.anchor.endLine == 5)
    }

    @Test func deletingTheQuoteDetachesItAndKeepsTheQuote() throws {
        let made = try anchor("Run the tool once to create its configuration file.\n\n", in: Self.document)
        let text = Self.document.replacingOccurrences(of: made.quote, with: "")
        let resolution = MarkdownCommentAnchoring.resolve(made, in: text)
        #expect(resolution.anchor.isDetached && resolution.needsPersisting)
        #expect(resolution.anchor.quote == made.quote && resolution.anchor.range == made.range)

        // Resolving the detached anchor again changes nothing.
        let again = MarkdownCommentAnchoring.resolve(resolution.anchor, in: text)
        #expect(again.anchor == resolution.anchor && !again.needsPersisting)

        // Undoing the deletion attaches it again.
        let restored = MarkdownCommentAnchoring.resolve(resolution.anchor, in: Self.document)
        #expect(restored.anchor == made && restored.needsPersisting)
    }

    @Test func aWhitespaceOnlyMiddleIsNotARewrite() throws {
        let made = try anchor("Run the tool once to create its configuration file.", in: Self.document)
        let text = Self.document.replacingOccurrences(of: made.quote, with: "   ")
        #expect(MarkdownCommentAnchoring.resolve(made, in: text).anchor.isDetached)
    }

    @Test func aCompletelyDifferentFileDetaches() throws {
        let made = try anchor("create its configuration", in: Self.document)
        let resolution = MarkdownCommentAnchoring.resolve(made, in: "Nothing in common here.\nAt all.\n")
        #expect(resolution.anchor.isDetached && resolution.anchor.quote == made.quote)
        #expect(MarkdownCommentAnchoring.resolve(made, in: "").anchor.isDetached)
    }

    @Test func aDuplicatedQuoteIsToldApartByItsContext() throws {
        let text = "## Linux\n\nRun `make install`.\n\n## macOS\n\nRun `make install`.\n"
        let made = try anchor("Run `make install`.", in: text, occurrence: 1)
        let edited = "Read this first.\n\n" + text
        let resolution = MarkdownCommentAnchoring.resolve(made, in: edited)
        let second = (edited as NSString).range(of: "Run `make install`.", options: .backwards)
        #expect(!resolution.anchor.isDetached && resolution.anchor.range == second)
    }

    @Test func aDuplicatedQuoteWithTheSameContextGoesToTheClearlyNearestOne() throws {
        let block = "Same paragraph text, repeated with the very same surroundings.\n\n"
        let filler = String(repeating: "Unrelated filler sentence number one. ", count: 6) + "\n\n"
        let text = filler + block + filler + block + filler
        let made = try anchor("very same", in: text, occurrence: 1)
        // A small edit above both moves them a little; the second stays far nearer the old offset.
        let edited = "Hi.\n" + text
        let resolution = MarkdownCommentAnchoring.resolve(made, in: edited)
        let second = (edited as NSString).range(of: "very same", options: .backwards)
        #expect(!resolution.anchor.isDetached && resolution.anchor.range == second)
    }

    @Test func anAmbiguousDuplicateDetaches() throws {
        let block = "Same paragraph text, repeated with the very same surroundings.\n\n"
        let filler = String(repeating: "Unrelated filler sentence number one. ", count: 6) + "\n\n"
        let made = try anchor("very same", in: filler + block + filler)
        // The text moved far down and the block now appears twice with identical surroundings; neither copy is
        // clearly nearer the old offset than the other.
        let padding = String(repeating: "z", count: 1_000) + "\n\n"
        let text = padding + filler + block + filler + filler + block + filler
        let resolution = MarkdownCommentAnchoring.resolve(made, in: text)
        #expect(resolution.anchor.isDetached)
    }

    @Test func offsetsAreUTF16ForNonASCIIText() throws {
        let text = "Xin chào 👋🏽 thế giới.\n\nĐoạn thứ hai có 🇻🇳 và chữ ghép.\n"
        let made = try anchor("có 🇻🇳 và", in: text)
        #expect(made.range == range(of: "có 🇻🇳 và", in: text))
        #expect(made.startLine == 3 && made.endLine == 3)

        let edited = "🎉🎉 Mở đầu.\n" + text
        let resolution = MarkdownCommentAnchoring.resolve(made, in: edited)
        #expect(resolution.anchor.range == range(of: "có 🇻🇳 và", in: edited))
        #expect(resolution.anchor.startLine == 4 && resolution.anchor.quote == "có 🇻🇳 và")
    }

    @Test func contextNeverSplitsASurrogatePair() throws {
        // 64 UTF-16 units before the quote fall in the middle of the emoji.
        let text = "😀" + String(repeating: "a", count: 63) + "QUOTE" + String(repeating: "b", count: 63) + "😀"
        let made = try anchor("QUOTE", in: text)
        #expect(made.prefix == String(repeating: "a", count: 63))
        #expect(made.suffix == String(repeating: "b", count: 63))
        let wide = try anchor("QUOTE", in: "😀" + text + "😀")
        #expect(!wide.prefix.contains("\u{FFFD}") && !wide.suffix.contains("\u{FFFD}"))
    }

    @Test func crlfCountsAsOneLineBreak() throws {
        let text = "# Title\r\n\r\nFirst line.\r\nSecond line.\r\n"
        let made = try anchor("Second line.", in: text)
        #expect(made.startLine == 4 && made.endLine == 4)
        let spanning = try anchor("First line.\r\nSecond", in: text)
        #expect(spanning.startLine == 3 && spanning.endLine == 4)

        let edited = "Intro.\r\n" + text
        let resolution = MarkdownCommentAnchoring.resolve(made, in: edited)
        #expect(resolution.anchor.range == range(of: "Second line.", in: edited) && resolution.anchor.startLine == 5)

        let rewritten = edited.replacingOccurrences(of: "Second line.", with: "Line two, reworded.")
        let rewrite = MarkdownCommentAnchoring.resolve(made, in: rewritten)
        #expect(rewrite.anchor.quote == "Line two, reworded." && rewrite.anchor.startLine == 5)
    }

    @Test func aLoneCarriageReturnEndsALine() throws {
        let made = try anchor("third", in: "first\rsecond\rthird")
        #expect(made.startLine == 3)
    }

    // MARK: Shifting

    @Test func shiftFollowsEditsAroundAndInsideTheSpan() throws {
        let made = try anchor("create its configuration", in: Self.document)
        let start = made.startOffset, end = made.endOffset
        typealias Edit = MarkdownCommentAnchoring.Edit
        func shifted(_ edit: Edit) -> MarkdownCommentAnchor { MarkdownCommentAnchoring.shift(made, forEdit: edit) }

        #expect(shifted(Edit(location: 0, oldLength: 0, newLength: 5)).range == NSRange(location: start + 5, length: end - start))
        #expect(shifted(Edit(location: 0, oldLength: 3, newLength: 0)).range == NSRange(location: start - 3, length: end - start))
        #expect(shifted(Edit(location: start, oldLength: 0, newLength: 2)).startOffset == start + 2)
        #expect(shifted(Edit(location: end, oldLength: 0, newLength: 2)) == made)
        #expect(shifted(Edit(location: end + 4, oldLength: 3, newLength: 0)) == made)
        #expect(shifted(Edit(location: start + 2, oldLength: 0, newLength: 4)).range == NSRange(location: start, length: end - start + 4))
        #expect(shifted(Edit(location: start + 2, oldLength: 3, newLength: 0)).range == NSRange(location: start, length: end - start - 3))
        // Crossing the start trims the head; crossing the end trims the tail.
        #expect(shifted(Edit(location: start - 2, oldLength: 5, newLength: 1)).range == NSRange(location: start - 1, length: end - start - 3))
        #expect(shifted(Edit(location: end - 3, oldLength: 6, newLength: 9)).range == NSRange(location: start, length: end - start - 3))
        // Replacing exactly the span keeps it on the replacement; deleting it detaches.
        #expect(shifted(Edit(location: start, oldLength: end - start, newLength: 4)).range == NSRange(location: start, length: 4))
        #expect(shifted(Edit(location: start, oldLength: end - start, newLength: 0)).isDetached)
        #expect(shifted(Edit(location: start - 1, oldLength: end - start + 2, newLength: 10)).isDetached)
        // Malformed edits and detached anchors are left alone.
        #expect(shifted(Edit(location: -1, oldLength: 0, newLength: 1)) == made)
        var detached = made
        detached.isDetached = true
        #expect(MarkdownCommentAnchoring.shift(detached, forEdit: Edit(location: 0, oldLength: 0, newLength: 3)) == detached)
    }

    @Test func refreshRecomputesFromOffsetsAndDetachesWhenTheyNoLongerFit() throws {
        let made = try anchor("create its configuration", in: Self.document)
        var text = Self.document
        let edit = apply("New line.\n", at: NSRange(location: 0, length: 0), to: &text)
        let refreshed = MarkdownCommentAnchoring.refresh(MarkdownCommentAnchoring.shift(made, forEdit: edit), in: text)
        #expect(refreshed.quote == made.quote && refreshed.startLine == made.startLine + 1)
        #expect(refreshed.range == range(of: made.quote, in: text))
        #expect(MarkdownCommentAnchoring.refresh(made, in: "short").isDetached)
    }

    @Test func shiftAgreesWithResolveOnTheSameEdits() throws {
        let original = Self.document
        let made = try anchor("Run the tool once to create its configuration file.", in: original)
        var text = original
        var tracked = made
        func type(_ replacement: String, at range: NSRange) {
            tracked = MarkdownCommentAnchoring.shift(tracked, forEdit: apply(replacement, at: range, to: &text))
        }
        // Above the span, below it, then inside it, character by character as typing would.
        type("Intro 👋🏽.\n\n", at: NSRange(location: 0, length: 0))
        type("\nAppendix 🇻🇳.\n", at: NSRange(location: (text as NSString).length, length: 0))
        type("", at: range(of: "Appendix ", in: text))
        var insertAt = range(of: "configuration file", in: text).location
        for character in "default " {
            type(String(character), at: NSRange(location: insertAt, length: 0))
            insertAt += String(character).utf16.count
        }
        type("", at: range(of: "once ", in: text))

        let followed = MarkdownCommentAnchoring.refresh(tracked, in: text)
        let resolved = MarkdownCommentAnchoring.resolve(made, in: text).anchor
        #expect(followed == resolved)
        #expect(followed.quote == "Run the tool to create its default configuration file.")
        #expect(!followed.isDetached)
    }

    @Test func shiftAndResolveBothDetachWhenTheSpanIsDeleted() throws {
        let original = Self.document
        let made = try anchor("create its configuration", in: original)
        var text = original
        var tracked = MarkdownCommentAnchoring.shift(made, forEdit: apply("Top.\n", at: NSRange(location: 0, length: 0),
                                                                          to: &text))
        tracked = MarkdownCommentAnchoring.shift(tracked, forEdit: apply("", at: range(of: made.quote, in: text), to: &text))
        #expect(tracked.isDetached)
        #expect(MarkdownCommentAnchoring.resolve(made, in: text).anchor.isDetached)
    }
}
