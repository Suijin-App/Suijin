import Foundation
import GRDB
import Testing
@testable import SuijinCore

@Suite struct MarkdownCommentTests {
    private static let text = "# Title\n\nFirst paragraph.\n\nSecond paragraph.\n"

    private func anchor(_ quote: String = "First paragraph.") -> MarkdownCommentAnchor {
        let range = (Self.text as NSString).range(of: quote)
        return MarkdownCommentAnchor(in: Self.text, range: range)!
    }

    private func seed(_ store: SuijinStore) throws -> (Workspace, WorktreeRecord) {
        let workspace = Workspace(name: "repo", path: "/tmp/repo", kind: .git)
        try store.save(workspace)
        let worktree = WorktreeRecord(workspaceID: workspace.id, path: "/tmp/repo-worktrees/feat", branch: "feat")
        try store.save(worktree)
        return (workspace, worktree)
    }

    // MARK: Model

    @Test func filePathIsStandardized() {
        let comment = MarkdownComment(workspaceID: UUID(), filePath: "/tmp/repo/docs/../README.md", body: "",
                                      anchor: anchor())
        #expect(comment.filePath == "/tmp/repo/README.md")
    }

    @Test func editingASentCommentReopensItAndEditingAnOpenOneKeepsItOpen() {
        let session = UUID()
        var comment = MarkdownComment(workspaceID: UUID(), filePath: "/tmp/a.md", body: "first", anchor: anchor())
        comment.edit(body: "draft")
        #expect(comment.status == .open && comment.body == "draft" && comment.updatedAt != nil)

        comment.markSent(to: session)
        #expect(comment.status == .sent && comment.sentAt != nil && comment.sentToSession == session)
        comment.edit(body: "second")
        #expect(comment.status == .open && comment.sentAt == nil && comment.sentToSession == nil)
        #expect(comment.body == "second")
    }

    @Test func editingAnAnsweredCommentReopensItWithoutTheReply() {
        var comment = MarkdownComment(workspaceID: UUID(), filePath: "/tmp/a.md", body: "x", anchor: anchor())
        comment.markSent(to: UUID())
        comment.resolve(.declined, reply: "Out of scope")
        comment.edit(body: "y")
        #expect(comment.status == .open && comment.agentReply == nil && comment.resolvedAt == nil)
        #expect(comment.sentAt == nil && comment.sentToSession == nil)
    }

    @Test func resolvingRecordsTheOutcomeAndReply() {
        var comment = MarkdownComment(workspaceID: UUID(), filePath: "/tmp/a.md", body: "x", anchor: anchor())
        comment.markSent(to: UUID())
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        comment.resolve(.fixed, reply: "Done", at: date)
        #expect(comment.status == .fixed && comment.status.isResolved)
        #expect(comment.agentReply == "Done" && comment.resolvedAt == date)
        comment.resolve(.declined, reply: nil)
        #expect(comment.status == .declined && comment.agentReply == nil)
    }

    @Test func reopeningMovesAnsweredCommentsBackToOpenAndLeavesOthersAlone() {
        var comment = MarkdownComment(workspaceID: UUID(), filePath: "/tmp/a.md", body: "x", anchor: anchor())
        comment.reopen()
        #expect(comment.status == .open)

        comment.markSent(to: UUID())
        comment.reopen()
        #expect(comment.status == .sent && comment.sentToSession != nil)

        for outcome in MarkdownCommentOutcome.allCases {
            comment.markSent(to: UUID())
            comment.resolve(outcome, reply: "reply")
            comment.reopen()
            #expect(comment.status == .open && comment.agentReply == nil && comment.resolvedAt == nil)
            #expect(comment.sentAt == nil && comment.sentToSession == nil)
        }
    }

    @Test func sendingAgainClearsAnEarlierAnswer() {
        var comment = MarkdownComment(workspaceID: UUID(), filePath: "/tmp/a.md", body: "x", anchor: anchor())
        comment.markSent(to: nil)
        #expect(comment.status == .sent && comment.sentAt != nil && comment.sentToSession == nil)
        comment.resolve(.fixed, reply: "ok")
        let session = UUID()
        comment.markSent(to: session)
        #expect(comment.status == .sent && comment.agentReply == nil && comment.resolvedAt == nil)
        #expect(comment.sentToSession == session)
    }

    // MARK: Store

