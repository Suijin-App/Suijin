import Foundation
import Testing
@testable import SevindaDiff

struct SyntaxHighlighterTests {
    @Test(arguments: [
        ("Sources/App.swift", "swift"), ("web/index.JS", "javascript"), ("a.mjs", "javascript"), ("App.jsx", "javascript"),
        ("main.ts", "typescript"), ("View.tsx", "tsx"), ("tool.py", "python"), ("package.json", "json"),
        ("main.go", "go"), ("lib.rs", "rust"), ("README.md", "markdown"),
    ])
    func detectsLanguageFromExtension(path: String, expected: String) {
        #expect(SyntaxHighlighter.language(forPath: path) == expected)
    }

    @Test(arguments: ["Makefile", "photo.png", "notes.txt", "archive.tar.gz", "", ".gitignore"])
    func unknownPathsHaveNoLanguage(path: String) {
        #expect(SyntaxHighlighter.language(forPath: path) == nil)
    }

    @Test func swiftKeywordAndStringAreHighlighted() async {
        let source = "func greet() -> String {\n    return \"hi\" // done\n}"
        let spans = await SyntaxHighlighter.highlight(source, language: "swift")
        let text = source as NSString
        let tokens = spans.map { (text.substring(with: $0.range), $0.token) }
        #expect(tokens.contains { $0 == ("func", .keyword) })
        #expect(tokens.contains { $0 == ("return", .keyword) })
        #expect(tokens.contains { $0.1 == .string && $0.0.contains("hi") })
        #expect(tokens.contains { $0 == ("// done", .comment) })
        // Flattened output: sorted and non-overlapping.
        for (a, b) in zip(spans, spans.dropFirst()) { #expect(NSMaxRange(a.range) <= b.range.location) }
    }

    @Test func unknownLanguageProducesNoSpans() async {
        #expect(await SyntaxHighlighter.highlight("func x() {}", language: "cobol").isEmpty)
    }

    /// Every bundled grammar must load its vendored query and color at least something typical.
    @Test(arguments: [
        ("swift", "let x = 1"), ("javascript", "const x = 1;"), ("typescript", "const x: number = 1;"),
        ("tsx", "const x = <div>{1}</div>;"), ("python", "def f():\n    return 1"), ("json", "{\"a\": 1}"),
        ("go", "package main\nfunc main() {}"), ("rust", "fn main() { let x = 1; }"), ("markdown", "# Title\n\ntext"),
    ])
    func everyGrammarHighlights(language: String, source: String) async throws {
        let grammar = try #require(SyntaxHighlighter.grammars[language])
        #expect(SyntaxHighlighter.query(for: grammar) != nil)
        #expect(!(await SyntaxHighlighter.highlight(source, language: language)).isEmpty)
    }

    @Test func jsonKeysAreProperties() async {
        let source = "{\"key\": \"value\"}"
        let spans = await SyntaxHighlighter.highlight(source, language: "json")
        let text = source as NSString
        #expect(spans.contains { text.substring(with: $0.range) == "\"key\"" && $0.token == .property })
        #expect(spans.contains { text.substring(with: $0.range) == "\"value\"" && $0.token == .string })
    }

    @Test func captureNamesMapToTokens() {
        #expect(TokenKind(captureName: "keyword.function") == .keyword)
        #expect(TokenKind(captureName: "string.special.key") == .property)
        #expect(TokenKind(captureName: "variable.builtin") == .keyword)
        #expect(TokenKind(captureName: "variable") == nil)
        #expect(TokenKind(captureName: "punctuation.bracket") == nil)
        #expect(TokenKind(captureName: "text.title") == .heading)
    }

    @Test func innerCapturesOverrideOuterAndPrecedenceBreaksTies() {
        let outer = SyntaxHighlighter.Capture(range: NSRange(location: 0, length: 10), pattern: 0, paint: TokenKind.string.paintValue)
        let inner = SyntaxHighlighter.Capture(range: NSRange(location: 2, length: 3), pattern: 5, paint: TokenKind.keyword.paintValue)
        let spans = SyntaxHighlighter.flatten([inner, outer], length: 10, firstPatternWins: true)
        #expect(spans == [
            HighlightSpan(range: NSRange(location: 0, length: 2), token: .string),
            HighlightSpan(range: NSRange(location: 2, length: 3), token: .keyword),
            HighlightSpan(range: NSRange(location: 5, length: 5), token: .string),
        ])

        let early = SyntaxHighlighter.Capture(range: NSRange(location: 0, length: 4), pattern: 1, paint: TokenKind.type.paintValue)
        let late = SyntaxHighlighter.Capture(range: NSRange(location: 0, length: 4), pattern: 9, paint: TokenKind.function.paintValue)
        #expect(SyntaxHighlighter.flatten([late, early], length: 4, firstPatternWins: true).map(\.token) == [.type])
        #expect(SyntaxHighlighter.flatten([early, late], length: 4, firstPatternWins: false).map(\.token) == [.function])
    }
}
