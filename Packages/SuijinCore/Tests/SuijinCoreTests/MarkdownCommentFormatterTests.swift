import Foundation
import Testing
@testable import SuijinCore

@Suite struct MarkdownCommentFormatterTests {
    private let workspace = UUID()

    private func comment(_ quote: String, in text: String, note: String = "", id: UUID = UUID()) throws -> MarkdownComment {
        let range = (text as NSString).range(of: quote)
        let anchor = try #require(MarkdownCommentAnchor(in: text, range: range))
        return MarkdownComment(id: id, workspaceID: workspace, filePath: "/work/docs/plan.md", body: note, anchor: anchor)
    }

    private let text = "# Plan\n\nFirst paragraph.\n\nSecond paragraph\nruns on two lines.\n"

    @Test func oneCommentWithANote() throws {
        let id = try #require(UUID(uuidString: "7F3A2B00-0000-4000-8000-000000000001"))
        let one = try comment("First paragraph.", in: text, note: "rewrite this for a new reader", id: id)
        let output = MarkdownCommentFormatter.format([one], filePath: "docs/plan.md")
        #expect(output == """
        Review comments on docs/plan.md. For each one, edit the file, then report the result:
          suijin comment resolve <id> --fixed --reply "what you changed"
          suijin comment resolve <id> --declined --reply "why not"

        [c-7f3a2b] line 3
        > First paragraph.
        Note: rewrite this for a new reader

        """)
    }

    @Test func severalCommentsAndAMultiLineQuoteWithoutANote() throws {
        let first = try comment("First paragraph.", in: text, note: "shorter")
        let second = try comment("Second paragraph\nruns on two lines.", in: text)
        let output = MarkdownCommentFormatter.format([first, second], filePath: "/abs/plan.md")
        #expect(output.contains("Review comments on /abs/plan.md."))
        #expect(output.contains("] lines 5-6\n> Second paragraph\n> runs on two lines.\n"))
        #expect(output.components(separatedBy: "Note: ").count == 2, "a comment without a note has no Note line")
        #expect(output.hasSuffix("> runs on two lines.\n"))
    }

    @Test func aLongQuoteIsCutButKeepsItsLineNumbers() throws {
        let long = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let one = try comment(long, in: long + "\n")
        let entry = MarkdownCommentFormatter.entry(one, id: "c-abc123")
        #expect(entry.hasPrefix("[c-abc123] lines 1-30\n> line 1\n"))
        #expect(entry.contains("> line 20\n> … (10 more lines not shown)"))
        #expect(!entry.contains("> line 21"))
    }

    @Test func detachedCommentsAreLeftOut() throws {
        var gone = try comment("First paragraph.", in: text)
        gone.anchor.isDetached = true
        let kept = try comment("# Plan", in: text)
        #expect(MarkdownCommentFormatter.format([gone], filePath: "plan.md").isEmpty)
        let output = MarkdownCommentFormatter.format([gone, kept], filePath: "plan.md")
        #expect(!output.contains("First paragraph."))
        #expect(output.contains("> # Plan"))
    }

    @Test func withoutInstructionsTheCommandIsNotMentioned() throws {
        let one = try comment("First paragraph.", in: text)
        let output = MarkdownCommentFormatter.format([one], filePath: "plan.md", includesInstructions: false)
        #expect(!output.contains("suijin comment"))
        #expect(output.hasPrefix("Review comments on plan.md. For each one, edit the file.\n\n["))
    }

    @Test func shellCharactersInNotesAndQuotesAreKeptVerbatim() throws {
        let risky = "run `rm -rf $HOME` && echo \"done\"; $(whoami) 'x' \\ !"
        let source = "before \(risky) after\n"
        let one = try comment(risky, in: source, note: "why `$(this)`? \"quote\" 'single' ; | & > <")
        let output = MarkdownCommentFormatter.format([one], filePath: "plan.md")
        #expect(output.contains("> " + risky + "\n"))
        #expect(output.contains("Note: why `$(this)`? \"quote\" 'single' ; | & > <\n"))
    }

    @Test func crlfQuotesAreSplitIntoLines() throws {
        let source = "one\r\ntwo\r\nthree\r\n"
        let one = try comment("one\r\ntwo", in: source)
        #expect(MarkdownCommentFormatter.entry(one, id: "c-1") == "[c-1] lines 1-2\n> one\n> two")
    }

    @Test func shortIDsGrowUntilTheyAreUnique() throws {
        let a = try #require(UUID(uuidString: "7F3A2B11-0000-4000-8000-000000000001"))
        let b = try #require(UUID(uuidString: "7F3A2B12-0000-4000-8000-000000000002"))
        let c = try #require(UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000003"))
        #expect(MarkdownCommentFormatter.shortID(of: a, among: [a, b, c]) == "c-7f3a2b11")
        #expect(MarkdownCommentFormatter.shortID(of: b, among: [a, b, c]) == "c-7f3a2b12")
        #expect(MarkdownCommentFormatter.shortID(of: c, among: [a, b, c]) == "c-aaaaaa")
        #expect(MarkdownCommentFormatter.shortID(of: a, among: [a]) == "c-7f3a2b")
    }

    @Test func idsResolveFromShortAndFullFormsAndAmbiguousOnesDoNot() throws {
        let a = try #require(UUID(uuidString: "7F3A2B11-0000-4000-8000-000000000001"))
        let b = try #require(UUID(uuidString: "7F3A2B12-0000-4000-8000-000000000002"))
        let ids = [a, b]
        #expect(MarkdownCommentFormatter.resolve("c-7f3a2b11", among: ids) == a)
        #expect(MarkdownCommentFormatter.resolve("7F3A2B12", among: ids) == b)
        #expect(MarkdownCommentFormatter.resolve(a.uuidString, among: ids) == a)
        #expect(MarkdownCommentFormatter.resolve("c-7f3a2b", among: ids) == nil, "two comments start this way")
        #expect(MarkdownCommentFormatter.resolve("c-000000", among: ids) == nil)
        #expect(MarkdownCommentFormatter.resolve("", among: ids) == nil)
        #expect(MarkdownCommentFormatter.resolve("c-zz; rm", among: ids) == nil)
    }
}
