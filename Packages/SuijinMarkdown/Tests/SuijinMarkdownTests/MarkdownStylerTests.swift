import Foundation
import Testing
@testable import SuijinMarkdown

/// Substring helpers so the tests read as "the run over this text".
private struct Styled {
    let text: String
    let styling: MarkdownStyling

    init(_ text: String) {
        self.text = text
        styling = MarkdownStyler.styling(of: MarkdownSyntaxTree(text: text))
    }

    func string(_ range: NSRange) -> String { (text as NSString).substring(with: range) }

    func runs(_ matches: (MarkdownStyleRun.Kind) -> Bool) -> [String] {
        styling.runs.filter { matches($0.kind) }.map { string($0.range) }
    }

    func runs(_ kind: MarkdownStyleRun.Kind) -> [String] { runs { $0 == kind } }

    func markers(_ role: MarkdownMarker.Role) -> [String] {
        styling.markers.filter { $0.role == role }.map { string($0.range) }
    }
}

@Suite struct MarkdownStylerTests {
    @Test func atxHeadingsOfEveryLevel() {
        for level in 1...6 {
            let styled = Styled(String(repeating: "#", count: level) + " Title\n\ntext\n")
            #expect(styled.runs(.heading(level: level)) == [String(repeating: "#", count: level) + " Title"])
            #expect(styled.markers(.heading) == [String(repeating: "#", count: level) + " "])
        }
    }

    @Test func setextHeadings() {
        let styled = Styled("Big\n===\n\nSmall\n---\n")
        #expect(styled.runs(.heading(level: 1)) == ["Big"])
        #expect(styled.runs(.heading(level: 2)) == ["Small"])
        #expect(styled.markers(.heading) == ["===", "---"])
    }

    @Test func strongEmphasisAndStrikethrough() {
        let styled = Styled("a **bold** b *it* c _it_ d ~~gone~~ e\n")
        #expect(styled.runs(.strong) == ["**bold**"])
        #expect(styled.markers(.strong) == ["**", "**"])
        #expect(styled.runs(.emphasis) == ["*it*", "_it_"])
        #expect(styled.markers(.emphasis) == ["*", "*", "_", "_"])
        #expect(styled.runs(.strikethrough) == ["~~gone~~"])
        #expect(styled.markers(.strikethrough) == ["~~", "~~"])
    }

    @Test func inlineCode() {
        let styled = Styled("use `let x = *1*` here\n")
        #expect(styled.runs(.inlineCode) == ["`let x = *1*`"])
        #expect(styled.markers(.code) == ["`", "`"])
        #expect(styled.runs(.emphasis).isEmpty)
    }

    @Test func inlineLinkHidesBracketsAndDestination() {
        let styled = Styled("see [the docs](https://example.com/a_b) now\n")
        #expect(styled.runs(.link(destination: "https://example.com/a_b")) == ["the docs"])
        #expect(styled.markers(.linkOpen) == ["["])
        #expect(styled.markers(.linkClose) == ["](https://example.com/a_b)"])
    }

    @Test func referenceLinkAndAutolink() {
        let styled = Styled("a [text][ref] and <https://x.y>\n\n[ref]: https://r.r\n")
        #expect(styled.runs(.link(destination: nil)) == ["text"])
        #expect(styled.runs(.link(destination: "https://x.y")) == ["https://x.y"])
        #expect(styled.markers(.linkOpen) == ["[", "<"])
        #expect(styled.markers(.linkClose) == ["][ref]", ">"])
    }

    @Test func listMarkers() {
        let styled = Styled("- one\n* two\n1. three\n- [ ] todo\n- [x] done\n")
        #expect(styled.runs(.listMarker(.bullet)) == ["-", "*"])
        #expect(styled.runs(.listMarker(.ordered)) == ["1."])
        #expect(styled.runs(.listMarker(.task(checked: false))) == ["- [ ]"])
        #expect(styled.runs(.listMarker(.task(checked: true))) == ["- [x]"])
        #expect(styled.markers(.bullet) == ["-", "*"])
        #expect(styled.markers(.taskBullet) == ["- ", "- "])
        #expect(styled.markers(.checkbox(checked: false)) == ["[ ]"])
        #expect(styled.markers(.checkbox(checked: true)) == ["[x]"])
    }

