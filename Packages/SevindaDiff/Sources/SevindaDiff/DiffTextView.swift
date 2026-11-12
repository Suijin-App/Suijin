import AppKit
import SevindaGit
import Synchronization

/// Read-only diff view: a TextKit 2 `NSTextView` (viewport-based layout, so only the visible part of a large diff
/// is laid out) inside an `NSScrollView`, with a line-number ruler, full-width backgrounds for added/deleted lines,
/// and syntax highlighting applied in the background.
///
/// By default lines soft-wrap to the view width: backgrounds then always span the visible width and a narrow pane
/// never needs horizontal scrolling. A side-by-side column turns wrapping off instead (`wrapsLines = false`), so both
/// columns keep one visual line per row and stay aligned; each column then scrolls horizontally on its own.
///
/// Views can be inserted between lines ("zones", used for diff notes): the row above a zone gets paragraph spacing
/// of the zone's height, and the zone's view is a subview of the text view placed in that gap. The text itself is
/// unchanged, so selection, copy and find are not affected.
@MainActor
public final class DiffTextView: NSView {
    public private(set) var diff: FileDiff?
    public private(set) var language: String?

    let scrollView = NSScrollView()
    let textView: DiffNSTextView
    let gutter: DiffGutterView
    private let fragmentProvider = DiffFragmentProvider()
    private(set) var layout = DiffLayout(diff: FileDiff(oldPath: nil, newPath: nil))
    private var highlightTask: Task<Void, Never>?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    /// A view inserted below a row.
    struct Zone {
        var height: CGFloat
        /// Nil for a spacer that only keeps another column aligned.
        var view: NSView?
    }

    /// Zones by row index.
    private(set) var zones: [Int: Zone] = [:]
    private let selectionOverlay = PassThroughView()

    /// Shows the "+" button and accepts drags in the gutter to pick lines for a note.
    var notesEnabled = false {
        didSet {
            guard notesEnabled != oldValue else { return }
            gutter.showsNoteButton = notesEnabled
            if !notesEnabled { hoveredRow = nil }
        }
    }
    /// Called with the lines the user picked in the gutter.
    var onNoteRangeSelected: ((DiffNoteAnchor) -> Void)?
    /// New-side lines a note may point to: shown lines that can hold a zone below them.
    private(set) var commentableLines: Set<Int> = []
    /// Lines shown as selected for a note (while dragging, then while the note is written).
    var highlightedLines: ClosedRange<Int>? {
        didSet {
            guard highlightedLines != oldValue else { return }
            gutter.highlightedLines = highlightedLines
            positionSelectionOverlay()
        }
    }
    private var dragAnchorLine: Int?
    private var hoveredRow: Int? {
        didSet { if hoveredRow != oldValue { gutter.hoveredRow = hoveredRow } }
    }

    /// Soft-wraps lines to the view width (default). When false, lines keep their length, the document is laid out
    /// in full (so every row's position is exact, which side-by-side alignment relies on) and scrolls horizontally.
    var wrapsLines = true {
        didSet { if wrapsLines != oldValue { configureWrapping() } }
    }

