import AppKit
import SevindaUI
import Observation
import SwiftUI

/// Observable note state of one diff: the saved notes and the note being written. Zone views read it directly, so
/// typing in the composer re-renders only that zone.
@MainActor
@Observable
final class DiffNotesModel {
    struct Draft: Equatable {
        var anchor: DiffNoteAnchor
        var text: String
    }

    var notes: [DiffNoteItem] = []
    var draft: Draft?
    @ObservationIgnored var actions: DiffNoteActions?

    func notes(endingAt line: Int) -> [DiffNoteItem] {
        notes.filter { $0.anchor.lineNumber == line }
    }
}

/// Places the notes of a diff between its lines: one zone below each line that notes end on (or the draft is
/// anchored to), holding those notes' cards and the composer. In side-by-side mode the zones live in the right
/// column and the left column gets spacers of the same heights, so rows stay aligned.
@MainActor
final class DiffNotesController {
    let model = DiffNotesModel()
    private(set) weak var primary: DiffTextView?
    private weak var mirror: DiffTextView?
    /// Zone views by the line they sit below; kept while the line keeps a zone, so card editing state survives.
    private var hosts: [Int: NSHostingView<DiffNoteZoneView>] = [:]
    private var heights: [Int: CGFloat] = [:]
    private var isEnabled = false

    /// Notes are shown in `primary`; `mirror` (the left column) gets spacers.
    func attach(primary: DiffTextView?, mirror: DiffTextView?) {
        if self.primary !== primary {
            self.primary?.notesEnabled = false
            self.primary?.onNoteRangeSelected = nil
            self.primary?.setZones([:])
        }
        if self.mirror !== mirror { self.mirror?.setZones([:]) }
        self.primary = primary
        self.mirror = mirror
        primary?.onNoteRangeSelected = { [weak self] anchor in self?.beginDraft(anchor) }
        apply()
    }

    /// New notes (or none, disabling notes) for the current diff.
    func update(_ configuration: DiffNotesConfiguration?) {
        isEnabled = configuration != nil
        model.actions = configuration?.actions
        let notes = configuration?.notes ?? []
        if model.notes != notes { model.notes = notes }
        if !isEnabled { model.draft = nil }
        #if DEBUG
        openScreenshotDraftIfRequested()
        #endif
        apply()
    }

    #if DEBUG
    /// Screenshot runs open the composer directly: `-MercuryDiffNoteDraft <line>` (or `<start>-<end>`), once per launch.
    private static var didOpenScreenshotDraft = false

    private func openScreenshotDraftIfRequested() {
        guard isEnabled, !Self.didOpenScreenshotDraft, let primary,
              let value = UserDefaults.standard.string(forKey: "MercuryDiffNoteDraft") else { return }
        let bounds = value.split(separator: "-").compactMap { Int($0) }
        guard let last = bounds.last, primary.commentableLines.contains(last) else { return }
        Self.didOpenScreenshotDraft = true
        model.draft = DiffNotesModel.Draft(anchor: DiffNoteAnchor(from: bounds.first ?? last, to: last),
                                           text: "Rename this to make the timeout explicit.")
        if let row = primary.layout.rowIndex(newLine: bounds.first ?? last) { primary.gutter.hoveredRow = row }
    }
    #endif

    /// Forgets the draft, for example when another file is shown.
    func reset() {
        model.draft = nil
        primary?.highlightedLines = nil
    }

    func beginDraft(_ anchor: DiffNoteAnchor) {
        // Keep text already typed when the user re-picks the lines of an open draft.
        model.draft = DiffNotesModel.Draft(anchor: anchor, text: model.draft?.text ?? "")
        apply()
    }

    func cancelDraft() {
        model.draft = nil
        apply()
    }

    func saveDraft(_ body: String) {
        guard let draft = model.draft, !body.isEmpty else { return }
        model.draft = nil
        model.actions?.create(draft.anchor, body)
        apply()
    }

