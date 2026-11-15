import AppKit
import Testing
@testable import SuijinMarkdown

/// An editor in an offscreen window, laid out at a fixed size.
@MainActor
private struct Editor {
    let controller: MarkdownEditorController
    let window: NSWindow

    init(_ text: String, width: CGFloat = 700, height: CGFloat = 500, appearance: NSAppearance.Name = .aqua) {
        controller = MarkdownEditorController(text: text)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = controller.scrollView
        window.makeFirstResponder(controller.textView)
        controller.finishStyling()
        layout()
    }

    var textView: MarkdownTextView { controller.textView }
    var storage: NSTextStorage { textView.textStorage! }
    var source: NSString { storage.string as NSString }

    func layout() {
        controller.scrollView.layoutSubtreeIfNeeded()
        textView.layoutManager!.ensureLayout(for: textView.textContainer!)
    }

    func select(_ range: NSRange) { textView.setSelectedRange(range) }

    func place(at text: String, offset: Int = 0) {
        select(NSRange(location: source.range(of: text).location + offset, length: 0))
    }

    func attribute(_ key: NSAttributedString.Key, at text: String, offset: Int = 0) -> Any? {
        storage.attribute(key, at: source.range(of: text).location + offset, effectiveRange: nil)
    }

    func isHidden(_ text: String, offset: Int = 0) -> Bool { attribute(.markdownHidden, at: text, offset: offset) != nil }

    func font(at text: String, offset: Int = 0) -> NSFont { attribute(.font, at: text, offset: offset) as! NSFont }

    /// Width the glyphs of `text` take on screen.
    func width(of text: String) -> CGFloat {
        let manager = textView.layoutManager!
        let glyphs = manager.glyphRange(forCharacterRange: source.range(of: text), actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!).width
    }

    /// Width of the text on the line that contains `text`, without the line fragment padding.
    func lineWidth(at text: String) -> CGFloat {
        let manager = textView.layoutManager!
        let glyph = manager.glyphIndexForCharacter(at: source.range(of: text).location)
        return manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).width - textView.textContainer!.lineFragmentPadding * 2
    }

    func snapshot() -> NSBitmapImageRep {
        let view = controller.scrollView
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
}

@MainActor
@Suite struct MarkdownTextViewTests {
    static let sample = "# Title\n\nSome **bold** and *italic* with `code` and [a link](https://example.com).\n\n- one\n- [ ] todo\n- [x] done\n\n> quoted\n\n---\n\n```swift\nlet a = **1**\n```\n"

    @Test func textIsTheSourceAfterEdits() {
        let editor = Editor(Self.sample)
        #expect(editor.controller.text == Self.sample)
        editor.place(at: "Some")
        editor.textView.insertText("Now ", replacementRange: editor.textView.selectedRange())
        editor.textView.insertText("**x**", replacementRange: editor.textView.selectedRange())
        editor.textView.deleteBackward(nil)
        var expected = Self.sample.replacingOccurrences(of: "Some", with: "Now **x*Some")
        #expect(editor.controller.text == expected)
        editor.select(editor.source.range(of: "- one\n"))
        editor.textView.insertText("", replacementRange: editor.textView.selectedRange())
        expected = expected.replacingOccurrences(of: "- one\n", with: "")
        #expect(editor.controller.text == expected)
    }

    @Test func undoAndRedoRestoreTheSource() {
        let editor = Editor(Self.sample)
        editor.place(at: "Some")
        editor.textView.insertText("**new** ", replacementRange: editor.textView.selectedRange())
        #expect(editor.controller.text != Self.sample)
        editor.textView.undoManager?.undo()
        #expect(editor.controller.text == Self.sample)
        editor.textView.undoManager?.redo()
        #expect(editor.controller.text == Self.sample.replacingOccurrences(of: "Some", with: "**new** Some"))
        // The styling follows: the redone text is strong again.
        editor.place(at: "# Title")
        #expect(editor.font(at: "new").fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func attributesFollowTheSyntax() {
        let editor = Editor(Self.sample)
        editor.place(at: "- one")
        #expect(editor.font(at: "Title").pointSize == 32)
        #expect(editor.font(at: "bold").fontDescriptor.symbolicTraits.contains(.bold))
        #expect(editor.font(at: "italic").fontDescriptor.symbolicTraits.contains(.italic))
        #expect(editor.font(at: "code").fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(editor.attribute(.markdownLink, at: "a link") as? String == "https://example.com")
        #expect(editor.attribute(.markdownQuoteDepth, at: "quoted") as? Int == 1)
        #expect(editor.attribute(.markdownBlock, at: "let a") != nil)
        #expect(editor.attribute(.markdownRule, at: "---") != nil)
        #expect(editor.font(at: "Some").pointSize == 16)
    }