    @Test func listItemContentStartsAfterTheMarker() {
        let text = "- one\n  - [ ] nested\n"
        let styled = Styled(text)
        let starts = styled.styling.runs.compactMap { run -> String? in
            guard case .listItem(let content) = run.kind else { return nil }
            return (text as NSString).substring(from: content).components(separatedBy: "\n")[0]
        }
        #expect(starts == ["one", "nested"])
    }

    @Test func blockquoteMarkersOnEveryLine() {
        let styled = Styled("> first\n> second\n\nafter\n")
        #expect(styled.runs(.blockquote(depth: 1)) == ["> first\n> second"])
        #expect(styled.markers(.blockquote) == ["> ", "> "])
    }

    @Test func thematicBreak() {
        let styled = Styled("above\n\n---\n\nbelow\n")
        #expect(styled.runs(.thematicBreak) == ["---"])
        #expect(styled.markers(.thematicBreak) == ["---"])
    }

    @Test func fencedCodeBlockKeepsItsMarkers() {
        let styled = Styled("```swift\nlet a = **1**\n```\n\nafter\n")
        let blocks = styled.styling.runs.compactMap { run -> (String, String?, String?)? in
            guard case .codeBlock(let language, let content) = run.kind else { return nil }
            return (styled.string(run.range), language, content.map(styled.string))
        }
        #expect(blocks.count == 1)
        #expect(blocks.first?.0 == "```swift\nlet a = **1**\n```")
        #expect(blocks.first?.1 == "swift")
        #expect(blocks.first?.2 == "let a = **1**\n")
        #expect(styled.styling.markers.isEmpty)
    }

    @Test func tableIsOneRunWithoutMarkers() {
        let styled = Styled("| a | **b** |\n|---|---|\n| 1 | 2 |\n")
        #expect(styled.runs(.table) == ["| a | **b** |\n|---|---|\n| 1 | 2 |"])
        #expect(styled.styling.markers.isEmpty)
    }

    @Test func frontMatterIsOneRunWithoutMarkers() {
        let styled = Styled("---\ntitle: \"**x**\"\n---\n# Head\n")
        #expect(styled.runs(.frontMatter) == ["---\ntitle: \"**x**\"\n---"])
        #expect(styled.runs(.heading(level: 1)) == ["# Head"])
        #expect(styled.markers(.strong).isEmpty)
    }

    @Test func fileWithOnlyFrontMatter() {
        let styled = Styled("---\na: 1\n---\n")
        #expect(styled.runs(.frontMatter) == ["---\na: 1\n---"])
        #expect(styled.styling.markers.isEmpty)
    }

    @Test func emptyFile() {
        let styled = Styled("")
        #expect(styled.styling.runs.isEmpty)
        #expect(styled.styling.markers.isEmpty)
    }

    @Test func strongInsideListInsideQuote() {
        let styled = Styled("> - item **bold**\n>   more *it*\n")
        #expect(styled.runs(.blockquote(depth: 1)).count == 1)
        #expect(styled.runs(.listMarker(.bullet)) == ["-"])
        #expect(styled.runs(.strong) == ["**bold**"])
        #expect(styled.runs(.emphasis) == ["*it*"])
        #expect(styled.markers(.blockquote) == ["> ", "> "])
    }

    @Test func offsetsAreUTF16ForNonASCIIAndEmoji() {
        let styled = Styled("Tiếng Việt 👍🏽 **đậm** và *nghiêng* 🎉\n")
        #expect(styled.runs(.strong) == ["**đậm**"])
        #expect(styled.runs(.emphasis) == ["*nghiêng*"])
        #expect(styled.markers(.strong) == ["**", "**"])
    }

    @Test func crlfLineEndings() {
        let styled = Styled("# Title\r\n\r\n- one **b**\r\n- two\r\n\r\n> q\r\n")
        #expect(styled.runs(.heading(level: 1)) == ["# Title"])
        #expect(styled.runs(.strong) == ["**b**"])
        #expect(styled.runs(.listMarker(.bullet)) == ["-", "-"])
        #expect(styled.markers(.blockquote) == ["> "])
    }

    @Test func inlineHTMLIsLeftAlone() {
        let styled = Styled("a <span class=\"x\">*b*</span> c\n")
        #expect(styled.markers(.linkOpen).isEmpty)
        // The emphasis between the tags is still Markdown; the tags themselves get no marker.
        #expect(styled.styling.markers.allSatisfy { !styled.string($0.range).contains("<") })
    }

