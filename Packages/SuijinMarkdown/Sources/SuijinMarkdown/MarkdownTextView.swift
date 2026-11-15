import AppKit

// How markers are hidden. Two ways were tried on the same cases (arrow keys across a hidden marker, a click in the
// middle of bold text, a drag selection across markers, copy, undo and redo, typing with an input method):
//
//   A. TextKit 1, with the layout manager's delegate turning hidden characters into control characters that have
//      no advancement, so they take no room and are never drawn.
//   B. A tiny font and a clear color on the hidden characters.
//
// A is used. With B the characters keep a sliver of width that adds up (`](https://a-long-url)` leaves a visible
// gap), the insertion point still stops inside that gap, and the tiny font changes the line height when a marker is
// the tallest thing left on a line. With A the characters stay in the text storage, so copy, undo, search and
// accessibility see the full Markdown source, and hit-testing maps a click to the right character. A's one weakness,
// an insertion point that seems stuck while it steps over invisible characters, cannot happen here: markers on the
// lines of the selection are always shown, so the insertion point is never on a line with hidden characters.
// TextKit 1 is also what the rest of the file viewer uses (the code view's line-number ruler).
//
// Within A, the `.null` glyph property was tried first and dropped: the typesetter leaves null glyphs out of the line
// altogether, so a line whose paragraph starts with a hidden marker (`- [ ] task`, `> - item`) was no longer the
// paragraph's first line and took the hanging indent meant for wrapped lines. Zero-width control characters stay in
// the line.

/// Lays out the Markdown source with hidden markers and draws what plain attributes cannot: block backgrounds,
/// quote bars, rules and checkboxes.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var theme = MarkdownTheme()

    override init() {
        super.init()
        delegate = self
        allowsNonContiguousLayout = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Glyphs

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        let count = glyphRange.length
        let first = characterIndexes[0], last = characterIndexes[count - 1]
        guard first <= last, last < storage.length else { return 0 }
        var changes = false
        storage.enumerateAttributes(in: NSRange(location: first, length: last - first + 1)) { attributes, _, stop in
            if attributes[.markdownHidden] != nil || attributes[.markdownBullet] != nil {
                changes = true
                stop.pointee = true
            }
        }
        guard changes else { return 0 }

        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        var newProperties = Array(UnsafeBufferPointer(start: properties, count: count))
        var effective = NSRange(location: 0, length: 0)
        var hidden = false, bullet = false
        for index in 0..<count {
            let character = characterIndexes[index]
            if !NSLocationInRange(character, effective) {
                let attributes = storage.attributes(at: character, effectiveRange: &effective)
                hidden = attributes[.markdownHidden] != nil
                bullet = attributes[.markdownBullet] != nil
            }
            if hidden {
                newProperties[index] = .controlCharacter
            } else if bullet, let dot = Self.bulletGlyph(in: font) {
                newGlyphs[index] = dot
            }
        }
        setGlyphs(&newGlyphs, properties: &newProperties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return count
    }

    /// Hidden characters are laid out as control characters without any advancement.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt characterIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = textStorage, characterIndex < storage.length,
              storage.attribute(.markdownHidden, at: characterIndex, effectiveRange: nil) != nil else { return action }
        return .zeroAdvancement
    }

    private static func bulletGlyph(in font: NSFont) -> CGGlyph? {
        var unit: UniChar = 0x2022
        var glyph: CGGlyph = 0
        return CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1) ? glyph : nil
    }

    // MARK: Drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first, glyphsToShow.length > 0 else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)
        let padding = container.lineFragmentPadding
        let width = container.size.width - padding * 2

        var drawnBlocks = Set<Int>()
        storage.enumerateAttribute(.markdownBlock, in: characters) { value, range, _ in
            guard let color = value as? NSColor else { return }
            // The whole block, not only its visible part, so the corners sit at its real ends.
            var block = NSRange(location: 0, length: 0)
            _ = storage.attribute(.markdownBlock, at: range.location, longestEffectiveRange: &block, in: whole)
            guard drawnBlocks.insert(block.location).inserted else { return }
            let glyphs = glyphRange(forCharacterRange: block, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let top = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let bottom = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let rect = NSRect(x: origin.x + padding, y: origin.y + top.minY - 2, width: width, height: bottom.maxY - top.minY + 4)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }

        // Text backgrounds (inline code, comment highlights, the selection) go over the block backgrounds.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        storage.enumerateAttribute(.markdownQuoteDepth, in: characters) { value, range, _ in
            guard let depth = value as? Int, depth > 0 else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            theme.quoteBarColor.setFill()
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
                for level in 0..<depth {
                    let x = origin.x + padding + CGFloat(level) * self.theme.quoteIndent
                    NSBezierPath(roundedRect: NSRect(x: x, y: origin.y + fragment.minY, width: 3, height: fragment.height),
                                 xRadius: 1.5, yRadius: 1.5).fill()
                }
            }
        }

        storage.enumerateAttribute(.markdownRule, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let fragment = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            theme.ruleColor.setFill()
            NSRect(x: origin.x + padding, y: origin.y + fragment.midY - 1, width: width, height: 2).fill()
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, glyphsToShow.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.markdownCheckbox, in: characters) { value, range, _ in
            guard let checked = value as? Bool, let rect = checkboxRect(forCharacterRange: range) else { return }
            drawCheckbox(checked: checked, in: rect.offsetBy(dx: origin.x, dy: origin.y))
        }
    }

    /// The square a task box is drawn in, in container coordinates: centered on the characters `[ ]`.
    func checkboxRect(forCharacterRange range: NSRange) -> NSRect? {
        guard let storage = textStorage, let container = textContainers.first else { return nil }
        var box = NSRange(location: 0, length: 0)
        _ = storage.attribute(.markdownCheckbox, at: range.location, longestEffectiveRange: &box,
                              in: NSRange(location: 0, length: storage.length))
        let glyphs = glyphRange(forCharacterRange: box, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let bounds = boundingRect(forGlyphRange: glyphs, in: container)
        let side = min(bounds.height, theme.checkboxSide)
        return NSRect(x: bounds.minX, y: (bounds.midY - side / 2).rounded(), width: side, height: side)
    }

    private func drawCheckbox(checked: Bool, in rect: NSRect) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3.5, yRadius: 3.5)
        if checked {
            theme.checkboxColor.setFill()
            box.fill()
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.52))
            mark.line(to: NSPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.69))
            mark.line(to: NSPoint(x: rect.minX + rect.width * 0.74, y: rect.minY + rect.height * 0.33))
            mark.lineWidth = 1.6
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            NSColor.white.setStroke()
            mark.stroke()
        } else {
            theme.secondaryTextColor.setStroke()
            box.lineWidth = 1.2
            box.stroke()
        }
    }
}

