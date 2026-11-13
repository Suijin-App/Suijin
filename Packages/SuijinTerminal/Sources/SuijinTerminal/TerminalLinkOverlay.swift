import AppKit

/// Where the cells of a terminal's screen are in its view: rows count from the top, the view's origin is at the bottom
/// left (SwiftTerm's views are not flipped).
public struct TerminalCellGeometry: Equatable, Sendable {
    public var cellSize: CGSize
    /// The height of the view the grid is drawn in; row 0 touches its top edge.
    public var viewHeight: CGFloat
    /// From the bottom of a cell up to the text baseline.
    public var baselineOffset: CGFloat
    /// The font's underline position: below the baseline when negative.
    public var underlinePosition: CGFloat
    /// The device scale, to keep lines on whole pixels.
    public var scale: CGFloat

    public init(cellSize: CGSize, viewHeight: CGFloat, baselineOffset: CGFloat, underlinePosition: CGFloat, scale: CGFloat) {
        self.cellSize = cellSize
        self.viewHeight = viewHeight
        self.baselineOffset = baselineOffset
        self.underlinePosition = underlinePosition
        self.scale = max(1, scale)
    }

    /// The cells `columns` of screen row `row`.
    public func rect(row: Int, columns: Range<Int>) -> CGRect {
        CGRect(x: CGFloat(columns.lowerBound) * cellSize.width, y: viewHeight - CGFloat(row + 1) * cellSize.height,
               width: CGFloat(columns.count) * cellSize.width, height: cellSize.height)
    }

    /// An underline of `thickness` points below the text of those cells, on whole device pixels.
    public func underline(row: Int, columns: Range<Int>, thickness: CGFloat) -> CGRect {
        let cells = rect(row: row, columns: columns)
        let top = cells.minY + baselineOffset + min(-1, underlinePosition)
        let pixelTop = (top * scale).rounded() / scale
        let pixelThickness = max(1, (thickness * scale).rounded()) / scale
        // Never below the cell, where it would touch the next row's text.
        return CGRect(x: cells.minX, y: max(cells.minY, pixelTop - pixelThickness), width: cells.width, height: pixelThickness)
    }

    /// The screen row and column at `point`, or nil outside the grid.
    public func cell(at point: CGPoint, rows: Int, columns: Int) -> (row: Int, column: Int)? {
        guard cellSize.width > 0, cellSize.height > 0, point.x >= 0, point.y <= viewHeight else { return nil }
        let column = Int(point.x / cellSize.width)
        let row = Int((viewHeight - point.y) / cellSize.height)
        guard row >= 0, row < rows, column >= 0, column < columns else { return nil }
        return (row, column)
    }
}

/// Underlines the paths and links found on a terminal's screen, above the text and below the caret, find bar and
/// scroller.
///
/// A view of its own because SwiftTerm has no API to decorate a range of cells without changing the buffer (its
/// underline is a cell attribute the program sets). It takes no clicks (`hitTest` returns nil), so selection, scrolling,
/// mouse reporting and focusing the pane reach the terminal as before. It reports the pointer entering and leaving a
/// mark through tracking areas without `.mouseMoved`, which on macOS 26 can make the window server synthesize clicks
/// (the reason SwiftTerm avoids that option too).
@MainActor
final class TerminalLinkOverlay: NSView, NSViewToolTipOwner {
    struct Mark: Equatable {
        /// Underlined cells, one rect per row, in view coordinates.
        var rects: [CGRect]
        var underlines: [CGRect]
        var emphasizedUnderlines: [CGRect]
        var toolTip: String
    }

    var marks: [Mark] = [] {
        didSet {
            guard marks != oldValue else { return }
            needsDisplay = true
            rebuildTracking()
        }
    }
    /// The mark under the pointer that a click would open: drawn stronger, with the pointing-hand cursor and its tooltip.
    var emphasized: Int? {
        didSet {
            guard emphasized != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Called when the pointer enters or leaves a mark.
    var onPointerCrossing: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !marks.isEmpty else { return }
        var accent = NSColor.controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor }
        for (index, mark) in marks.enumerated() {
            let isEmphasized = index == emphasized
            (isEmphasized ? accent : accent.withAlphaComponent(0.55)).setFill()
            for rect in isEmphasized ? mark.emphasizedUnderlines : mark.underlines where rect.intersects(dirtyRect) {
                rect.fill()
            }
        }
    }

    // MARK: Pointer

    private var trackingAreasAdded: [NSTrackingArea] = []

    private func rebuildTracking() {
        for area in trackingAreasAdded { removeTrackingArea(area) }
        trackingAreasAdded.removeAll()
        removeAllToolTips()
        for (index, mark) in marks.enumerated() {
            for rect in mark.rects {
                let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self,
                                          userInfo: ["mark": index])
                addTrackingArea(area)
                trackingAreasAdded.append(area)
                addToolTip(rect, owner: self, userData: nil)
            }
        }
        window?.invalidateCursorRects(for: self)
    }

    override func mouseEntered(with event: NSEvent) { onPointerCrossing?() }
    override func mouseExited(with event: NSEvent) { onPointerCrossing?() }

    override func resetCursorRects() {
        guard let emphasized, marks.indices.contains(emphasized) else { return }
        for rect in marks[emphasized].rects { addCursorRect(rect, cursor: .pointingHand) }
    }

    /// Only the emphasized mark has a tooltip: with ⌘-click opening, a path shows its full location while ⌘ is held,
    /// and plain hovering over output stays quiet.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let emphasized, marks.indices.contains(emphasized),
              marks[emphasized].rects.contains(where: { $0.contains(point) }) else { return "" }
        return marks[emphasized].toolTip
    }
}