    @Test func escapedCharacterHidesTheBackslash() {
        let styled = Styled("not \\*emphasis\\*\n")
        #expect(styled.markers(.escape) == ["\\", "\\"])
        #expect(styled.runs(.emphasis).isEmpty)
    }

    @Test func imageIsShownAsTyped() {
        let styled = Styled("an ![alt *x*](a.png) image\n")
        #expect(styled.styling.markers.isEmpty)
        #expect(styled.styling.runs.isEmpty)
    }

    @Test func stylingOfARangeOnlyReturnsBlocksThatTouchIt() {
        let text = "# One\n\npara **a**\n\n# Two\n\npara **b**\n"
        let tree = MarkdownSyntaxTree(text: text)
        let second = (text as NSString).range(of: "para **b**")
        let styling = MarkdownStyler.styling(of: tree, in: second)
        #expect(styling.runs.map { (text as NSString).substring(with: $0.range) } == ["**b**"])
    }

    // MARK: Hiding

    @Test func markersOnAnActiveLineStayVisible() {
        let text = "# One\n\npara **a**\n"
        let styling = Styled(text).styling
        let source = text as NSString
        let headingLine = source.lineRange(for: NSRange(location: 0, length: 0))
        let hidden = MarkdownStyler.hiddenMarkers(in: styling.markers, activeLines: [headingLine])
        #expect(hidden.map { source.substring(with: $0.range) } == ["**", "**"])
        #expect(MarkdownStyler.hiddenMarkers(in: styling.markers, activeLines: []).count == 3)
    }

    @Test func aSelectionAcrossLinesKeepsAllItsMarkersVisible() {
        let text = "*a*\n*b*\n*c*\n"
        let styling = Styled(text).styling
        let hidden = MarkdownStyler.hiddenMarkers(in: styling.markers, activeLines: [NSRange(location: 0, length: 8)])
        #expect(hidden.map(\.range.location) == [8, 10])
    }

    @Test func anInsertionPointAtTheEndOfTheLastLineIsOnThatLine() {
        let text = "a **b**"
        let styling = Styled(text).styling
        let end = NSRange(location: (text as NSString).length, length: 0)
        let hidden = MarkdownStyler.hiddenMarkers(in: styling.markers, activeLines: [(text as NSString).lineRange(for: end)])
        #expect(hidden.isEmpty)
    }

    // MARK: Properties

    static let fixtures: [String] = [
        "---\ntitle: x\nstatus: pending\n---\n# Head *em*\n\nPara **bold** `code` ~~gone~~ [link](http://a.b) <http://x.y> \\* [ref][r] ![img](a.png)\n\n- item one\n  more\n- [ ] todo\n- [x] done\n  1. nested **b**\n\n> quote **b**\n> second\n\n---\n\n```swift\nlet a = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nSetext\n===\n\n    indented\n\n[r]: http://r.r\n",
        "> - a\n>   - b **c** `d`\n> > nested *quote*\n\n1. one\n2. two\n   continued [x](y)\n",
        "Việt **đậm** 👩‍👩‍👧 *nghiêng*\r\n\r\n- [ ] việc 🎉\r\n- [x] xong\r\n",
        "***both*** **a *b* c** [**bold link**](u) `a` ``b ` c``\n",
        "<div>\n*html*\n</div>\n\ntext <b>x</b> **y**\n",
        "#\n\n-\n\n>\n\n****\n\n[]()\n",
    ]

    @Test(arguments: fixtures)
    func runsStayInsideTheTextAndMarkersDoNotOverlap(text: String) {
        let styling = Styled(text).styling
        let length = (text as NSString).length
        for run in styling.runs {
            #expect(run.range.location >= 0 && NSMaxRange(run.range) <= length)
        }
        var previousEnd = 0
        for marker in styling.markers {
            #expect(marker.range.length > 0)
            #expect(marker.range.location >= previousEnd)
            #expect(NSMaxRange(marker.range) <= length)
            previousEnd = NSMaxRange(marker.range)
        }
    }

    // MARK: Incremental

