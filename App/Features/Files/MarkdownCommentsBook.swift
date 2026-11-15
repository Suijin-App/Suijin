import AppKit
import Foundation
import Observation
import SuijinCore
import SuijinMarkdown
import SwiftUI

/// The comments on one Markdown file tab, loaded from the store and kept in memory. Changes show at once and are
/// written through; a failed write reloads from the store and reports the error (as `DiffNotesBook` does).
///
/// While the file is edited the comments follow their text edit by edit; when the whole text is replaced (the file
/// was reloaded) each one is searched for again, and one whose text is gone becomes detached instead of vanishing.
@MainActor
@Observable
final class MarkdownCommentsBook {
    let path: String
    let context: SessionContext
    let workspaceID: UUID
    let worktreeID: UUID?
    private(set) var comments: [MarkdownComment] = []
    private(set) var isLoaded = false
    /// Whether the user opened or closed the Comments column; until they do, it shows when the file has comments.
    var panelPreference: Bool?
    /// The comment under the editor's insertion point, shown lit in the column.
    private(set) var activeID: UUID?

    /// Held weakly: writes to the store finish after the tab, and in tests after the model, is gone.
    @ObservationIgnored private weak var owner: AppModel?
    /// The app model while it lives, also for the extensions of the book in other files.
    var appModel: AppModel? { owner }
    @ObservationIgnored private(set) weak var session: MarkdownEditSession?
    /// Comments whose position changed since it was last written.
    @ObservationIgnored private var moved: Set<UUID> = []
    @ObservationIgnored private var anchorSave: Task<Void, Never>?
    /// The last write to the store. Writes run one after another, in the order they were asked for: two versions
    /// of one comment written at the same time could otherwise land newest first.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    @ObservationIgnored private var composer: NSPopover?

    /// How long typing must pause before moved comment positions are written.
    static let anchorSaveDelay: Duration = .milliseconds(800)

    init?(path: String, context: SessionContext, model: AppModel) {
        guard let workspaceID = model.workspaceID(of: context) else { return nil }
        self.path = URL(fileURLWithPath: path).standardized.path
        self.context = context
        self.workspaceID = workspaceID
        if case .worktree(let id) = context { worktreeID = id } else { worktreeID = nil }
        owner = model
    }

    // MARK: Reading

    var isPanelShown: Bool { panelPreference ?? !comments.isEmpty }

    /// Comments that still have a place in the file, in reading order.
    var placed: [MarkdownComment] {
        comments.filter { !$0.anchor.isDetached }.sorted { ($0.anchor.startOffset, $0.createdAt) < ($1.anchor.startOffset, $1.createdAt) }
    }

    /// Comments whose text is no longer in the file.
    var detached: [MarkdownComment] {
        comments.filter(\.anchor.isDetached).sorted { $0.createdAt < $1.createdAt }
    }

    /// Comments not answered yet: open or sent.
    var unfinishedCount: Int { comments.filter { !$0.status.isResolved }.count }

    /// Comments to hand to an agent: not sent yet, and still in the file.
    var unsent: [MarkdownComment] { placed.filter { $0.status == .open } }

    /// Comments an agent has and did not answer yet: they can be sent again.
    var waiting: [MarkdownComment] { placed.filter { $0.status == .sent } }

    /// The comment on exactly `range`, if any.
    func comment(on range: NSRange) -> MarkdownComment? {
        placed.first { $0.anchor.range == range }
    }

    /// The text the comments are anchored in: the editor's when the tab is being edited, else the file's.
    func currentText() -> String? {
        if let session { return session.text }
        return (try? MarkdownFile.read(URL(fileURLWithPath: path)))?.text
    }

    // MARK: Loading

    func load() async {
        guard let model = owner else { return }
        let path = path, workspaceID = workspaceID, worktreeID = worktreeID
        do {
            comments = try await model.io { try $0.markdownComments(filePath: path, workspaceID: workspaceID, worktreeID: worktreeID) }
            isLoaded = true
            if let text = currentText() { resolveAll(in: text) }
            pushHighlights()
        } catch {
            isLoaded = true
            model.presentedError = PresentedError(title: String(localized: "Could not load the comments"),
                                                  message: error.localizedDescription)
        }
    }

