import Foundation
import SevindaCore
import SevindaDiff
import SevindaGit
import Observation

extension DiffNote: @retroactive DiffNoteFormattable {}

/// The diff notes of one context (a worktree, or a git workspace's main checkout), loaded from the store and kept
/// in memory. Changes show at once and are written through; a failed write reloads from the store and reports the
/// error.
@MainActor
@Observable
final class DiffNotesBook {
    let workspaceID: UUID
    let worktreeID: UUID?
    private(set) var notes: [DiffNote] = []
    @ObservationIgnored private unowned let model: AppModel

    init?(context: SessionContext, model: AppModel) {
        guard let workspaceID = model.workspaceID(of: context) else { return nil }
        self.workspaceID = workspaceID
        if case .worktree(let id) = context { worktreeID = id } else { worktreeID = nil }
        self.model = model
    }

    var unsent: [DiffNote] { notes.filter { $0.sentAt == nil } }

    /// Unsent notes in reading order: by file, file notes first, then by line.
    var unsentInOrder: [DiffNote] {
        unsent.sorted { a, b in
            if a.filePath != b.filePath { return a.filePath < b.filePath }
            if a.lineNumber != b.lineNumber { return a.lineNumber < b.lineNumber }
            return a.createdAt < b.createdAt
        }
    }

    func notes(forFile path: String) -> [DiffNote] {
        notes.filter { $0.filePath == path }
    }

    func load() async {
        let workspaceID = workspaceID
        let worktreeID = worktreeID
        do {
            notes = try await model.io { store in
                if let worktreeID { try store.diffNotes(worktreeID: worktreeID) } else { try store.diffNotes(mainCheckoutOf: workspaceID) }
            }
        } catch {
            model.presentedError = PresentedError(title: String(localized: "Could not load diff notes"),
                                                  message: error.localizedDescription)
        }
    }

    /// Adds a note on `anchor` of `diff`'s file, fingerprinting the noted lines so later changes mark it stale.
    func create(_ anchor: DiffNoteAnchor, body: String, in diff: FileDiff, scope: DiffNoteScope) {
        let identity = DiffNoteAnchoring.identity(of: anchor, in: DiffNoteAnchoring.newSideLines(of: diff))
        let note = DiffNote(workspaceID: workspaceID, worktreeID: worktreeID, filePath: diff.displayPath,
                            oldPath: diff.oldPath != diff.newPath ? diff.oldPath : nil,
                            startLine: anchor.startLine, lineNumber: anchor.lineNumber, body: body,
                            scope: scope, diffIdentity: identity)
        notes.append(note)
        persist([note], title: String(localized: "Could not save the note"))
    }

    /// Edits a note's text; an edited note counts as unsent again.
    func update(_ id: UUID, body: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].body != body else { return }
        notes[index] = notes[index].edited(body: body)
        persist([notes[index]], title: String(localized: "Could not save the note"))
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        Task {
            do {
                try await model.io { try $0.deleteDiffNote(id: id) }
            } catch {
                await failed(String(localized: "Could not delete the note"), error)
            }
        }
    }

    func markSent(_ ids: [UUID], at date: Date = Date()) {
        var changed: [DiffNote] = []
        for index in notes.indices where ids.contains(notes[index].id) {
            notes[index].sentAt = date
            changed.append(notes[index])
        }
        persist(changed, title: String(localized: "Could not mark the notes as sent"))
    }

    private func persist(_ changed: [DiffNote], title: String) {
        guard !changed.isEmpty else { return }
        Task {
            do {
                try await model.io { store in for note in changed { try store.save(note) } }
            } catch {
                await failed(title, error)
            }
        }
    }

    private func failed(_ title: String, _ error: any Error) async {
        model.presentedError = PresentedError(title: title, message: error.localizedDescription)
        await load()
    }
}