/// The editor's text view: the Markdown source as its text, shown formatted. Custom on purpose: AppKit has no
/// Markdown editor, and a web view is not an option for it.
public final class MarkdownTextView: NSTextView {
    /// Called when a rendered task box is clicked, with the range of its `[ ]` or `[x]`.
    var onToggleCheckbox: ((NSRange) -> Void)?
    /// Called when a link is ⌘-clicked, with its destination.
    var onOpenLink: ((String) -> Void)?
    /// Extra items for the context menu (the app adds "Add Comment").
    var contextMenuItems: (() -> [NSMenuItem])?
    /// Called when a click or drag in the text ended.
    var onMouseUp: (() -> Void)?

    /// What Return inserts: the line ending of the file being edited, so a CRLF file stays CRLF.
    public var lineEnding = "\n"

    var markdownLayoutManager: MarkdownLayoutManager? { layoutManager as? MarkdownLayoutManager }

    var theme = MarkdownTheme() {
        didSet {
            markdownLayoutManager?.theme = theme
            backgroundColor = theme.background
            updateInset()
        }
    }

    init() {
        let storage = NSTextStorage()
        let layoutManager = MarkdownLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)

        isEditable = true
        isSelectable = true
        allowsUndo = true
        // Plain text: paste and drop insert characters only, and copy writes the Markdown source.
        isRichText = false
        importsGraphics = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        // The editor never changes what the user typed: no smart quotes, dashes, replacements or autocorrection.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        backgroundColor = theme.background
        updateInset()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInset()
    }

    /// Centers the text column in a wide view.
    private func updateInset() {
        let side = max(theme.contentInset.width, ((frame.width - theme.maximumContentWidth) / 2).rounded(.down))
        let inset = NSSize(width: side, height: theme.contentInset.height)
        if textContainerInset != inset { textContainerInset = inset }
    }

    public override func insertNewline(_ sender: Any?) {
        insertText(lineEnding, replacementRange: selectedRange())
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, let box = checkbox(at: point) {
            onToggleCheckbox?(box)
            return
        }
        if event.modifierFlags.contains(.command), let link = link(at: point) {
            onOpenLink?(link)
            return
        }
        // Returns when the mouse button is released: the text view tracks the drag itself.
        super.mouseDown(with: event)
        onMouseUp?()
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if let items = contextMenuItems?(), !items.isEmpty, let menu {
            menu.insertItem(.separator(), at: 0)
            for item in items.reversed() { menu.insertItem(item, at: 0) }
        }
        return menu
    }

    /// The range of the rendered task box under `point` (view coordinates), if any.
    func checkbox(at point: NSPoint) -> NSRange? {
        guard let layoutManager = markdownLayoutManager, let storage = textStorage, let container = textContainer else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: container)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        // The click may land on either side of the box's characters; look at the neighbours too.
        for candidate in [character, character - 1, character + 1] where candidate >= 0 && candidate < storage.length {
            var range = NSRange(location: 0, length: 0)
            guard storage.attribute(.markdownCheckbox, at: candidate, longestEffectiveRange: &range,
                                    in: NSRange(location: 0, length: storage.length)) != nil,
                  let rect = layoutManager.checkboxRect(forCharacterRange: range),
                  rect.insetBy(dx: -3, dy: -3).contains(local) else { continue }
            return range
        }
        return nil
    }

    /// The destination of the link under `point` (view coordinates), if any.
    func link(at point: NSPoint) -> String? {
        guard let layoutManager, let storage = textStorage, let container = textContainer else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        return storage.attribute(.markdownLink, at: character, effectiveRange: nil) as? String
    }
}