    public override init(frame frameRect: NSRect) {
        textView = DiffNSTextView(usingTextLayoutManager: true)
        gutter = DiffGutterView(scrollView: scrollView, textView: textView)
        super.init(frame: frameRect)
        configureTextView()
        configureScrollView()
        gutter.noteDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        highlightTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Shows `diff` in unified form; `language` (see `SyntaxHighlighter.language(forPath:)`) enables highlighting.
    /// Setting the same diff again is a no-op, so SwiftUI updates stay cheap.
    public func setDiff(_ diff: FileDiff, language: String?) {
        guard diff != self.diff || language != self.language else { return }
        self.diff = diff
        self.language = language
        show(DiffLayout(diff: diff), language: language)
    }

    /// A background drawn behind part of a row's text (word-level changes).
    struct WordMark {
        /// Range in the layout's `text`.
        var range: NSRange
        var color: NSColor
    }

    /// Shows a prepared layout (a side-by-side column, or the unified layout from `setDiff`). Removes all zones.
    func show(_ layout: DiffLayout, language: String?, wordMarks: [WordMark] = []) {
        generation += 1
        highlightTask?.cancel()
        removeAllZones()
        highlightedLines = nil
        dragAnchorLine = nil
        hoveredRow = nil

        self.layout = layout
        self.language = language
        fragmentProvider.layout = layout
        gutter.layout = layout
        commentableLines = Self.commentableLines(in: layout)
        if let layoutManager = textView.textLayoutManager {
            // Rendering attributes live on the layout manager, not the text; drop the previous diff's colors.
            layoutManager.removeRenderingAttribute(.foregroundColor, for: layoutManager.documentRange)
            layoutManager.removeRenderingAttribute(.backgroundColor, for: layoutManager.documentRange)
        }
        textView.textStorage?.setAttributedString(Self.attributedText(for: layout))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if let layoutManager = textView.textLayoutManager {
            for mark in wordMarks {
                guard let range = textRange(for: mark.range, in: layoutManager) else { continue }
                layoutManager.addRenderingAttribute(.backgroundColor, value: mark.color, for: range)
            }
        }
        if !wrapsLines { layOutEverything() }
        textView.scroll(.zero)
        gutter.needsDisplay = true

        if let language, SyntaxHighlighter.supportedLanguages.contains(language), !layout.rows.isEmpty {
            startHighlighting(language: language)
        }
    }

    /// Completes when the current highlight pass has been applied (or was cancelled).
    func highlightingCompleted() async {
        await highlightTask?.value
    }

    private static func commentableLines(in layout: DiffLayout) -> Set<Int> {
        DiffNoteAnchoring.placeableLines(in: layout.rows.map { DiffLayout.Line(kind: $0.kind, text: $0.range.length == 0 ? "" : " ", newLine: $0.newLine) })
    }

    // MARK: - Setup

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = DiffTheme.background
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 10
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(String(localized: "Diff", bundle: .module,
                                              comment: "Accessibility label of the diff text"))
        textView.textLayoutManager?.delegate = fragmentProvider
        textView.noteAnchorForSelection = { [weak self] in self?.noteAnchorForSelection() }
        textView.onAddNote = { [weak self] anchor in self?.onNoteRangeSelected?(anchor) }
        textView.onLayout = { [weak self] in
            guard let self else { return }
            gutter.needsDisplay = true
            positionZones()
            positionSelectionOverlay()
        }
        selectionOverlay.wantsLayer = true
        selectionOverlay.isHidden = true
        textView.addSubview(selectionOverlay)
        configureWrapping()
    }