    @Test func markersAreHiddenExceptOnTheLineOfTheInsertionPoint() {
        let editor = Editor(Self.sample)
        editor.place(at: "- one")
        #expect(editor.isHidden("# "))
        #expect(editor.isHidden("**bold"))
        #expect(editor.isHidden("](https"))
        #expect(editor.isHidden("> quoted"))
        // Nothing in a code block is ever hidden.
        #expect(!editor.isHidden("**1**"))

        editor.place(at: "Some", offset: 2)
        #expect(!editor.isHidden("**bold"))
        #expect(!editor.isHidden("](https"))
        #expect(editor.isHidden("# "))

        editor.place(at: "Title")
        #expect(!editor.isHidden("# "))
        #expect(editor.isHidden("**bold"))
    }

    @Test func aSelectionAcrossLinesShowsTheMarkersOfAllItsLines() {
        let editor = Editor("*a*\n\n*b*\n\n*c*\n")
        editor.select(NSRange(location: 1, length: 6))
        #expect(editor.storage.attribute(.markdownHidden, at: 0, effectiveRange: nil) == nil)
        #expect(editor.storage.attribute(.markdownHidden, at: 5, effectiveRange: nil) == nil)
        #expect(editor.storage.attribute(.markdownHidden, at: 10, effectiveRange: nil) != nil)
    }

    @Test func hiddenMarkersTakeNoRoom() {
        let editor = Editor("first\n\nSome **bold** text\n")
        editor.place(at: "first")
        editor.layout()
        let hidden = editor.lineWidth(at: "Some")
        editor.place(at: "Some")
        editor.layout()
        let shown = editor.lineWidth(at: "Some")
        // The rendered line is exactly as wide as the same text without its markers.
        let rendered = NSMutableAttributedString(string: "Some bold text", attributes: [.font: NSFont.systemFont(ofSize: 16)])
        rendered.addAttribute(.font, value: editor.font(at: "bold"), range: NSRange(location: 5, length: 4))
        #expect(abs(hidden - rendered.size().width) < 1)
        #expect(shown > hidden + 20)
    }

    @Test func theInsertionPointIsNeverOnALineWithHiddenCharacters() {
        let editor = Editor(Self.sample)
        editor.place(at: "# Title")
        var visited = Set<Int>()
        // Walk right through the whole document: every step moves, and the line it lands on shows its markers.
        for _ in 0..<editor.source.length {
            let before = editor.textView.selectedRange().location
            editor.textView.moveRight(nil)
            let location = editor.textView.selectedRange().location
            // Moving onto a rendered line lands after its leading marker, never inside it.
            #expect(location > before || before == editor.source.length)
            visited.insert(location)
            let line = editor.source.lineRange(for: NSRange(location: location, length: 0))
            var hasHidden = false
            editor.storage.enumerateAttribute(.markdownHidden, in: line) { value, _, _ in if value != nil { hasHidden = true } }
            #expect(!hasHidden)
        }
        #expect(visited.contains(editor.source.length))
    }

    @Test func copyWritesTheMarkdownSource() {
        let editor = Editor(Self.sample)
        editor.place(at: "- one")
        editor.textView.selectAll(nil)
        // A plain-text view: copy writes the selected characters and nothing else.
        #expect(!editor.textView.isRichText)
        #expect(!editor.textView.writablePasteboardTypes.contains(.rtf))
        #expect(editor.source.substring(with: editor.textView.selectedRange()) == Self.sample)
    }