    /// Follows the editor of this tab: its edits move the comments, and the comments are drawn behind its text.
    func attach(_ session: MarkdownEditSession) {
        guard self.session !== session else { return }
        self.session = session
        session.onTextChange = { [weak self] change in self?.textChanged(change) }
        session.onTextReplaced = { [weak self] in
            guard let self, let text = self.currentText() else { return }
            self.textReplaced(text)
        }
        session.onSelectionChange = { [weak self] selection in self?.selectionChanged(selection) }
        session.onCommentRequested = { [weak self] in self?.beginComment() }
        if isLoaded { resolveAll(in: session.text) }
        pushHighlights()
    }

    // MARK: Changes

    /// Adds a comment on `range` of the current text. Nil when the range is empty or outside the text.
    @discardableResult
    func create(range: NSRange, body: String) -> MarkdownComment? {
        guard let text = currentText(), let anchor = MarkdownCommentAnchor(in: text, range: range) else { return nil }
        let comment = MarkdownComment(workspaceID: workspaceID, worktreeID: worktreeID, filePath: path,
                                      body: body.trimmingCharacters(in: .whitespacesAndNewlines), anchor: anchor)
        comments.append(comment)
        pushHighlights()
        persist([comment], title: String(localized: "Could not save the comment"))
        return comment
    }

    /// Edits a comment's note. A comment an agent already has goes back to open, and is taken back from the agent.
    func update(_ id: UUID, body: String) {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = comments.firstIndex(where: { $0.id == id }), comments[index].body != body else { return }
        let wasWithAgent = comments[index].status != .open
        comments[index].edit(body: body)
        if wasWithAgent { owner?.withdrawComments([id]) }
        pushHighlights()
        persist([comments[index]], title: String(localized: "Could not save the comment"))
    }

    func delete(_ id: UUID) {
        guard comments.contains(where: { $0.id == id }) else { return }
        comments.removeAll { $0.id == id }
        moved.remove(id)
        owner?.withdrawComments([id])
        pushHighlights()
        write(title: String(localized: "Could not delete the comment")) { try $0.deleteMarkdownComment(id: id) }
    }

    /// Puts an answered comment back to open and drops the agent's reply.
    func reopen(_ id: UUID) {
        guard let index = comments.firstIndex(where: { $0.id == id }), comments[index].status.isResolved else { return }
        comments[index].reopen()
        owner?.withdrawComments([id])
        pushHighlights()
        persist([comments[index]], title: String(localized: "Could not save the comment"))
    }

    /// Puts a sent comment back to open, so the Send menu hands it over again.
    func unsend(_ id: UUID) {
        guard let index = comments.firstIndex(where: { $0.id == id }), comments[index].status == .sent else { return }
        var comment = comments[index]
        comment.status = .open
        comment.sentAt = nil
        comment.sentToSession = nil
        comments[index] = comment
        owner?.withdrawComments([id])
        persist([comment], title: String(localized: "Could not save the comment"))
    }

    /// Records that comments were handed to an agent: pasted into `session`, or copied when it is nil.
    func markSent(_ ids: [UUID], to session: UUID?, at date: Date = Date()) {
        var changed: [MarkdownComment] = []
        for index in comments.indices where ids.contains(comments[index].id) {
            comments[index].markSent(to: session, at: date)
            changed.append(comments[index])
        }
        pushHighlights()
        persist(changed, title: String(localized: "Could not mark the comments as sent"))
    }