    @Test func typingBoldCharacterByCharacterMatchesAFreshParse() {
        let prefix = "# Title\n\nSome text \n\n- item\n"
        let insertion = (prefix as NSString).range(of: "text ").location + 5
        let tree = MarkdownSyntaxTree(text: prefix)
        var current = prefix as NSString
        for (index, character) in "**đậm**".enumerated() {
            // Every character typed here is one UTF-16 unit.
            tree.replace(location: insertion + index, oldLength: 0, with: String(character))
            current = current.replacingCharacters(in: NSRange(location: insertion + index, length: 0), with: String(character)) as NSString
            #expect(tree.text == current as String)
            let fresh = MarkdownStyler.styling(of: MarkdownSyntaxTree(text: current as String))
            #expect(MarkdownStyler.styling(of: tree) == fresh)
        }
        #expect(MarkdownStyler.styling(of: tree).runs.contains { $0.kind == .strong })
    }

    @Test(arguments: fixtures)
    func randomEditsMatchAFreshParse(text: String) {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["*", "**", "`", "\n", "\n\n", "# ", "- ", "> ", "```\n", "x", " ", "[a](b)", "---\n", "é", "🎉"]
        let tree = MarkdownSyntaxTree(text: text)
        var current = text as NSString
        for _ in 0..<60 {
            let location = Int.random(in: 0...current.length, using: &generator)
            // Never cut a surrogate pair or a CRLF: an editor does not produce such edits.
            let safe = current.rangeOfComposedCharacterSequence(at: min(location, max(0, current.length - 1)))
            let start = current.length == 0 ? 0 : safe.location
            let deleting = Bool.random(using: &generator) && start < current.length
            let old = deleting ? current.rangeOfComposedCharacterSequence(at: start) : NSRange(location: start, length: 0)
            let replacement = deleting ? "" : pieces.randomElement(using: &generator)!
            tree.replace(location: old.location, oldLength: old.length, with: replacement)
            current = current.replacingCharacters(in: old, with: replacement) as NSString
            let fresh = MarkdownStyler.styling(of: MarkdownSyntaxTree(text: current as String))
            #expect(MarkdownStyler.styling(of: tree) == fresh, "after editing to: \(current)")
        }
    }

    @Test func editReportsTheLinesWhoseSyntaxChanged() {
        let text = "one\n\ntwo\n\nthree\n"
        let tree = MarkdownSyntaxTree(text: text)
        // Typing inside "two" only dirties its own line.
        let dirty = tree.replace(location: 6, oldLength: 0, with: "x")
        #expect(tree.text == "one\n\ntxwo\n\nthree\n")
        #expect(dirty == NSRange(location: 5, length: 5))
    }

    @Test func openingAFenceDirtiesEverythingItSwallows() {
        let text = "one\n\ntwo **b**\n\nthree\n"
        let tree = MarkdownSyntaxTree(text: text)
        let dirty = tree.replace(location: 0, oldLength: 0, with: "```\n")
        #expect(NSMaxRange(dirty) == tree.length)
        #expect(MarkdownStyler.styling(of: tree).markers.isEmpty)
    }

    @Test func closingTheFrontMatterDirtiesFromTheTop() {
        let tree = MarkdownSyntaxTree(text: "---\ntitle: x\n\n# Head\n")
        let dirty = tree.replace(location: 13, oldLength: 0, with: "---\n")
        #expect(dirty.location == 0)
        #expect(MarkdownStyler.styling(of: tree).runs.contains { $0.kind == .frontMatter })
    }
}

@Suite struct MarkdownDocumentTests {
    @Test func splitsFrontMatterFromTheBody() {
        let document = MarkdownDocument("---\ntitle: \"Plan\"\nstatus: pending\n  nested: no\n---\n# Body\n")
        #expect(document.frontMatter.map(\.key) == ["title", "status"])
        #expect(document.frontMatter.map(\.value) == ["Plan", "pending"])
        #expect(document.body == "# Body\n")
    }

    @Test func noFrontMatterLeavesTheTextWhole() {
        let document = MarkdownDocument("# Title\n---\n")
        #expect(document.frontMatter.isEmpty)
        #expect(document.body == "# Title\n---\n")
    }

    @Test func crlfFrontMatter() {
        let document = MarkdownDocument("---\r\na: 1\r\n---\r\nbody\r\n")
        #expect(document.frontMatter.map(\.key) == ["a"])
        #expect(document.body == "body\r\n")
    }

    @Test func unclosedFrontMatterIsNotFrontMatter() {
        #expect(MarkdownFrontMatter.range(in: "---\na: 1\n") == nil)
    }
}