    @Test func clickingATaskBoxTogglesItInTheSource() throws {
        let editor = Editor(Self.sample)
        editor.place(at: "# Title")
        editor.layout()
        let manager = try #require(editor.textView.markdownLayoutManager)
        let box = editor.source.range(of: "[ ]")
        let rect = try #require(manager.checkboxRect(forCharacterRange: box))
        let origin = editor.textView.textContainerOrigin
        let point = NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y)
        #expect(editor.textView.checkbox(at: point) == box)
        editor.textView.onToggleCheckbox?(box)
        #expect(editor.controller.text == Self.sample.replacingOccurrences(of: "- [ ] todo", with: "- [x] todo"))
        editor.textView.undoManager?.undo()
        #expect(editor.controller.text == Self.sample)
        // A box on the line being edited is text, not a button.
        editor.place(at: "todo")
        #expect(editor.textView.checkbox(at: point) == nil)
    }

    @Test func commandClickFindsTheLinkDestination() throws {
        let editor = Editor(Self.sample)
        editor.place(at: "# Title")
        editor.layout()
        let manager = editor.textView.layoutManager!
        let glyphs = manager.glyphRange(forCharacterRange: editor.source.range(of: "a link"), actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: editor.textView.textContainer!)
        let origin = editor.textView.textContainerOrigin
        #expect(editor.textView.link(at: NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y)) == "https://example.com")
        #expect(editor.textView.link(at: NSPoint(x: origin.x + 2, y: origin.y + 2)) == nil)
    }

    @Test func editsAreReportedInOrder() {
        let editor = Editor("one\n")
        var changes: [MarkdownTextChange] = []
        editor.controller.onTextChange = { changes.append($0) }
        editor.select(NSRange(location: 3, length: 0))
        editor.textView.insertText("!", replacementRange: editor.textView.selectedRange())
        editor.select(NSRange(location: 0, length: 2))
        editor.textView.insertText("", replacementRange: editor.textView.selectedRange())
        editor.controller.flushPendingChanges()
        #expect(changes == [
            MarkdownTextChange(location: 3, oldLength: 0, newLength: 1),
            MarkdownTextChange(location: 0, oldLength: 2, newLength: 0),
        ])
    }

    @Test func replacingTheTextKeepsTheLineAndClearsUndo() {
        let editor = Editor("one\ntwo\nthree\n")
        editor.place(at: "two", offset: 1)
        editor.textView.insertText("x", replacementRange: editor.textView.selectedRange())
        editor.controller.setText("zero\none\n**two**\nthree\n")
        #expect(editor.controller.text == "zero\none\n**two**\nthree\n")
        #expect(editor.textView.selectedRange() == NSRange(location: 5, length: 0))
        #expect(editor.textView.undoManager?.canUndo == false)
        editor.place(at: "zero")
        #expect(editor.isHidden("**two"))
    }

    @Test func typingMarkdownStylesItAtOnce() {
        let editor = Editor("start\n\nplain\n")
        editor.place(at: "plain")
        for character in "**b** " {
            editor.textView.insertText(String(character), replacementRange: editor.textView.selectedRange())
        }
        #expect(editor.controller.text == "start\n\n**b** plain\n")
        #expect(editor.font(at: "b**").fontDescriptor.symbolicTraits.contains(.bold))
        #expect(!editor.font(at: "plain").fontDescriptor.symbolicTraits.contains(.bold))
        // Still on the edited line: the markers show. Leave it and they hide.
        #expect(!editor.isHidden("**b"))
        editor.place(at: "start")
        #expect(editor.isHidden("**b"))
    }

    @Test func highlightsDoNotTouchTheText() {
        let editor = Editor(Self.sample)
        let range = editor.source.range(of: "bold")
        editor.controller.setHighlights([MarkdownHighlight(range: range, color: .systemYellow)])
        let color = editor.textView.layoutManager!.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil)
        #expect(color as? NSColor == .systemYellow)
        #expect(editor.controller.text == Self.sample)
        #expect(editor.textView.undoManager?.canUndo == false)
        editor.controller.setHighlights([])
        #expect(editor.textView.layoutManager!.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil) == nil)
    }

    @Test func theSelectionAccessoryFollowsTheSelection() {
        let editor = Editor(Self.sample)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        accessory.setFrameSize(NSSize(width: 80, height: 22))
        editor.controller.selectionAccessory = accessory
        #expect(accessory.isHidden, "nothing is selected")

        let range = editor.source.range(of: "bold")
        editor.select(range)
        #expect(!accessory.isHidden)
        #expect(accessory.superview === editor.textView)
        let selection = try? #require(editor.controller.selectionRect())
        // Under the selected text, inside the text view.
        #expect(accessory.frame.minY >= (selection?.maxY ?? .infinity))
        #expect(editor.textView.bounds.contains(accessory.frame))

        editor.select(NSRange(location: 0, length: 0))
        #expect(accessory.isHidden)
        editor.controller.selectionAccessory = nil
        #expect(accessory.superview == nil)
    }

    @Test func returnInsertsTheLineEndingOfTheFile() {
        let editor = Editor("one\r\ntwo\r\n")
        editor.textView.lineEnding = "\r\n"
        editor.select(NSRange(location: 3, length: 0))
        editor.textView.insertNewline(nil)
        #expect(editor.controller.text == "one\r\n\r\ntwo\r\n")
    }

    @Test func aLargeFileOpensAndTypesQuickly() {
        var text = ""
        var section = 0
        while text.utf8.count < 1_000_000 {
            section += 1
            text += "## Section \(section)\n\nSome **bold** text with `code`, a [link](https://example.com/\(section)) and *emphasis*.\n\n- item one\n- [ ] item two\n\n```swift\nlet value = \(section)\n```\n\n"
        }
        let clock = ContinuousClock()
        var editor: Editor?
        let open = clock.measure { editor = Editor(text, width: 900, height: 700) }
        guard let editor else { return }
        // Typing in the middle of the file: each keystroke reparses and restyles only what changed.
        editor.select(NSRange(location: editor.source.length / 2, length: 0))
        editor.place(at: "Section \(section / 2)\n")
        var slowest = Duration.zero
        for character in "typing **fast** here" {
            let elapsed = clock.measure {
                editor.textView.insertText(String(character), replacementRange: editor.textView.selectedRange())
            }
            slowest = max(slowest, elapsed)
        }
        print("large file: open \(open), slowest keystroke \(slowest)")
        #expect(editor.controller.text.utf8.count == text.utf8.count + 20)
        // The reparse of a file this long waits for a pause; once it ran, the typed text is styled.
        editor.controller.finishStyling()
        #expect(editor.font(at: "fast** here").fontDescriptor.symbolicTraits.contains(.bold))
        #expect(slowest < .milliseconds(50))
        #expect(open < .seconds(8))
    }

    /// Renders the sample at a narrow and a wide width in both appearances. Set SUIJIN_SNAPSHOT_DIR to keep the
    /// images for a look.
    @Test func rendersInBothAppearances() throws {
        let document = """
        ---
        title: Sample
        status: pending
        ---
        # Heading one
        ## Heading two
        ### Heading three

        Body text with **bold**, *italic*, ~~struck~~, `inline code` and [a link](https://example.com). A long paragraph follows so that the text wraps at the narrow width and shows the line spacing of the editor.

        - First item with a long text that wraps onto a second line to show the hanging indent of a list item
          - Nested item
        - [ ] Open task
        - [x] Done task
        1. Ordered item

        > A quote that is long enough to wrap onto a second line so the bar on its left can be seen along both lines.

        ---

        ```swift
        let greeting = "hello"
        print(greeting)
        ```

        | Column | Value |
        |--------|-------|
        | a      | 1     |

        Last line, being edited: **bold** and [link](https://example.com).
        """
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [560.0, 1200.0] {
                let editor = Editor(document, width: width, height: 900, appearance: appearance)
                editor.select(NSRange(location: editor.source.length, length: 0))
                editor.layout()
                let bitmap = editor.snapshot()
                #expect(bitmap.pixelsWide > 0)
                if let directory = ProcessInfo.processInfo.environment["SUIJIN_SNAPSHOT_DIR"] {
                    let name = "editor-\(Int(width))-\(appearance == .aqua ? "light" : "dark").png"
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
        }
    }
}
