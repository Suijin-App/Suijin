import AppKit
import MercuryGit
import SwiftUI
import Testing
@testable import MercuryDiff

@MainActor
struct DiffNoteViewTests {
    private func window(for view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.layoutIfNeeded()
        return window
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test func zoneOpensAGapBelowItsRowAndHoldsItsView() throws {
        let view = DiffTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = window(for: view, size: view.frame.size)
        defer { window.close() }
        view.setDiff(Fixtures.swiftDiff, language: nil)
        window.displayIfNeeded()
        let before = try #require(view.rowFrame(4))
        let zoneView = NSView()
        view.setZones([3: DiffTextView.Zone(height: 80, view: zoneView)])
        window.displayIfNeeded()
        let anchor = try #require(view.rowFrame(3))
        let after = try #require(view.rowFrame(4))
        #expect(abs(after.minY - before.minY - 80) < 0.5)
        #expect(zoneView.superview === view.textView)
        #expect(abs(zoneView.frame.minY - anchor.maxY) < 0.5)
        #expect(zoneView.frame.height == 80)
        // Regression: the clip view extends under the gutter, and a zone placed from its bounds slid under the gutter.
        #expect(zoneView.frame.minX >= 0 && zoneView.frame.maxX <= view.textView.bounds.maxX + 0.5)
        // The text is unchanged: the gap is paragraph spacing, not inserted characters.
        #expect(view.textView.string == view.layout.text)

        view.setZones([:])
        window.displayIfNeeded()
        #expect(zoneView.superview == nil)
        #expect(abs((view.rowFrame(4)?.minY ?? 0) - before.minY) < 0.5)
    }

    @Test func highlightsSurviveZoneChanges() async throws {
        let view = DiffTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = window(for: view, size: view.frame.size)
        defer { window.close() }
        let layoutManager = try #require(view.textView.textLayoutManager)
        func coloredRuns() -> Int {
            var count = 0
            layoutManager.enumerateRenderingAttributes(from: layoutManager.documentRange.location, reverse: false) { _, attributes, _ in
                if attributes[.foregroundColor] != nil { count += 1 }
                return true
            }
            return count
        }
        view.setDiff(Fixtures.swiftDiff, language: "swift")
        await view.highlightingCompleted()
        let colored = coloredRuns()
        #expect(colored > 0)
        view.setZones([2: DiffTextView.Zone(height: 60, view: NSView()), 5: DiffTextView.Zone(height: 30, view: nil)])
        window.displayIfNeeded()
        #expect(coloredRuns() == colored)
    }

    @Test func emptyLastRowCannotHoldAZone() {
        let diff = FileDiff(oldPath: "a", newPath: "a", hunks: [
            DiffHunk(header: "@@ -1 +1,2 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 2, lines: [
                DiffLine(kind: .context, text: "x", oldLine: 1, newLine: 1),
                DiffLine(kind: .added, text: "", oldLine: nil, newLine: 2),
            ]),
        ])
        let view = DiffTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.setDiff(diff, language: nil)
        #expect(view.commentableLines == [1])
        view.setZones([2: DiffTextView.Zone(height: 40, view: NSView())])
        #expect(view.zones.isEmpty)
    }

    @Test func draggingPicksAClampedRange() {
        let view = DiffTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.setDiff(Fixtures.swiftDiff, language: nil)
        view.notesEnabled = true
        var picked: DiffNoteAnchor?
        view.onNoteRangeSelected = { picked = $0 }
        // Rows: 0 header, 1 ctx(1), 2 del, 3 add(2), 4 ctx(3), 5 add(4), 6 ctx(5), 7 marker, 8 header, 9 del, 10 add(41), 11 ctx(42).
        #expect(!view.beginNoteDrag(at: 2)) // a deleted line cannot take a note
        #expect(view.beginNoteDrag(at: 5))
        view.continueNoteDrag(to: 2) // over the deleted row: the line above it counts
        #expect(view.highlightedLines == 1...4)
        view.continueNoteDrag(to: 11) // across the hunk gap: stops at line 5
        #expect(view.highlightedLines == 4...5)
        view.endNoteDrag()
        #expect(picked == DiffNoteAnchor(startLine: 4, lineNumber: 5))
    }

