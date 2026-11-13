import Foundation
import Testing
@testable import SuijinCore

@Suite struct DiffNoteStoreTests {
    private func seed(_ store: SuijinStore) throws -> (Workspace, WorktreeRecord) {
        let workspace = Workspace(name: "repo", path: "/tmp/repo", kind: .git)
        try store.save(workspace)
        let worktree = WorktreeRecord(workspaceID: workspace.id, path: "/tmp/repo-worktrees/feat", branch: "feat")
        try store.save(worktree)
        return (workspace, worktree)
    }

    @Test func roundTripsEveryField() throws {
        let store = try SuijinStore.inMemory()
        let (workspace, worktree) = try seed(store)
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000.25)
        let note = DiffNote(workspaceID: workspace.id, worktreeID: worktree.id, filePath: "Sources/App.swift",
                            oldPath: "Sources/Old.swift", startLine: 3, lineNumber: 7, body: "Rename \"x\"\nplease",
                            createdAt: created, updatedAt: created.addingTimeInterval(5), sentAt: created.addingTimeInterval(9),
                            scope: .branch, diffIdentity: "abc123")
        let fileNote = DiffNote(workspaceID: workspace.id, worktreeID: worktree.id, filePath: "README.md", lineNumber: 0,
                                body: "Whole file", createdAt: created.addingTimeInterval(1), scope: .uncommitted)
        try store.save(note)
        try store.save(fileNote)
        #expect(try store.diffNotes(worktreeID: worktree.id) == [note, fileNote])
        #expect(try store.diffNotes(mainCheckoutOf: workspace.id).isEmpty)
        #expect(fileNote.isFileNote && !note.isFileNote)
    }

    @Test func mainCheckoutNotesAreSeparateFromWorktreeNotes() throws {
        let store = try SuijinStore.inMemory()
        let (workspace, worktree) = try seed(store)
        let main = DiffNote(workspaceID: workspace.id, filePath: "a.swift", lineNumber: 1, body: "main", scope: .uncommitted)
        let tree = DiffNote(workspaceID: workspace.id, worktreeID: worktree.id, filePath: "a.swift", lineNumber: 1,
                            body: "tree", scope: .uncommitted)
        try store.save(main)
        try store.save(tree)
        #expect(try store.diffNotes(mainCheckoutOf: workspace.id) == [main])
        #expect(try store.diffNotes(worktreeID: worktree.id) == [tree])
    }

    @Test func editingClearsSentAtAndUpdateIsPersisted() throws {
        let store = try SuijinStore.inMemory()
        let (workspace, worktree) = try seed(store)
        var note = DiffNote(workspaceID: workspace.id, worktreeID: worktree.id, filePath: "a.swift", lineNumber: 4,
                            body: "first", scope: .branch)
        note.sentAt = Date()
        try store.save(note)
        let edited = note.edited(body: "second")
        #expect(edited.sentAt == nil && edited.updatedAt != nil && edited.body == "second")
        try store.save(edited)
        #expect(try store.diffNotes(worktreeID: worktree.id) == [edited])

        try store.deleteDiffNote(id: note.id)
        #expect(try store.diffNotes(worktreeID: worktree.id).isEmpty)
    }

    @Test func rejectsInvalidNotes() throws {
        let store = try SuijinStore.inMemory()
        let (workspace, _) = try seed(store)
        func note(start: Int?, line: Int, body: String = "x") -> DiffNote {
            DiffNote(workspaceID: workspace.id, filePath: "a", startLine: start, lineNumber: line, body: body, scope: .branch)
        }
        #expect(throws: DiffNoteError.invalidLineRange) { try store.save(note(start: 5, line: 4)) }
        #expect(throws: DiffNoteError.invalidLineRange) { try store.save(note(start: 0, line: 4)) }
        #expect(throws: DiffNoteError.invalidLineRange) { try store.save(note(start: 1, line: 0)) }
        #expect(throws: DiffNoteError.invalidLineRange) { try store.save(note(start: nil, line: -1)) }
        #expect(throws: DiffNoteError.emptyBody) { try store.save(note(start: nil, line: 2, body: " \n ")) }
        #expect(throws: Never.self) { try store.save(note(start: 4, line: 4)) }
    }

    @Test func deletingTheWorktreeOrWorkspaceDeletesItsNotes() throws {
        let store = try SuijinStore.inMemory()
        let (workspace, worktree) = try seed(store)
        try store.save(DiffNote(workspaceID: workspace.id, worktreeID: worktree.id, filePath: "a", lineNumber: 1,
                                body: "x", scope: .branch))
        try store.save(DiffNote(workspaceID: workspace.id, filePath: "a", lineNumber: 1, body: "y", scope: .branch))
        try store.deleteWorktree(id: worktree.id)
        #expect(try store.diffNotes(worktreeID: worktree.id).isEmpty)
        #expect(try store.diffNotes(mainCheckoutOf: workspace.id).count == 1)
        try store.deleteWorkspace(id: workspace.id)
        #expect(try store.diffNotes(mainCheckoutOf: workspace.id).isEmpty)
    }

    @Test func migratesAFileDatabaseAndKeepsNotesAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("suijin.sqlite")
        let workspace = Workspace(name: "repo", path: "/tmp/repo", kind: .git)
        let note = DiffNote(workspaceID: workspace.id, filePath: "a", lineNumber: 2, body: "keep", scope: .uncommitted)
        do {
            let store = try SuijinStore(url: url)
            try store.save(workspace)
            try store.save(note)
        }
        let reopened = try SuijinStore(url: url)
        #expect(try reopened.diffNotes(mainCheckoutOf: workspace.id) == [note])
    }
}