    @Test func roundTripsEveryField() throws {
        let store = try SuijinStore.inMemory()
        let (workspace, worktree) = try seed(store)
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000.25)
        var detachedAnchor = anchor("Second paragraph.")
        detachedAnchor.isDetached = true
        let comment = MarkdownComment(
            workspaceID: workspace.id, worktreeID: worktree.id, filePath: "/tmp/repo-worktrees/feat/README.md",
            body: "Rewrite \"this\"\nplease", anchor: detachedAnchor, status: .declined, createdAt: created,
            updatedAt: created.addingTimeInterval(1), sentAt: created.addingTimeInterval(2), sentToSession: UUID(),
            resolvedAt: created.addingTimeInterval(3), agentReply: "Not needed"
        )
        let plain = MarkdownComment(workspaceID: workspace.id, worktreeID: worktree.id,
                                    filePath: "/tmp/repo-worktrees/feat/README.md", body: "",
                                    anchor: anchor(), createdAt: created.addingTimeInterval(10))
        try store.save(comment)
        try store.save(plain)
        #expect(try store.markdownComment(id: comment.id) == comment)
        #expect(try store.markdownComments(filePath: comment.filePath, workspaceID: workspace.id,
                                           worktreeID: worktree.id) == [comment, plain])
        #expect(try store.markdownComment(id: UUID()) == nil)
    }

    @Test func filtersByFileContextAndSession() throws {
        let store = try SuijinStore.inMemory()
        let (workspace, worktree) = try seed(store)
        let session = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        var readme = MarkdownComment(workspaceID: workspace.id, worktreeID: worktree.id,
                                     filePath: "/tmp/repo-worktrees/feat/README.md", body: "a", anchor: anchor(),
                                     createdAt: base)
        readme.markSent(to: session)
        let guide = MarkdownComment(workspaceID: workspace.id, worktreeID: worktree.id,
                                    filePath: "/tmp/repo-worktrees/feat/GUIDE.md", body: "b", anchor: anchor(),
                                    createdAt: base.addingTimeInterval(1))
        var main = MarkdownComment(workspaceID: workspace.id, filePath: "/tmp/repo/README.md", body: "c",
                                   anchor: anchor(), createdAt: base.addingTimeInterval(2))
        main.markSent(to: session)
        for comment in [readme, guide, main] { try store.save(comment) }

        #expect(try store.markdownComments(filePath: "/tmp/repo-worktrees/feat/./README.md", workspaceID: workspace.id,
                                           worktreeID: worktree.id) == [readme])
        #expect(try store.markdownComments(filePath: "/tmp/repo-worktrees/feat/README.md", workspaceID: workspace.id,
                                           worktreeID: nil).isEmpty)
        #expect(try store.markdownComments(filePath: "/tmp/repo/README.md", workspaceID: workspace.id,
                                           worktreeID: nil) == [main])
        #expect(try store.markdownComments(workspaceID: workspace.id, worktreeID: worktree.id) == [readme, guide])
        #expect(try store.markdownComments(workspaceID: workspace.id, worktreeID: nil) == [main])
        #expect(try store.markdownComments(sentToSession: session) == [readme, main])
        #expect(try store.markdownComments(sentToSession: UUID()).isEmpty)
    }

    @Test func updatesAndDeletes() throws {
        let store = try SuijinStore.inMemory()
        let (workspace, _) = try seed(store)
        var comment = MarkdownComment(workspaceID: workspace.id, filePath: "/tmp/repo/a.md", body: "x", anchor: anchor())
        try store.save(comment)
        comment.markSent(to: UUID())
        comment.anchor = MarkdownCommentAnchoring.resolve(comment.anchor, in: "Intro\n\n" + Self.text).anchor
        try store.save(comment)
        #expect(try store.markdownComment(id: comment.id) == comment)
        try store.deleteMarkdownComment(id: comment.id)
        #expect(try store.markdownComment(id: comment.id) == nil)
    }

    @Test func rejectsInvalidComments() throws {
        let store = try SuijinStore.inMemory()
        let (workspace, _) = try seed(store)
        let relative = MarkdownComment(workspaceID: workspace.id, filePath: "docs/a.md", body: "x", anchor: anchor())
        #expect(throws: MarkdownCommentError.invalidFilePath) { try store.save(relative) }
        var unstandardized = relative
        unstandardized.filePath = "/tmp/repo/../a.md"
        #expect(throws: MarkdownCommentError.invalidFilePath) { try store.save(unstandardized) }

        var broken = MarkdownComment(workspaceID: workspace.id, filePath: "/tmp/repo/a.md", body: "x", anchor: anchor())
        broken.anchor.endOffset = broken.anchor.startOffset
        #expect(throws: MarkdownCommentError.invalidAnchor) { try store.save(broken) }
        broken.anchor = anchor()
        broken.anchor.quote = ""
        #expect(throws: MarkdownCommentError.invalidAnchor) { try store.save(broken) }
        broken.anchor = anchor()
        broken.anchor.startLine = 0
        #expect(throws: MarkdownCommentError.invalidAnchor) { try store.save(broken) }
    }

    @Test func deletingTheWorktreeOrWorkspaceDeletesItsComments() throws {
        let store = try SuijinStore.inMemory()
        let (workspace, worktree) = try seed(store)
        let inTree = MarkdownComment(workspaceID: workspace.id, worktreeID: worktree.id,
                                     filePath: "/tmp/repo-worktrees/feat/a.md", body: "x", anchor: anchor())
        let inMain = MarkdownComment(workspaceID: workspace.id, filePath: "/tmp/repo/a.md", body: "y", anchor: anchor())
        try store.save(inTree)
        try store.save(inMain)
        try store.deleteWorktree(id: worktree.id)
        #expect(try store.markdownComment(id: inTree.id) == nil)
        #expect(try store.markdownComment(id: inMain.id) == inMain)
        try store.deleteWorkspace(id: workspace.id)
        #expect(try store.markdownComment(id: inMain.id) == nil)
    }

    @Test func anExistingDatabaseUpgradesAfterABackup() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-v8-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", ".backup-v8_permission_mode"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        // A database as the previous version left it, with a workspace in it.
        let workspaceID = UUID()
        let queue = try DatabaseQueue(path: url.path)
        try Migrations.migrator.migrate(queue, upTo: "v8_permission_mode")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO workspace (id, name, path, kind, createdAt, sortOrder) VALUES (?, 'Repo', '/tmp/repo', 'git', 0, 0)",
                           arguments: [workspaceID])
        }
        try queue.close()

        let comment = MarkdownComment(workspaceID: workspaceID, filePath: "/tmp/repo/README.md", body: "keep",
                                      anchor: anchor())
        do {
            let store = try SuijinStore(url: url)
            #expect(try store.workspaces().map(\.id) == [workspaceID])
            try store.save(comment)
        }
        let backup = url.appendingPathExtension("backup-v8_permission_mode")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try DatabaseQueue(path: backup.path).read { db in
            try !db.tableExists("markdown_comment") && db.tableExists("workspace")
        })
        let reopened = try SuijinStore(url: url)
        #expect(try reopened.markdownComment(id: comment.id) == comment)
    }
}