    @Test func controllerShowsDraftThenSavedNoteInOneZone() throws {
        let container = DiffDocumentContainerView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = window(for: container, size: container.frame.size)
        defer { window.close() }
        var created: [(DiffNoteAnchor, String)] = []
        var notes: [DiffNoteItem] = []
        func configuration() -> DiffNotesConfiguration {
            DiffNotesConfiguration(notes: notes, actions: DiffNoteActions(
                create: { created.append(($0, $1)) }, update: { _, _ in }, delete: { _ in }))
        }
        container.show(Fixtures.swiftDiff, language: nil, notes: configuration())
        #expect(container.textView.notesEnabled)
        #expect(container.textView.gutter.showsNoteButton)

        container.notesController.beginDraft(DiffNoteAnchor(startLine: 2, lineNumber: 3))
        spin()
        let row = try #require(container.textView.layout.rowIndex(newLine: 3))
        let zone = try #require(container.textView.zones[row])
        #expect(zone.view != nil && zone.height > 40)
        #expect(container.textView.highlightedLines == 2...3)

        container.notesController.saveDraft("Check this")
        #expect(created.count == 1 && created.first?.0 == DiffNoteAnchor(startLine: 2, lineNumber: 3))
        #expect(container.textView.zones.isEmpty)
        notes = [DiffNoteItem(id: UUID(), anchor: DiffNoteAnchor(startLine: 2, lineNumber: 3), body: "Check this",
                              isSent: false, isStale: false)]
        container.show(Fixtures.swiftDiff, language: nil, notes: configuration())
        spin()
        #expect(container.textView.zones[row]?.view != nil)
        #expect(container.textView.highlightedLines == nil)

        // Without a configuration notes are off.
        container.show(Fixtures.swiftDiff, language: nil, notes: nil)
        #expect(!container.textView.notesEnabled && container.textView.zones.isEmpty)
    }

    @Test func sideBySideNotesGoRightWithAlignedSpacersLeft() throws {
        let container = DiffDocumentContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
        let window = window(for: container, size: container.frame.size)
        defer { window.close() }
        let note = DiffNoteItem(id: UUID(), anchor: DiffNoteAnchor(lineNumber: 2), body: "Why?", isSent: true, isStale: false)
        container.show(Fixtures.swiftDiff, language: nil, mode: .sideBySide, notes: DiffNotesConfiguration(
            notes: [note], actions: DiffNoteActions(create: { _, _ in }, update: { _, _ in }, delete: { _ in })))
        spin()
        let sideBySide = try #require(container.sideBySideView)
        #expect(container.textView.isHidden && !sideBySide.isHidden)
        let row = try #require(sideBySide.right.layout.rowIndex(newLine: 2))
        let zone = try #require(sideBySide.right.zones[row])
        #expect(zone.view != nil)
        #expect(sideBySide.left.zones[row]?.view == nil)
        #expect(sideBySide.left.zones[row]?.height == zone.height)
        #expect(sideBySide.right.notesEnabled && !sideBySide.left.notesEnabled)
        window.displayIfNeeded()
        let below = row + 1
        #expect(abs((sideBySide.left.rowFrame(below)?.minY ?? -1) - (sideBySide.right.rowFrame(below)?.minY ?? -2)) < 0.5)
    }
}

@MainActor
struct DiffNoteSelectionTests {
    @Test func selectedTextNotesItsNewSideLines() {
        let view = DiffTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.setDiff(Fixtures.swiftDiff, language: nil)
        #expect(view.noteAnchorForSelection() == nil) // notes off
        view.notesEnabled = true
        let layout = view.layout
        // From the deleted row 2 into the context row 4: new lines 2...3.
        let start = layout.rows[2].range.location
        view.textView.setSelectedRange(NSRange(location: start, length: NSMaxRange(layout.rows[4].range) - start))
        #expect(view.noteAnchorForSelection() == DiffNoteAnchor(startLine: 2, lineNumber: 3))
        // An insertion point on a context line notes that line.
        view.textView.setSelectedRange(NSRange(location: layout.rows[6].range.location + 1, length: 0))
        #expect(view.noteAnchorForSelection() == DiffNoteAnchor(lineNumber: 5))
        // Only a deleted line selected: nothing to note.
        view.textView.setSelectedRange(layout.rows[9].range)
        #expect(view.noteAnchorForSelection() == nil)
    }
}
