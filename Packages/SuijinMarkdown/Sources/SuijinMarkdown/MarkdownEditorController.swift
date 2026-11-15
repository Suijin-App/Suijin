import AppKit

/// One edit of the editor's text: `oldLength` units at `location` were replaced by `newLength` units.
public struct MarkdownTextChange: Sendable, Hashable {
    public var location: Int
    public var oldLength: Int
    public var newLength: Int

    public init(location: Int, oldLength: Int, newLength: Int) {
        self.location = location
        self.oldLength = oldLength
        self.newLength = newLength
    }
}

/// A range of the text shown on a background color (a comment's anchor).
public struct MarkdownHighlight: Hashable {
    public var range: NSRange
    public var color: NSColor

    public init(range: NSRange, color: NSColor) {
        self.range = range
        self.color = color
    }
}

/// A colored range of a code block, relative to the start of its code.
public struct MarkdownCodeSpan {
    public var range: NSRange
    public var color: NSColor

    public init(range: NSRange, color: NSColor) {
        self.range = range
        self.color = color
    }
}

/// Joins the syntax tree, the styler and the text view: the text view's text is always the Markdown source, and this
/// controller keeps its attributes in step with the syntax as the text and the selection change.
@MainActor
public final class MarkdownEditorController: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
    public let textView: MarkdownTextView
    public let scrollView: NSScrollView

    /// Called after each edit of the text (typing, paste, undo, a toggled task box), in order. Not called for
    /// `setText(_:)`.
    public var onTextChange: ((MarkdownTextChange) -> Void)?
    /// Called when the selection changed.
    public var onSelectionChange: ((NSRange) -> Void)?
    /// Opens a ⌘-clicked link.
    public var onOpenLink: ((String) -> Void)? {
        didSet { textView.onOpenLink = onOpenLink }
    }
    /// Extra items for the text view's context menu.
    public var contextMenuItems: (() -> [NSMenuItem])? {
        didSet { textView.contextMenuItems = contextMenuItems }
    }
    /// A small view shown just below the end of the selection while text is selected (the app's Comment button).
    /// It is a subview of the text view, so it scrolls with the text.
    public var selectionAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            updateSelectionAccessory()
        }
    }

    /// Colors the code of a fenced block: `(code, language)` to spans relative to the code. The app supplies its
    /// syntax highlighter here; without one, code is shown in one color.
    public var codeHighlighter: ((String, String) async -> [MarkdownCodeSpan])? {
        didSet { styleEverything() }
    }

    public var theme: MarkdownTheme {
        didSet {
            textView.theme = theme
            scrollView.backgroundColor = theme.background
            styleEverything()
        }
    }

    /// The editor's own undo history. The window's undo manager is shared with every other view in it, and
    /// reloading the file must clear only this editor's edits.
    public let undoManager = UndoManager()

    public func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

    private let tree: MarkdownSyntaxTree
    private var storage: NSTextStorage { textView.textStorage! }
    private var layoutManager: NSLayoutManager { textView.layoutManager! }

    /// The lines of the selection: their markers are shown as typed.
    private var activeRange = NSRange(location: 0, length: 0)
    private var isInsideEdit = false
    private var isReplacingAll = false
    private var needsActiveUpdate = false
    private var reparseWork: DispatchWorkItem?
    /// Ranges that are not code any more and may still carry syntax colors.
    private var staleColorRanges: [NSRange] = []
    private var pendingChanges: [MarkdownTextChange] = []
    private var highlights: [MarkdownHighlight] = []
    /// Background styling of a long document: everything before `styledEnd` is styled.
    private var styledEnd = 0
    private var stylingGeneration = 0

    /// Characters styled at once when a document is shown; the rest follows in pieces of the same size.
    static let stylingChunk = 40_000
    /// Documents up to this length (UTF-16 units) are reparsed on every edit; longer ones when typing pauses.
    static let immediateReparseLimit = 150_000
    static let reparseDelay: TimeInterval = 0.15

    public init(text: String = "", theme: MarkdownTheme = MarkdownTheme()) {
        self.theme = theme
        tree = MarkdownSyntaxTree(text: text)
        textView = MarkdownTextView()
        scrollView = NSScrollView()
        super.init()
        textView.theme = theme
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        storage.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes))
        textView.typingAttributes = baseAttributes
        storage.delegate = self
        textView.delegate = self
        textView.onToggleCheckbox = { [weak self] range in self?.toggleCheckbox(range) }
        textView.onMouseUp = { [weak self] in self?.updateSelectionAccessory() }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        activeRange = lineRange(NSRange(location: 0, length: 0))
        styleEverything()
    }

    // MARK: - Text

    /// The Markdown source, exactly as it would be saved.
    public var text: String { storage.string }

    public var selectedRange: NSRange { textView.selectedRange() }

    /// Replaces the whole text (the file was reloaded). Not undoable; the undo history is cleared. Keeps the scroll
    /// position, and puts the insertion point on the line it was on.
    public func setText(_ text: String) {
        guard text != storage.string else { return }
        let source = storage.string as NSString
        let selection = textView.selectedRange()
        let line = source.substring(to: min(selection.location, source.length)).components(separatedBy: "\n").count - 1
        let origin = scrollView.contentView.bounds.origin

        isReplacingAll = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        isReplacingAll = false
        tree.replaceAll(with: text)
        textView.breakUndoCoalescing()
        undoManager.removeAllActions()
        pendingChanges.removeAll()
        reparseWork?.cancel()

        let fresh = storage.string as NSString
        var location = 0
        for _ in 0..<line where location < fresh.length {
            location = NSMaxRange(fresh.lineRange(for: NSRange(location: location, length: 0)))
        }
        textView.setSelectedRange(NSRange(location: min(location, fresh.length), length: 0))
        activeRange = lineRange(textView.selectedRange())
        styleEverything()
        applyHighlights()
        layoutManager.ensureLayout(forBoundingRect: NSRect(origin: origin, size: scrollView.contentView.bounds.size), in: textView.textContainer!)
        scrollView.contentView.scroll(to: scrollView.contentView.constrainBoundsRect(NSRect(origin: origin, size: scrollView.contentView.bounds.size)).origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Selects `range` and scrolls it into view, with the system's find indicator.
    public func reveal(_ range: NSRange) {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        let target = clamped.length == 0 ? NSRange(location: min(range.location, storage.length), length: 0) : clamped
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        if target.length > 0 { textView.showFindIndicator(for: target) }
    }

    /// Where the selection is drawn, in the text view's coordinates; nil when nothing is selected or it is
    /// scrolled out of view.
    public func selectionRect() -> NSRect? {
        let selection = textView.selectedRange()
        guard selection.length > 0, let container = textView.textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        guard rect.intersects(textView.visibleRect) else { return nil }
        return rect.intersection(textView.visibleRect)
    }

    /// Shows `highlights` behind the text, replacing the previous ones. Drawn with the layout manager's temporary
    /// attributes: the text and its undo history are not touched.
    public func setHighlights(_ highlights: [MarkdownHighlight]) {
        guard highlights != self.highlights else { return }
        self.highlights = highlights
        applyHighlights()
    }

    private func applyHighlights() {
        let whole = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        for highlight in highlights {
            let range = NSIntersectionRange(highlight.range, whole)
            guard range.length > 0 else { continue }
            layoutManager.addTemporaryAttribute(.backgroundColor, value: highlight.color, forCharacterRange: range)
        }
    }

    /// Delivers the edits collected since the last call. Edits are held until the text view finished changing its
    /// text, so a listener may safely read the text or set highlights.
    public func flushPendingChanges() {
        guard !pendingChanges.isEmpty, !isInsideEdit else { return }
        let changes = pendingChanges
        pendingChanges.removeAll()
        for change in changes { onTextChange?(change) }
    }

    private func toggleCheckbox(_ range: NSRange) {
        guard range.length == 3, NSMaxRange(range) <= storage.length else { return }
        let mark = NSRange(location: range.location + 1, length: 1)
        let checked = (storage.string as NSString).substring(with: mark) != " "
        let replacement = checked ? " " : "x"
        guard textView.shouldChangeText(in: mark, replacementString: replacement) else { return }
        storage.replaceCharacters(in: mark, with: replacement)
        textView.didChangeText()
    }

    // MARK: - Editing

    nonisolated public func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                                        range editedRange: NSRange, changeInLength delta: Int) {
        MainActor.assumeIsolated {
            guard editedMask.contains(.editedCharacters), !isReplacingAll else { return }
            isInsideEdit = true
            let oldLength = editedRange.length - delta
            let replacement = (storage.string as NSString).substring(with: editedRange)
            tree.edit(location: editedRange.location, oldLength: oldLength, with: replacement)

            // Keep the active lines and the background styling position on the same text as before the edit.
            let oldEnd = editedRange.location + oldLength
            if oldEnd <= activeRange.location {
                activeRange.location += delta
            } else if editedRange.location < NSMaxRange(activeRange) || activeRange.length == 0 {
                let start = min(activeRange.location, editedRange.location)
                let end = max(NSMaxRange(activeRange) + delta, NSMaxRange(editedRange))
                activeRange = NSRange(location: start, length: max(0, end - start))
            }
            activeRange = lineRange(activeRange)
            if editedRange.location < styledEnd { styledEnd = max(editedRange.location, styledEnd + delta) }

            pendingChanges.append(MarkdownTextChange(location: editedRange.location, oldLength: oldLength, newLength: editedRange.length))
        }
    }

    nonisolated public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                        range editedRange: NSRange, changeInLength delta: Int) {
        MainActor.assumeIsolated {
            guard isInsideEdit else { return }
            isInsideEdit = false
            // Edits that do not go through the text view (and so never reach `textDidChange`) are finished on the
            // next turn of the run loop.
            DispatchQueue.main.async { [weak self] in self?.finishEdit() }
        }
    }

    /// Styles what the last edits changed, then reports them. Styling waits until the text view finished the edit:
    /// attributes changed during it would grow the edited range, and the text view puts the insertion point at the
    /// end of that range.
    private func finishEdit() {
        guard !isInsideEdit else { return }
        if tree.needsReparse {
            if storage.length <= Self.immediateReparseLimit {
                restyleNow([])
            } else {
                // A very long document is reparsed once typing pauses; until then new text keeps the style of the
                // text it was typed into.
                reparseWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.tree.needsReparse, !self.isInsideEdit else { return }
                    self.restyleNow([])
                }
                reparseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.reparseDelay, execute: work)
            }
        }
        if needsActiveUpdate { updateActiveLines() }
        flushPendingChanges()
    }

    public func textDidChange(_ notification: Notification) {
        finishEdit()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        if isInsideEdit {
            needsActiveUpdate = true
        } else {
            updateActiveLines()
        }
        updateSelectionAccessory()
        onSelectionChange?(textView.selectedRange())
    }

    /// Places the selection accessory under the last selected character, or hides it: nothing selected, or a drag
    /// still going on (it would sit under the pointer).
    private func updateSelectionAccessory() {
        guard let accessory = selectionAccessory else { return }
        let selection = textView.selectedRange()
        guard selection.length > 0, NSMaxRange(selection) <= storage.length, NSEvent.pressedMouseButtons == 0,
              let container = textView.textContainer else {
            accessory.isHidden = true
            return
        }
        let last = NSRange(location: NSMaxRange(selection) - 1, length: 1)
        let glyphs = layoutManager.glyphRange(forCharacterRange: last, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let origin = textView.textContainerOrigin
        let size = accessory.fittingSize
        let x = min(max(origin.x, rect.maxX + origin.x + 6), max(origin.x, textView.bounds.width - size.width - 8))
        if accessory.superview !== textView { textView.addSubview(accessory) }
        accessory.frame = NSRect(x: x.rounded(), y: (rect.maxY + origin.y + 4).rounded(), width: size.width, height: size.height)
        accessory.isHidden = false
    }

    /// Shows the markers of the lines the selection moved onto, and renders those of the lines it left.
    private func updateActiveLines() {
        needsActiveUpdate = false
        let new = lineRange(textView.selectedRange())
        let old = NSIntersectionRange(activeRange, NSRange(location: 0, length: storage.length))
        guard new != activeRange else { return }
        activeRange = new
        var changed: [NSRange] = []
        for (a, b) in [(old, new), (new, old)] {
            // The parts of `a` outside `b`.
            if a.location < b.location {
                changed.append(NSRange(location: a.location, length: min(NSMaxRange(a), b.location) - a.location))
            }
            if NSMaxRange(a) > NSMaxRange(b) {
                let start = max(a.location, NSMaxRange(b))
                changed.append(NSRange(location: start, length: NSMaxRange(a) - start))
            }
        }
        // An empty last line has no characters to restyle.
        let ranges = changed.map(lineRange).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return }
        restyleNow(ranges)
    }

    /// Restyles whole lines in one editing session of the text storage, and has the layout manager generate their
    /// glyphs again (hidden markers are a glyph property, which an attribute change alone does not refresh).
    private func restyleNow(_ ranges: [NSRange]) {
        var ranges = ranges
        // Edits not parsed yet are parsed first: the tree must match the text it styles.
        if tree.needsReparse { ranges.append(tree.reparse()) }
        storage.beginEditing()
        for range in ranges { restyle(range) }
        storage.endEditing()
        let whole = NSRange(location: 0, length: storage.length)
        for range in ranges {
            let range = NSIntersectionRange(range, whole)
            guard range.length > 0 else { continue }
            layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
        // Temporary attributes cannot be changed while the storage is editing.
        for range in staleColorRanges {
            let range = NSIntersectionRange(range, whole)
            if range.length > 0 { layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range) }
        }
        staleColorRanges.removeAll()
    }

    private func lineRange(_ range: NSRange) -> NSRange {
        let source = storage.string as NSString
        let clamped = NSRange(location: min(range.location, source.length),
                              length: min(range.length, source.length - min(range.location, source.length)))
        return source.lineRange(for: clamped)
    }

    // MARK: - Styling

    private var baseParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        return style
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: theme.baseFont, .foregroundColor: theme.textColor, .paragraphStyle: baseParagraphStyle]
    }

    /// Styles the start of the document now and the rest in pieces, so a long file shows at once.
    private func styleEverything() {
        stylingGeneration += 1
        styledEnd = 0
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        styleNextChunk(generation: stylingGeneration)
    }

    private func styleNextChunk(generation: Int) {
        guard generation == stylingGeneration, styledEnd < storage.length else { return }
        let chunk = lineRange(NSRange(location: styledEnd, length: min(Self.stylingChunk, storage.length - styledEnd)))
        restyleNow([chunk])
        styledEnd = NSMaxRange(chunk)
        guard styledEnd < storage.length else { return }
        DispatchQueue.main.async { [weak self] in self?.styleNextChunk(generation: generation) }
    }

    /// Styles the rest of a long document now (tests, and callers that need the final layout).
    public func finishStyling() {
        if tree.needsReparse { restyleNow([]) }
        while styledEnd < storage.length {
            let before = styledEnd
            styleNextChunk(generation: stylingGeneration)
            if styledEnd == before { break }
        }
    }

    /// Sets every attribute the editor owns in `range` (whole lines) from the syntax tree. Called inside an editing
    /// session of the text storage.
    private func restyle(_ range: NSRange) {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return }
        for key in NSAttributedString.Key.markdownOwned { storage.removeAttribute(key, range: range) }
        storage.addAttributes(baseAttributes, range: range)

        let styling = MarkdownStyler.styling(of: tree, in: range)
        var codeRanges: [NSRange] = []
        for run in styling.runs {
            let clipped = NSIntersectionRange(run.range, range)
            guard clipped.length > 0 else { continue }
            apply(run, in: clipped, limit: range)
            if case .codeBlock(let language?, let content?) = run.kind, codeHighlighter != nil {
                codeRanges.append(content)
                highlightCode(content, language: language)
            }
        }
        let hidden = Set(MarkdownStyler.hiddenMarkers(in: styling.markers, activeLines: [activeRange]))
        for marker in styling.markers {
            let clipped = NSIntersectionRange(marker.range, range)
            guard clipped.length > 0 else { continue }
            present(marker, in: clipped, rendered: hidden.contains(marker))
        }

        // Syntax colors of code are temporary attributes: they stay while the code is retyped, and are dropped from
        // text that is no longer code.
        var location = range.location
        for code in codeRanges.sorted(by: { $0.location < $1.location }) {
            if code.location > location {
                staleColorRanges.append(NSRange(location: location, length: code.location - location))
            }
            location = max(location, NSMaxRange(code))
        }
        if location < NSMaxRange(range) {
            staleColorRanges.append(NSRange(location: location, length: NSMaxRange(range) - location))
        }
    }

    private func apply(_ run: MarkdownStyleRun, in range: NSRange, limit: NSRange) {
        switch run.kind {
        case .heading(let level):
            storage.addAttribute(.font, value: theme.headingFont(level: level), range: range)
            paragraphs(of: range, limit: limit) { $0.paragraphSpacingBefore = 4 }
        case .strong:
            addTrait(.bold, in: range)
        case .emphasis:
            addTrait(.italic, in: range)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .inlineCode:
            storage.enumerateAttribute(.font, in: range) { value, part, _ in
                let size = ((value as? NSFont)?.pointSize ?? theme.baseFont.pointSize) * theme.monoFont.pointSize / theme.baseFont.pointSize
                storage.addAttribute(.font, value: NSFont(descriptor: theme.monoFont.fontDescriptor, size: size) ?? theme.monoFont, range: part)
            }
            storage.addAttribute(.backgroundColor, value: theme.inlineCodeBackground, range: range)
        case .link(let destination):
            storage.addAttribute(.foregroundColor, value: theme.linkColor, range: range)
            if let destination { storage.addAttribute(.markdownLink, value: destination, range: range) }
        case .listMarker(let marker):
            if marker == .ordered { storage.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: range) }
        case .listItem(let contentLocation):
            listItem(run.range, contentLocation: contentLocation, in: range, limit: limit)
        case .blockquote(let depth):
            storage.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: range)
            let lines = NSIntersectionRange(lineRange(range), limit)
            storage.addAttribute(.markdownQuoteDepth, value: depth, range: lines)
            // Each level adds its own indent: an inner quote's run comes after the outer one's.
            paragraphs(of: range, limit: limit) {
                $0.firstLineHeadIndent += self.theme.quoteIndent
                $0.headIndent += self.theme.quoteIndent
            }
        case .thematicBreak:
            break
        case .codeBlock, .table, .frontMatter:
            let lines = NSIntersectionRange(lineRange(range), limit)
            storage.addAttribute(.font, value: theme.monoFont, range: lines)
            storage.addAttribute(.foregroundColor, value: theme.textColor, range: lines)
            storage.addAttribute(.markdownBlock, value: theme.blockBackground, range: lines)
            paragraphs(of: range, limit: limit) {
                $0.firstLineHeadIndent += self.theme.blockPadding
                $0.headIndent += self.theme.blockPadding
                $0.tailIndent = -self.theme.blockPadding
                $0.lineSpacing = 2
            }
        }
    }

    /// Gives a list item a hanging indent: wrapped lines start under the item's text, not under its marker.
    private func listItem(_ item: NSRange, contentLocation: Int, in range: NSRange, limit: NSRange) {
        let source = storage.string as NSString
        let firstLine = source.lineRange(for: NSRange(location: min(item.location, source.length), length: 0))
        guard contentLocation >= firstLine.location, contentLocation <= source.length else { return }
        // The width of what comes before the text on the first line, as it is rendered: indentation, then the
        // marker with a bullet shown as a dot and a task's `- ` hidden. Quote markers are hidden and take no room.
        var indentation = 0
        var index = firstLine.location
        while index < min(item.location, contentLocation) {
            let unit = source.character(at: index)
            if unit == 0x3E {
                index += (index + 1 < source.length && source.character(at: index + 1) == 0x20) ? 2 : 1
                continue
            }
            if unit == 0x20 || unit == 0x09 { indentation += 1 }
            index += 1
        }
        var marker = source.substring(with: NSRange(location: item.location, length: max(0, contentLocation - item.location)))
        marker = marker.trimmingCharacters(in: .whitespaces)
        let space = (" " as NSString).size(withAttributes: [.font: theme.baseFont]).width
        let markerWidth: CGFloat
        if marker.hasSuffix("]"), marker.contains("[") {
            markerWidth = (marker.suffix(3) as NSString).size(withAttributes: [.font: theme.checkboxFont]).width + space
        } else {
            if marker == "-" || marker == "*" || marker == "+" { marker = "\u{2022}" }
            markerWidth = (marker as NSString).size(withAttributes: [.font: theme.baseFont]).width + space
        }
        let prefix = CGFloat(indentation) * (space + theme.indentationKern) + markerWidth

        // Widen the indentation spaces of this item's first line so nesting reads clearly.
        let leading = NSIntersectionRange(NSRange(location: firstLine.location, length: max(0, item.location - firstLine.location)), limit)
        if leading.length > 0 { storage.addAttribute(.kern, value: theme.indentationKern, range: leading) }
        paragraphs(of: range, limit: limit) { style in
            style.headIndent = style.firstLineHeadIndent + prefix
        }
    }

    /// Shows a marker as typed (dimmed) or in its rendered form.
    private func present(_ marker: MarkdownMarker, in range: NSRange, rendered: Bool) {
        guard rendered else {
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: range)
            return
        }
        switch marker.role {
        case .bullet:
            storage.addAttribute(.markdownBullet, value: true, range: range)
            storage.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: range)
        case .checkbox(let checked):
            storage.addAttribute(.markdownCheckbox, value: checked, range: range)
            storage.addAttribute(.font, value: theme.checkboxFont, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        case .thematicBreak:
            storage.addAttribute(.markdownRule, value: true, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        default:
            storage.addAttribute(.markdownHidden, value: true, range: range)
        }
    }

    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, in range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, part, _ in
            guard let font = value as? NSFont else { return }
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
            if let styled = NSFont(descriptor: descriptor, size: font.pointSize) {
                storage.addAttribute(.font, value: styled, range: part)
            }
        }
    }

    /// Changes the paragraph style of every line `range` touches, inside `limit`.
    private func paragraphs(of range: NSRange, limit: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
        let lines = NSIntersectionRange(lineRange(range), limit)
        guard lines.length > 0 else { return }
        storage.enumerateAttribute(.paragraphStyle, in: lines) { value, part, _ in
            let style = ((value as? NSParagraphStyle) ?? baseParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            change(style)
            storage.addAttribute(.paragraphStyle, value: style, range: part)
        }
    }

    // MARK: - Code highlighting

    private func highlightCode(_ content: NSRange, language: String) {
        guard let codeHighlighter, content.length > 0, NSMaxRange(content) <= storage.length else { return }
        let code = (storage.string as NSString).substring(with: content)
        Task { [weak self] in
            let spans = await codeHighlighter(code, language)
            guard let self else { return }
            // The code moves when text above it is edited: find where this exact code is now.
            let source = self.storage.string as NSString
            var range = content
            if NSMaxRange(range) > source.length || source.substring(with: range) != code {
                // Among identical blocks, the one nearest to where this code was.
                var nearest: NSRange?
                var search = NSRange(location: 0, length: source.length)
                while search.length > 0 {
                    let found = source.range(of: code, options: [], range: search)
                    guard found.location != NSNotFound else { break }
                    if nearest.map({ abs(found.location - content.location) < abs($0.location - content.location) }) ?? true {
                        nearest = found
                    }
                    let next = found.location + max(1, found.length)
                    search = NSRange(location: next, length: source.length - next)
                }
                guard let nearest else { return }
                range = nearest
            }
            self.layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            for span in spans where span.range.location >= 0 && NSMaxRange(span.range) <= range.length {
                self.layoutManager.addTemporaryAttribute(.foregroundColor, value: span.color,
                                                         forCharacterRange: NSRange(location: range.location + span.range.location, length: span.range.length))
            }
        }
    }
}