    private func configureWrapping() {
        guard let container = textView.textContainer else { return }
        if wrapsLines {
            container.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            scrollView.hasHorizontalScroller = false
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            scrollView.hasHorizontalScroller = true
            layOutEverything()
        }
        updateBackgroundWidth()
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = DiffTheme.background
        scrollView.documentView = textView
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The ruler follows scrolling and the text view's height estimate, which TextKit 2 refines as it
        // lays out more of the document. Zones stay at the left edge of the visible area when scrolling sideways.
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        for (name, object) in [(NSView.boundsDidChangeNotification, clipView as NSView),
                               (NSView.frameDidChangeNotification, textView as NSView)] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.gutter.needsDisplay = true
                    self?.positionZones()
                }
            })
        }
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: clipView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateBackgroundWidth()
                self?.positionZones()
            }
        })

        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        clipView.addTrackingArea(tracking)
    }

    /// Lays out the whole document (no-wrap mode) and sizes the text view to its widest line.
    private func layOutEverything() {
        guard let layoutManager = textView.textLayoutManager else { return }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let usage = layoutManager.usageBoundsForTextContainer
        let width = max(scrollView.contentSize.width, ceil(usage.maxX) + 2 * (textView.textContainer?.lineFragmentPadding ?? 0))
        textView.minSize = NSSize(width: scrollView.contentSize.width, height: 0)
        if textView.frame.width != width { textView.frame.size.width = width }
        updateBackgroundWidth()
    }

    /// Row backgrounds span the text container when wrapping (nil: read live from the container), the text view
    /// (widest line or visible width) otherwise.
    private func updateBackgroundWidth() {
        var rounded: CGFloat?
        if !wrapsLines {
            let content = textView.textLayoutManager.map { ceil($0.usageBoundsForTextContainer.maxX) + 20 } ?? 0
            let width = max(scrollView.contentSize.width, content)
            textView.minSize = NSSize(width: scrollView.contentSize.width, height: 0)
            if textView.frame.width < width { textView.frame.size.width = width }
            // Round up so resizing a window does not redraw every fragment at each step.
            rounded = ceil(width / 256) * 256
        }
        guard rounded != fragmentProvider.backgroundWidth else { return }
        fragmentProvider.backgroundWidth = rounded
        textView.needsDisplay = true
        if let layoutManager = textView.textLayoutManager,
           let viewport = layoutManager.textViewportLayoutController.viewportRange {
            // Cached fragment surfaces keep their old bounds until they are laid out again.
            layoutManager.invalidateLayout(for: viewport)
            textView.needsLayout = true
        }
    }

    // MARK: - Text

    static func paragraphStyle(spacingAfter spacing: CGFloat = 0) -> NSParagraphStyle {
        let font = DiffTheme.font
        let paragraph = NSMutableParagraphStyle()
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        paragraph.tabStops = []
        paragraph.defaultTabInterval = digitWidth * 4
        paragraph.minimumLineHeight = DiffTheme.lineHeight
        paragraph.maximumLineHeight = DiffTheme.lineHeight
        // Wrapped continuation lines hang under the code instead of starting at column 0.
        paragraph.headIndent = digitWidth * 4
        paragraph.paragraphSpacing = spacing
        return paragraph
    }

    static func attributedText(for layout: DiffLayout) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: DiffTheme.font,
            .foregroundColor: DiffTheme.text,
            .paragraphStyle: paragraphStyle(),
            .baselineOffset: DiffTheme.baselineOffset,
        ]
        let text = NSMutableAttributedString(string: layout.text, attributes: base)
        let secondary: [NSAttributedString.Key: Any] = [.foregroundColor: DiffTheme.secondaryText]
        for row in layout.rows where row.kind == .hunkHeader || row.kind == .noNewlineMarker {
            text.addAttributes(secondary, range: row.range)
        }
        return text
    }

    // MARK: - Zones

    /// Replaces the zones. Rows whose zone height changed get new paragraph spacing; views are added, moved or removed.
    func setZones(_ newZones: [Int: Zone]) {
        let valid = newZones.filter { canHoldZone(row: $0.key) }
        let old = zones
        zones = valid
        for (row, zone) in old where zone.view != nil && zone.view !== valid[row]?.view {
            zone.view?.removeFromSuperview()
        }
        for zone in valid.values {
            if let view = zone.view, view.superview !== textView { textView.addSubview(view) }
        }
        let changed = Set(old.keys).union(valid.keys).filter { old[$0]?.height != valid[$0]?.height }
        if !changed.isEmpty, let storage = textView.textStorage {
            storage.beginEditing()
            for row in changed.sorted() {
                guard let range = paragraphRange(row: row) else { continue }
                storage.addAttribute(.paragraphStyle, value: Self.paragraphStyle(spacingAfter: valid[row]?.height ?? 0), range: range)
            }
            storage.endEditing()
            if !wrapsLines { layOutEverything() }
        }
        positionZones()
        positionSelectionOverlay()
    }

    private func removeAllZones() {
        for zone in zones.values { zone.view?.removeFromSuperview() }
        // The text is replaced right after, which drops the spacing attributes.
        zones = [:]
    }

    private func canHoldZone(row: Int) -> Bool {
        guard layout.rows.indices.contains(row) else { return false }
        return paragraphRange(row: row) != nil
    }

    /// The characters carrying a row's paragraph attributes: its text plus the newline that ends it.
    private func paragraphRange(row: Int) -> NSRange? {
        let range = layout.rows[row].range
        let isLast = row == layout.rows.count - 1
        let length = range.length + (isLast ? 0 : 1)
        return length > 0 ? NSRange(location: range.location, length: length) : nil
    }

    /// The row's text frame in text view coordinates, without the zone spacing below it.
    func rowFrame(_ row: Int) -> NSRect? {
        guard layout.rows.indices.contains(row), let layoutManager = textView.textLayoutManager,
              let location = layoutManager.location(layoutManager.documentRange.location, offsetBy: layout.rows[row].range.location),
              let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let origin = textView.textContainerOrigin
        let height = fragment.textLineFragments.last.map { $0.typographicBounds.maxY } ?? frame.height
        return NSRect(x: 0, y: frame.minY + origin.y, width: textView.bounds.width, height: min(frame.height, height))
    }

    private func positionZones() {
        // The text view's own visible part. The clip view extends under the ruler (its bounds start left of the text) and
        // views no longer clip to their bounds, so `visibleRect` alone can reach under the gutter.
        let clipped = textView.visibleRect.intersection(textView.bounds)
        let visible = clipped.isEmpty ? textView.bounds : clipped
        for (row, zone) in zones {
            guard let view = zone.view else { continue }
            guard let frame = rowFrame(row) else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            let target = NSRect(x: visible.minX, y: frame.maxY, width: visible.width, height: zone.height)
            if view.frame != target { view.frame = target }
        }
    }

    private func positionSelectionOverlay() {
        guard let lines = highlightedLines,
              let first = layout.rows.firstIndex(where: { $0.newLine == lines.lowerBound }),
              let last = layout.rows.lastIndex(where: { $0.newLine == lines.upperBound }),
              let top = rowFrame(first), let bottom = rowFrame(last) else {
            selectionOverlay.isHidden = true
            return
        }
        selectionOverlay.isHidden = false
        selectionOverlay.layer?.backgroundColor = DiffTheme.noteSelection.cgColor(resolvedFor: effectiveAppearance)
        selectionOverlay.frame = NSRect(x: 0, y: top.minY, width: textView.bounds.width, height: bottom.maxY - top.minY)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        positionSelectionOverlay()
    }

    // MARK: - Pointer

    /// The row under a point in text view coordinates.
    func row(atTextViewPoint point: NSPoint) -> Int? {
        guard let layoutManager = textView.textLayoutManager, !layout.rows.isEmpty else { return nil }
        let origin = textView.textContainerOrigin
        let local = CGPoint(x: 1, y: point.y - origin.y)
        guard let fragment = layoutManager.textLayoutFragment(for: local) else {
            return point.y < origin.y ? 0 : nil
        }
        let offset = layoutManager.offset(from: layoutManager.documentRange.location, to: fragment.rangeInElement.location)
        return layout.rowIndex(at: offset)
    }

    public override func mouseMoved(with event: NSEvent) {
        guard notesEnabled else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        hoveredRow = row(atTextViewPoint: point)
    }

    public override func mouseExited(with event: NSEvent) {
        if dragAnchorLine == nil { hoveredRow = nil }
    }

    /// Hovering the gutter shows the button for the row there too.
    func gutterHovered(row: Int?) {
        guard notesEnabled, dragAnchorLine == nil else { return }
        hoveredRow = row
    }

    /// Starts picking lines at `row`; false when that row cannot take a note.
    func beginNoteDrag(at row: Int) -> Bool {
        guard notesEnabled, layout.rows.indices.contains(row), let line = layout.rows[row].newLine,
              commentableLines.contains(line) else { return false }
        dragAnchorLine = line
        highlightedLines = line...line
        return true
    }

    func continueNoteDrag(to row: Int?) {
        guard let anchor = dragAnchorLine, let row, let target = nearestNewLine(to: row) else { return }
        let focus = DiffNoteAnchoring.clampFocus(anchor: anchor, focus: target, commentable: commentableLines)
        highlightedLines = min(anchor, focus)...max(anchor, focus)
        hoveredRow = row
    }

    func endNoteDrag() {
        defer { dragAnchorLine = nil }
        guard dragAnchorLine != nil, let lines = highlightedLines else { return }
        onNoteRangeSelected?(DiffNoteAnchor(from: lines.lowerBound, to: lines.upperBound))
    }

    /// The lines of the text selection (or of the line with the insertion point) that a note can point to: from the
    /// first selected new-side line as far as the selection reaches without crossing a gap.
    func noteAnchorForSelection() -> DiffNoteAnchor? {
        guard notesEnabled else { return nil }
        let selection = textView.selectedRange()
        guard let first = layout.rowIndex(at: selection.location),
              let last = layout.rowIndex(at: NSMaxRange(selection) - (selection.length > 0 ? 1 : 0)) else { return nil }
        let lines = layout.rows[first...max(first, last)].compactMap(\.newLine).filter { commentableLines.contains($0) }
        guard let start = lines.first, let end = lines.last else { return nil }
        let focus = DiffNoteAnchoring.clampFocus(anchor: start, focus: end, commentable: commentableLines)
        return DiffNoteAnchor(from: start, to: focus)
    }

    /// The new-side line of `row`, or of the closest row above it (then below) that has one: deleted rows and hunk
    /// headers have none.
    private func nearestNewLine(to row: Int) -> Int? {
        let rows = layout.rows
        guard rows.indices.contains(row) else { return nil }
        if let line = rows[row].newLine { return line }
        for index in stride(from: row - 1, through: 0, by: -1) { if let line = rows[index].newLine { return line } }
        for index in (row + 1)..<rows.count { if let line = rows[index].newLine { return line } }
        return nil
    }

    // MARK: - Highlighting

    private func startHighlighting(language: String) {
        let layout = self.layout
        let generation = self.generation
        highlightTask = Task { [weak self] in
            let spans = await Self.documentSpans(layout: layout, language: language)
            guard !Task.isCancelled, !spans.isEmpty else { return }
            await self?.apply(spans, generation: generation)
        }
    }

    @concurrent
    private static func documentSpans(layout: DiffLayout, language: String) async -> [HighlightSpan] {
        async let old = SyntaxHighlighter.highlight(layout.oldSideText, language: language)
        async let new = SyntaxHighlighter.highlight(layout.newSideText, language: language)
        let (oldSpans, newSpans) = await (old, new)
        guard !Task.isCancelled else { return [] }
        return layout.documentSpans(oldSide: oldSpans, newSide: newSpans)
    }

    /// Applies colors as TextKit 2 rendering attributes (no relayout), visible range first, then the rest
    /// in batches that yield to the main run loop so scrolling stays responsive.
    private func apply(_ spans: [HighlightSpan], generation: Int) async {
        guard let layoutManager = textView.textLayoutManager else { return }
        let visible = visibleCharacterRange() ?? NSRange(location: 0, length: 0)
        var first: [HighlightSpan] = []
        var rest: [HighlightSpan] = []
        rest.reserveCapacity(spans.count)
        for span in spans {
            if NSIntersectionRange(span.range, visible).length > 0 { first.append(span) } else { rest.append(span) }
        }
        let colors = Dictionary(uniqueKeysWithValues: TokenKind.allCases.map { ($0, DiffTheme.color(for: $0)) })
        let batchSize = 2_000
        for batch in [first] + stride(from: 0, to: rest.count, by: batchSize).map({
            Array(rest[$0..<min($0 + batchSize, rest.count)])
        }) {
            guard !Task.isCancelled, generation == self.generation else { return }
            for span in batch {
                guard let range = textRange(for: span.range, in: layoutManager), let color = colors[span.token] else {
                    continue
                }
                layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: range)
            }
            await Task.yield()
        }
    }

    private func textRange(for range: NSRange, in layoutManager: NSTextLayoutManager) -> NSTextRange? {
        let start = layoutManager.documentRange.location
        guard let lower = layoutManager.location(start, offsetBy: range.location),
              let upper = layoutManager.location(lower, offsetBy: range.length) else { return nil }
        return NSTextRange(location: lower, end: upper)
    }

    private func visibleCharacterRange() -> NSRange? {
        guard let layoutManager = textView.textLayoutManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange else { return nil }
        let start = layoutManager.documentRange.location
        let lower = layoutManager.offset(from: start, to: viewport.location)
        let upper = layoutManager.offset(from: start, to: viewport.endLocation)
        return NSRange(location: lower, length: max(0, upper - lower))
    }
}