@Suite struct MarkdownCommentAnswerStoreTests {
    private func makeStore() throws -> (SuijinStore, MarkdownComment) {
        let store = try SuijinStore.inMemory()
        let workspace = Workspace(name: "work", path: "/work", kind: .folder)
        try store.save(workspace)
        let text = "# Plan\n\nFirst paragraph.\n"
        let anchor = try #require(MarkdownCommentAnchor(in: text, range: (text as NSString).range(of: "First paragraph.")))
        let comment = MarkdownComment(workspaceID: workspace.id, filePath: "/work/plan.md", body: "note", anchor: anchor)
        try store.save(comment)
        return (store, comment)
    }

    @Test func anAnswerIsRecordedOnlyForTheSessionTheCommentWaitsOn() throws {
        var (store, comment) = try makeStore()
        let session = UUID()
        let sent = Date()
        #expect(try store.resolveMarkdownComment(id: comment.id, session: session, outcome: .fixed, reply: "x", at: sent) == nil,
                "an open comment takes no answer")
        comment.markSent(to: session, at: sent)
        try store.save(comment)
        #expect(try store.resolveMarkdownComment(id: comment.id, session: UUID(), outcome: .fixed, reply: "x", at: sent.addingTimeInterval(5)) == nil)
        #expect(try store.resolveMarkdownComment(id: UUID(), session: session, outcome: .fixed, reply: "x", at: sent.addingTimeInterval(5)) == nil)
        #expect(try store.markdownComment(id: comment.id)?.status == .sent)

        let answered = try #require(try store.resolveMarkdownComment(id: comment.id, session: session, outcome: .declined,
                                                                     reply: "why not", at: sent.addingTimeInterval(5)))
        #expect(answered.status == .declined)
        let saved = try #require(try store.markdownComment(id: comment.id))
        #expect(saved.status == .declined)
        #expect(saved.agentReply == "why not")
        #expect(saved.body == "note")
        // Answered once: a second answer changes nothing.
        #expect(try store.resolveMarkdownComment(id: comment.id, session: session, outcome: .fixed, reply: "again", at: sent.addingTimeInterval(9)) == nil)
        #expect(try store.markdownComment(id: comment.id)?.agentReply == "why not")
    }

    @Test func anAnswerOlderThanTheSendIsDropped() throws {
        var (store, comment) = try makeStore()
        let session = UUID()
        let sent = Date()
        comment.markSent(to: session, at: sent)
        try store.save(comment)
        // Given to an earlier version of the comment, before it was sent again.
        #expect(try store.resolveMarkdownComment(id: comment.id, session: session, outcome: .fixed, reply: "old", at: sent.addingTimeInterval(-60)) == nil)
        #expect(try store.markdownComment(id: comment.id)?.status == .sent)
    }

    @Test func movingACommentWritesItsPositionOnly() throws {
        var (store, comment) = try makeStore()
        let text = "Added.\n\n# Plan\n\nFirst paragraph.\n"
        let moved = try #require(MarkdownCommentAnchor(in: text, range: (text as NSString).range(of: "First paragraph.")))
        // A newer status is in the store than the copy that carries the new position.
        comment.markSent(to: UUID())
        try store.save(comment)
        try store.updateMarkdownCommentAnchor(id: comment.id, anchor: moved)
        let saved = try #require(try store.markdownComment(id: comment.id))
        #expect(saved.anchor == moved)
        #expect(saved.status == .sent)

        try store.deleteMarkdownComment(id: comment.id)
        try store.updateMarkdownCommentAnchor(id: comment.id, anchor: moved)
        #expect(try store.markdownComment(id: comment.id) == nil, "a deleted comment stays deleted")
    }
}