    /// Lines that get a zone in the current primary view.
    private func zoneLines() -> [Int] {
        guard isEnabled, let primary else { return [] }
        var lines = Set(model.notes.map(\.anchor.lineNumber).filter { $0 > 0 })
        if let draft = model.draft { lines.insert(draft.anchor.lineNumber) }
        return lines.filter { primary.commentableLines.contains($0) }.sorted()
    }

    /// Rebuilds the zones from the model: creates or drops zone views and pushes heights to both columns.
    func apply() {
        guard let primary else { return }
        primary.notesEnabled = isEnabled
        primary.highlightedLines = model.draft.map(\.anchor.lines)
        let lines = zoneLines()
        for line in hosts.keys where !lines.contains(line) {
            hosts[line] = nil
            heights[line] = nil
        }
        var zones: [Int: DiffTextView.Zone] = [:]
        var spacers: [Int: DiffTextView.Zone] = [:]
        for line in lines {
            guard let row = primary.layout.rowIndex(newLine: line) else { continue }
            let host = hosts[line] ?? makeHost(line: line, width: primary.scrollView.contentSize.width)
            hosts[line] = host
            let height = heights[line] ?? measure(host, width: primary.scrollView.contentSize.width)
            heights[line] = height
            zones[row] = DiffTextView.Zone(height: height, view: host)
            spacers[row] = DiffTextView.Zone(height: height, view: nil)
        }
        primary.setZones(zones)
        mirror?.setZones(spacers)
    }

    private func makeHost(line: Int, width: CGFloat) -> NSHostingView<DiffNoteZoneView> {
        let view = DiffNoteZoneView(line: line, model: model, controller: self)
        let host = NSHostingView(rootView: view)
        // Placed by frame in the text view; SwiftUI must not resize it.
        host.sizingOptions = []
        // Inside a scroll view the hosting view would inherit the window's safe areas (toolbar); a zone has none.
        host.safeAreaRegions = []
        host.frame = NSRect(x: 0, y: 0, width: max(width, 100), height: 1)
        return host
    }

    private func measure(_ host: NSHostingView<DiffNoteZoneView>, width: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: host.rootView)
        let size = controller.sizeThatFits(in: NSSize(width: max(width, 100), height: .greatestFiniteMagnitude))
        guard size.height.isFinite, size.height > 0 else { return 1 }
        return ceil(size.height)
    }

    /// The zone at `line` reported its content height (it grows while typing, shrinks when a card closes).
    func zone(_ line: Int, heightChanged height: CGFloat) {
        let rounded = ceil(height)
        guard rounded.isFinite, rounded > 0, hosts[line] != nil, heights[line] != rounded else { return }
        heights[line] = rounded
        apply()
    }
}

/// The contents of one zone: the cards of the notes ending on `line`, then the composer when the draft ends there.
struct DiffNoteZoneView: View {
    let line: Int
    let model: DiffNotesModel
    let controller: DiffNotesController

    var body: some View {
        VStack(alignment: .leading, spacing: MercurySpacing.s) {
            ForEach(model.notes(endingAt: line)) { note in
                DiffNoteCard(note: note,
                             onSave: { body in model.actions?.update(note.id, body) },
                             onDelete: { model.actions?.delete(note.id) })
            }
            if let draft = model.draft, draft.anchor.lineNumber == line {
                DiffNoteComposer(
                    title: DiffNoteCard.title(for: draft.anchor),
                    text: Binding(get: { model.draft?.text ?? "" }, set: { model.draft?.text = $0 }),
                    saveTitle: String(localized: "Add Note", bundle: .module, comment: "Saves a new diff note"),
                    onCancel: { controller.cancelDraft() },
                    onSave: { controller.saveDraft($0) })
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.leading, 12)
        .padding(.trailing, MercurySpacing.l)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Ideal height whatever the hosting frame proposes: the zone reports it and the gap follows.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            controller.zone(line, heightChanged: height)
        }
    }
}