/// A view that never takes the mouse, for overlays drawn above the text.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSColor {
    /// The color resolved for an appearance, for layers (which do not resolve dynamic colors themselves).
    func cgColor(resolvedFor appearance: NSAppearance) -> CGColor {
        var color = cgColor
        appearance.performAsCurrentDrawingAppearance { color = self.cgColor }
        return color
    }
}

/// `NSTextView` that reports layout passes: TextKit 2 lays out the viewport during `layout()`, and the
/// line-number ruler must redraw afterwards. (The viewport delegate callbacks are only overridable from
/// macOS 27, above our deployment target.)
final class DiffNSTextView: NSTextView {
    var onLayout: (() -> Void)?
    /// The lines "Add Note…" would note, nil when notes are off or nothing selected can take one.
    var noteAnchorForSelection: (() -> DiffNoteAnchor?)?
    var onAddNote: ((DiffNoteAnchor) -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    /// Puts "Add Note…" for the selected lines at the top of the context menu (the pointer-free way to note lines).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let anchor = noteAnchorForSelection?() {
            let item = NSMenuItem(title: String(localized: "Add Note on \(anchor.label)…", bundle: .module,
                                                comment: "Context menu item of the diff text; the argument is the location"),
                                  action: #selector(addNote(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = AnchorBox(anchor)
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func addNote(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? AnchorBox else { return }
        onAddNote?(box.anchor)
    }

    private final class AnchorBox: NSObject {
        let anchor: DiffNoteAnchor
        init(_ anchor: DiffNoteAnchor) { self.anchor = anchor }
    }
}

/// Supplies layout fragments that paint the row background across the full row width.
/// TextKit 2 has no paragraph-level full-width background attribute (`.backgroundColor` covers glyphs
/// only, and text blocks force TextKit 1), so a custom fragment is the supported route.
final class DiffFragmentProvider: NSObject, NSTextLayoutManagerDelegate {
    /// TextKit may ask for fragments from whichever thread drives layout, so the layout is a locked snapshot.
    private let current = Mutex(DiffLayout(diff: FileDiff(oldPath: nil, newPath: nil)))
    private let width = Mutex<CGFloat?>(nil)

    var layout: DiffLayout {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }

    /// How wide row backgrounds are painted, in text container coordinates; nil means the text container's width.
    var backgroundWidth: CGFloat? {
        get { width.withLock { $0 } }
        set { width.withLock { $0 = newValue } }
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = DiffLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragment.provider = self
        let offset = textLayoutManager.offset(from: textLayoutManager.documentRange.location, to: location)
        let kind = current.withLock { layout in layout.rowIndex(at: offset).map { layout.rows[$0].kind } }
        if let kind { fragment.background = DiffTheme.rowBackground(kind) }
        return fragment
    }
}

final class DiffLayoutFragment: NSTextLayoutFragment {
    nonisolated(unsafe) var background: NSColor?
    nonisolated(unsafe) weak var provider: DiffFragmentProvider?

    /// The background covers the row's lines, not the zone spacing below the paragraph.
    private var backgroundRect: CGRect? {
        guard background != nil,
              let width = provider?.backgroundWidth ?? textLayoutManager?.textContainer?.size.width, width > 0 else { return nil }
        let frame = layoutFragmentFrame
        let height = textLineFragments.last.map { min(frame.height, $0.typographicBounds.maxY) } ?? frame.height
        return CGRect(x: -frame.minX, y: 0, width: width, height: height)
    }

    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds
        guard let rect = backgroundRect else { return bounds }
        return bounds.union(rect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let background, let rect = backgroundRect {
            context.saveGState()
            context.setFillColor(background.cgColor)
            context.fill(rect.offsetBy(dx: point.x, dy: point.y))
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}
