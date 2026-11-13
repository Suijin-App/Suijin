import AppKit

/// Pointer handling of the gutter for notes: hovering a row shows its "+" button, pressing on a row that can take a
/// note starts picking lines, dragging extends the range (clamped to the hunk, auto-scrolling at the edges) and
/// releasing opens the note composer for those lines.
extension DiffGutterView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                              .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard showsNoteButton else { return }
        noteDelegate?.gutterHovered(row: row(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        guard showsNoteButton, !isDraggingNoteRange else { return }
        noteDelegate?.gutterHovered(row: nil)
    }

    override func cursorUpdate(with event: NSEvent) {
        if showsNoteButton, let row = row(for: event), layout.rows[row].newLine != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard showsNoteButton, let delegate = noteDelegate, let row = row(for: event),
              delegate.beginNoteDrag(at: row) else {
            super.mouseDown(with: event)
            return
        }
        isDraggingNoteRange = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingNoteRange else {
            super.mouseDragged(with: event)
            return
        }
        // Scroll when the pointer leaves the visible rows, then pick the row now under it.
        textView?.autoscroll(with: event)
        noteDelegate?.continueNoteDrag(to: row(for: event, clampedToVisible: true))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingNoteRange else {
            super.mouseUp(with: event)
            return
        }
        isDraggingNoteRange = false
        noteDelegate?.endNoteDrag()
    }

    /// The diff row at the event's height; above or below the visible rows when clamped, the first or last visible row.
    private func row(for event: NSEvent, clampedToVisible: Bool = false) -> Int? {
        guard let textView, let delegate = noteDelegate else { return nil }
        var point = textView.convert(event.locationInWindow, from: nil)
        if clampedToVisible {
            let visible = textView.visibleRect
            point.y = min(max(point.y, visible.minY + 1), visible.maxY - 1)
        }
        return delegate.row(atTextViewPoint: point)
    }
}