    /// Shows the answer an agent gave to a comment, as the store recorded it. Only the answer is taken, and only
    /// while the comment here still waits on that session: an edit, reopen or resend made in the meantime wins.
    func showAnswer(of answered: MarkdownComment) {
        guard let index = comments.firstIndex(where: { $0.id == answered.id }), answered.status.isResolved,
              comments[index].status == .sent, comments[index].sentToSession == answered.sentToSession else { return }
        comments[index].status = answered.status
        comments[index].resolvedAt = answered.resolvedAt
        comments[index].agentReply = answered.agentReply
        pushHighlights()
    }

    // MARK: Following the text

    /// One edit of the editor's text: every comment moves with its own text, without searching.
    func textChanged(_ change: MarkdownTextChange) {
        guard !comments.isEmpty else { return }
        let edit = MarkdownCommentAnchoring.Edit(location: change.location, oldLength: change.oldLength, newLength: change.newLength)
        for index in comments.indices {
            let shifted = MarkdownCommentAnchoring.shift(comments[index].anchor, forEdit: edit)
            guard shifted != comments[index].anchor else { continue }
            comments[index].anchor = shifted
            moved.insert(comments[index].id)
        }
        pushHighlights()
        scheduleAnchorSave()
    }

    /// The whole text was replaced: every comment is searched for again.
    func textReplaced(_ text: String) {
        anchorSave?.cancel()
        moved.removeAll()
        resolveAll(in: text)
        pushHighlights()
    }

    private func resolveAll(in text: String) {
        var changed: [MarkdownComment] = []
        for index in comments.indices {
            let resolution = MarkdownCommentAnchoring.resolve(comments[index].anchor, in: text)
            comments[index].anchor = resolution.anchor
            if resolution.needsPersisting { changed.append(comments[index]) }
        }
        persistAnchors(changed)
    }

    private func scheduleAnchorSave() {
        anchorSave?.cancel()
        anchorSave = Task { [weak self] in
            try? await Task.sleep(for: Self.anchorSaveDelay)
            guard !Task.isCancelled else { return }
            self?.saveMovedAnchors()
        }
    }

    /// Writes the positions that moved while typing, with their quote, context and lines brought up to the text.
    /// A comment that lost its text gets one more search: an undo may have brought the text back.
    func saveMovedAnchors() {
        anchorSave?.cancel()
        anchorSave = nil
        guard let text = currentText() else { return }
        var changed: [MarkdownComment] = []
        for index in comments.indices {
            let comment = comments[index]
            if comment.anchor.isDetached {
                let resolution = MarkdownCommentAnchoring.resolve(comment.anchor, in: text)
                guard !resolution.anchor.isDetached || moved.contains(comment.id) else { continue }
                comments[index].anchor = resolution.anchor
                changed.append(comments[index])
            } else if moved.contains(comment.id) {
                comments[index].anchor = MarkdownCommentAnchoring.refresh(comment.anchor, in: text)
                changed.append(comments[index])
            }
        }
        moved.removeAll()
        pushHighlights()
        persistAnchors(changed)
    }

    private func selectionChanged(_ selection: NSRange) {
        let id = placed.first { comment in
            let range = comment.anchor.range
            return selection.location >= range.location && NSMaxRange(selection) <= NSMaxRange(range)
        }?.id
        if id != activeID { activeID = id }
    }

    // MARK: Editor

    /// Draws the comments behind the editor's text: a stronger tint while a comment waits, a faint one once it was
    /// answered, none for a detached one.
    private func pushHighlights() {
        guard let session else { return }
        let accent = NSColor.controlAccentColor
        session.controller.setHighlights(placed.map { comment in
            MarkdownHighlight(range: comment.anchor.range,
                              color: accent.withAlphaComponent(comment.status.isResolved ? 0.10 : 0.24))
        })
    }

    /// Shows the comment's text in the editor, switching the tab to Edit first.
    func reveal(_ id: UUID) {
        guard let comment = comments.first(where: { $0.id == id }), !comment.anchor.isDetached,
              let session = owner?.markdownSession(for: path, in: context, create: true) else { return }
        let wasEditing = session.mode == .edit
        session.mode = .edit
        let range = comment.anchor.range
        if wasEditing {
            session.controller.reveal(range)
        } else {
            // After this update, so the editor is in the window.
            DispatchQueue.main.async { session.controller.reveal(range) }
        }
    }

