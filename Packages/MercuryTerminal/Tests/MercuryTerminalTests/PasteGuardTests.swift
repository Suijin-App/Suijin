import Testing
@testable import MercuryTerminal

@Suite("Paste guard")
struct PasteGuardTests {
    @Test("one command line goes straight through", arguments: ["ls -la", "ls -la\n", "  git status \r\n\n", "# note\nmake"])
    func singleLine(text: String) {
        #expect(PasteGuard.review(text, bracketedPaste: false) == nil)
        #expect(PasteGuard.review(text, bracketedPaste: true) == nil)
    }

    @Test("several command lines need confirmation")
    func multiLine() throws {
        let review = try #require(PasteGuard.review("cd /tmp\nrm -rf build\n", bracketedPaste: false))
        #expect(review.commandLineCount == 2)
        #expect(!review.canPasteWithoutRunning)
        let bracketed = try #require(PasteGuard.review("cd /tmp\r\nmake", bracketedPaste: true))
        #expect(bracketed.canPasteWithoutRunning)
    }

    @Test("blank lines, comments and continuations do not count")
    func commandLineCounting() {
        #expect(PasteGuard.commandLines("docker run \\\n  --rm \\\n  image").count == 1)
        #expect(PasteGuard.commandLines("\n\n# a\n  # b\necho 1\n\necho 2\n").count == 2)
        #expect(PasteGuard.commandLines("a\rb\r\nc").count == 3)
    }

    @Test("policy decides when to ask")
    func policies() {
        let text = "echo 1\necho 2"
        #expect(PasteGuard.review(text, bracketedPaste: true, policy: .always) != nil)
        #expect(PasteGuard.review(text, bracketedPaste: true, policy: .unlessBracketedPaste) == nil)
        #expect(PasteGuard.review(text, bracketedPaste: false, policy: .unlessBracketedPaste) != nil)
        #expect(PasteGuard.review(text, bracketedPaste: false, policy: .never) == nil)
    }

    @Test("decision bytes")
    func decisionBytes() {
        let start = PasteGuard.bracketedPasteStart, end = PasteGuard.bracketedPasteEnd
        let text = "echo 1\necho 2\n"
        #expect(PasteGuard.bytes(for: text, action: .run, bracketedPaste: false) == Array("echo 1\recho 2\r".utf8))
        #expect(PasteGuard.bytes(for: text, action: .run, bracketedPaste: true) == start + Array("echo 1\recho 2".utf8) + end + [13])
        #expect(PasteGuard.bytes(for: text, action: .pasteOnly, bracketedPaste: true) == start + Array("echo 1\recho 2".utf8) + end)
        // Without bracketed paste every line break would run a line.
        #expect(PasteGuard.bytes(for: text, action: .pasteOnly, bracketedPaste: false) == nil)
        #expect(PasteGuard.bytes(for: "make\n", action: .pasteOnly, bracketedPaste: false) == Array("make".utf8))
    }

    @Test("plain paste bytes keep the text and wrap it when asked")
    func plainBytes() {
        #expect(PasteGuard.plainPasteBytes("a\nb", bracketedPaste: false) == Array("a\rb".utf8))
        #expect(PasteGuard.plainPasteBytes("xin chào", bracketedPaste: true)
            == PasteGuard.bracketedPasteStart + Array("xin chào".utf8) + PasteGuard.bracketedPasteEnd)
    }
}
