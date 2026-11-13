import AppKit
import SuijinGit

/// Line-number gutter with old and new columns (or one of them, for a side-by-side column) plus a +/− sign column,
/// and, when notes are on, a column for the "+" button that adds a note.
///
/// Built on `NSRulerView`, AppKit's scroll-view gutter, so tiling next to the text and scroll tracking
/// come from the system. Only the marks are custom: AppKit has no line-number ruler, let alone one with
/// two number columns, so `drawHashMarksAndLabels(in:)` draws them from the TextKit 2 layout fragments
/// currently in the viewport.
@MainActor
final class DiffGutterView: NSRulerView {
    enum Columns { case both, old, new }

    var layout = DiffLayout(diff: FileDiff(oldPath: nil, newPath: nil)) {
        didSet {
            if layout.maxLineNumber != oldValue.maxLineNumber { updateThickness() }
            needsDisplay = true
        }
    }

    var columns = Columns.both {
        didSet { if columns != oldValue { updateThickness() } }
    }
    var showsNoteButton = false {
        didSet { if showsNoteButton != oldValue { updateThickness() } }
    }
    /// The row whose "+" button is shown.
    var hoveredRow: Int? {
        didSet { if hoveredRow != oldValue { needsDisplay = true } }
    }
    var highlightedLines: ClosedRange<Int>? {
        didSet { if highlightedLines != oldValue { needsDisplay = true } }
    }
    weak var noteDelegate: DiffTextView?
    /// True between a mouse-down that started picking lines and the mouse-up.
    var isDraggingNoteRange = false

    private(set) weak var textView: NSTextView?
    private(set) var metrics = Metrics(digits: Metrics.minimumDigits, columns: .both, noteButton: false)

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        // NSView no longer clips drawing to its bounds by default (macOS 14+). Unclipped, this ruler's
        // background covered the whole text column in on-screen windows.
        clipsToBounds = true
        setAccessibilityElement(false)
        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override var requiredThickness: CGFloat { ruleThickness }

    override func draw(_ dirtyRect: NSRect) {
        // AppKit can pass the ruler a dirty rect wider than its bounds (it is tiled over the clip view);
        // an opaque fill of the whole rect would paint over the diff text, so stay inside the bounds.
        let rect = dirtyRect.intersection(bounds)
        guard !rect.isEmpty else { return }
        DiffTheme.background.setFill()
        rect.fill()
        drawHashMarksAndLabels(in: rect)
        DiffTheme.separator.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.textLayoutManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange,
              !layout.rows.isEmpty else { return }
        let documentStart = layoutManager.documentRange.location
        let containerOrigin = textView.textContainerOrigin
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: DiffTheme.gutterFont,
                                                               .foregroundColor: DiffTheme.gutterText]
        let width = bounds.width - 1

        layoutManager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else {
                return false
            }
            let frame = fragment.layoutFragmentFrame
            let top = convert(NSPoint(x: 0, y: frame.minY + containerOrigin.y), from: textView).y
            if top > rect.maxY { return false }
            // Rows end before any note spacing below them.
            let height = fragment.textLineFragments.last.map { min(frame.height, $0.typographicBounds.maxY) } ?? frame.height
            if top + frame.height < rect.minY { return true }
            let offset = layoutManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            guard let index = layout.rowIndex(at: offset) else { return true }
            let row = layout.rows[index]

            if let lines = highlightedLines, let new = row.newLine, lines.contains(new) {
                DiffTheme.noteSelection.setFill()
                NSRect(x: 0, y: top, width: width, height: height).fill()
            } else if let background = DiffTheme.gutterBackground(row.kind) {
                background.setFill()
                NSRect(x: 0, y: top, width: width, height: height).fill()
            }
            // Baseline of the first visual line (so wrapped rows number their first line). `glyphOrigin`
            // excludes the `.baselineOffset` attribute the text is drawn with, so apply it here too.
            guard let line = fragment.textLineFragments.first else { return true }
            let baseline = top + line.typographicBounds.minY + line.glyphOrigin.y - DiffTheme.baselineOffset
            if let old = row.oldLine, columns != .new {
                drawRightAligned(String(old), right: metrics.oldRight, baseline: baseline, attributes: numberAttributes)
            }
            if let new = row.newLine, columns != .old {
                drawRightAligned(String(new), right: metrics.newRight, baseline: baseline, attributes: numberAttributes)
            }
            let sign: (String, NSColor)? = switch row.kind {
            case .added: ("+", DiffTheme.addedSign)
            case .deleted: ("−", DiffTheme.deletedSign)
            default: nil
            }
            if let (symbol, color) = sign {
                (symbol as NSString).draw(with: NSRect(x: metrics.signX, y: baseline, width: metrics.digitWidth * 2, height: 0),
                                          options: [], attributes: [.font: DiffTheme.gutterFont, .foregroundColor: color])
            }
            if showsNoteButton, index == hoveredRow, row.newLine != nil {
                drawNoteButton(centerY: top + line.typographicBounds.midY)
            }
            return true
        }
    }

    /// The "+" that adds a note, drawn with the system symbol in the accent color.
    private func drawNoteButton(centerY: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: DiffTheme.gutterFont.pointSize + 2, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .controlAccentColor]))
        guard let image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let rect = NSRect(x: metrics.noteButtonX + (Metrics.noteButtonWidth - size.width) / 2,
                          y: centerY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawRightAligned(_ string: String, right: CGFloat, baseline: CGFloat,
                                  attributes: [NSAttributedString.Key: Any]) {
        let width = CGFloat(string.utf16.count) * metrics.digitWidth
        // Without `.usesLineFragmentOrigin` the rect origin is the baseline origin.
        (string as NSString).draw(with: NSRect(x: right - width, y: baseline, width: width, height: 0),
                                  options: [], attributes: attributes)
    }

    private func updateThickness() {
        metrics = Metrics(digits: max(Metrics.minimumDigits, String(layout.maxLineNumber).count), columns: columns,
                          noteButton: showsNoteButton)
        ruleThickness = metrics.thickness
        scrollView?.tile()
        needsDisplay = true
    }

    struct Metrics {
        static let minimumDigits = 3
        static let noteButtonWidth: CGFloat = 20
        let digitWidth: CGFloat
        let noteButtonX: CGFloat
        let oldRight: CGFloat
        let newRight: CGFloat
        let signX: CGFloat
        let thickness: CGFloat

        @MainActor
        init(digits: Int, columns: Columns, noteButton: Bool) {
            digitWidth = ("0" as NSString).size(withAttributes: [.font: DiffTheme.gutterFont]).width
            let column = CGFloat(digits) * digitWidth
            noteButtonX = 2
            let start = noteButton ? noteButtonX + Self.noteButtonWidth : 0
            switch columns {
            case .both:
                oldRight = start + 10 + column
                newRight = oldRight + 10 + column
            case .old:
                oldRight = start + 10 + column
                newRight = oldRight
            case .new:
                newRight = start + 10 + column
                oldRight = newRight
            }
            signX = max(oldRight, newRight) + 10
            thickness = ceil(signX + digitWidth + 6)
        }
    }
}