    /// Starts a comment on the editor's selection: a popover at the selected text with the note field. A selection
    /// that is exactly an existing comment edits that comment's note instead.
    func beginComment() {
        guard let session, session.mode == .edit else { return }
        let selection = session.controller.selectedRange
        guard selection.length > 0, let rect = session.controller.selectionRect() else { return }
        let existing = comment(on: selection)
        let quote = (session.text as NSString).substring(with: selection)
        // Where the selection was when the popover opened; the text may change before the note is added.
        let anchor = MarkdownCommentAnchor(in: session.text, range: selection)
        let popover = NSPopover()
        popover.behavior = .transient
        let close: () -> Void = { [weak popover] in popover?.close() }
        popover.contentViewController = NSHostingController(rootView: MarkdownCommentComposer(
            quote: quote, note: existing?.body ?? "", isNew: existing == nil,
            onSubmit: { [weak self] note in
                defer { close() }
                guard let self else { return }
                if let existing {
                    self.update(existing.id, body: note)
                } else if let anchor, let text = self.currentText() {
                    // The same text, wherever it is now; when it is gone there is nothing to comment on.
                    let found = MarkdownCommentAnchoring.resolve(anchor, in: text).anchor
                    guard !found.isDetached else {
                        NSSound.beep()
                        return
                    }
                    self.create(range: found.range, body: note)
                }
                if self.panelPreference == false { self.panelPreference = nil }
            },
            onCancel: close))
        composer?.close()
        composer = popover
        popover.show(relativeTo: rect, of: session.controller.textView, preferredEdge: .maxY)
    }

    // MARK: Store

    private func persist(_ changed: [MarkdownComment], title: String) {
        guard !changed.isEmpty else { return }
        write(title: title) { store in for comment in changed { try store.save(comment) } }
    }

    /// Writes positions only: a moved comment never brings back a deleted row or an older status.
    private func persistAnchors(_ changed: [MarkdownComment]) {
        guard !changed.isEmpty else { return }
        let anchors = changed.map { ($0.id, $0.anchor) }
        write(title: String(localized: "Could not save the comment")) { store in
            for (id, anchor) in anchors { try store.updateMarkdownCommentAnchor(id: id, anchor: anchor) }
        }
    }

    /// Runs `work` on the store after every write asked for before it.
    private func write(title: String, _ work: @escaping @Sendable (SuijinStore) throws -> Void) {
        guard let model = owner else { return }
        let previous = lastWrite
        lastWrite = Task { [weak self] in
            await previous?.value
            do {
                try await model.io(work)
            } catch {
                await self?.failed(title, error)
            }
        }
    }

    private func failed(_ title: String, _ error: any Error) async {
        owner?.presentedError = PresentedError(title: title, message: error.localizedDescription)
        await load()
    }
}

extension AppModel {
    /// The comments of a Markdown tab, made (and loaded) when the tab first shows.
    @discardableResult
    func openMarkdownComments(for path: String, in context: SessionContext) -> MarkdownCommentsBook? {
        let key = FileTabKey(context: context, path: path)
        if let book = markdownBooks[key] { return book }
        guard let book = MarkdownCommentsBook(path: path, context: context, model: self) else { return nil }
        markdownBooks[key] = book
        if let session = markdownSessions[key] { book.attach(session) }
        Task { await book.load() }
        return book
    }

    /// The comments of the selected Markdown tab.
    var activeMarkdownBook: MarkdownCommentsBook? {
        activeMarkdownFile.flatMap { markdownBooks[$0] }
    }

    /// Whether Add Comment has a selection to work on: the selected tab is a Markdown file in Edit with text selected.
    var canAddComment: Bool {
        guard let session = activeMarkdownSession, session.mode == .edit, activeMarkdownBook != nil else { return false }
        return session.selection.length > 0
    }
}
