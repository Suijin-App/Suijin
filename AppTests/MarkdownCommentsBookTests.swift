import AppKit
import Foundation
import SuijinCore
import Testing
@testable import Suijin

/// The comments of a Markdown tab: they are written through to the store, follow their text while it is edited, and
/// are found again (or become detached) when the whole text is replaced.
@MainActor
@Suite(.serialized) struct MarkdownCommentsBookTests {
    static let text = "# Plan\n\nFirst paragraph to change.\n\nSecond paragraph stays.\n\nThird paragraph.\n"

    private struct Fixture {
        let model: AppModel
        let context: SessionContext
        let url: URL
        let book: MarkdownCommentsBook
        let session: MarkdownEditSession

        var path: String { url.path }
    }

    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private func makeFixture(text: String = MarkdownCommentsBookTests.text) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-comments-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("plan.md").standardizedFileURL
        try text.write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.selection = context
        model.openFile(url.path, in: context)
        let book = try #require(model.openMarkdownComments(for: url.path, in: context))
        #expect(await eventually { book.isLoaded })
        let session = try #require(model.markdownSession(for: url.path, in: context, create: true))
        session.mode = .edit
        #expect(book.session === session)
        return Fixture(model: model, context: context, url: url, book: book, session: session)
    }

    private func cleanUp(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func range(of text: String, in fixture: Fixture) -> NSRange {
        (fixture.session.text as NSString).range(of: text)
    }

    private func stored(_ fixture: Fixture) async -> [MarkdownComment] {
        let path = fixture.path, workspace = fixture.book.workspaceID
        return (try? await fixture.model.io { try $0.markdownComments(filePath: path, workspaceID: workspace, worktreeID: nil) }) ?? []
    }

    private func type(_ text: String, at location: Int, replacing length: Int = 0, in fixture: Fixture) {
        fixture.session.controller.textView.insertText(text, replacementRange: NSRange(location: location, length: length))
    }

    // MARK: Changes

    @Test func aNewCommentIsShownAtOnceAndWrittenToTheStore() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let comment = try #require(fixture.book.create(range: range(of: "First paragraph", in: fixture), body: "  shorter  "))
        #expect(fixture.book.comments.map(\.id) == [comment.id])
        #expect(comment.body == "shorter")
        #expect(comment.status == .open)
        #expect(comment.anchor.quote == "First paragraph")
        #expect(comment.anchor.startLine == 3)
        #expect(fixture.book.isPanelShown, "the column appears with the first comment")
        #expect(await eventually { await stored(fixture).map(\.id) == [comment.id] })
        #expect(fixture.book.create(range: NSRange(location: 3, length: 0), body: "") == nil, "nothing selected")
    }

    @Test func editingASentCommentMakesItOpenAgain() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let comment = try #require(fixture.book.create(range: range(of: "First paragraph", in: fixture), body: "one"))
        let session = UUID()
        fixture.book.markSent([comment.id], to: session)
        #expect(fixture.book.comments.first?.status == .sent)
        #expect(fixture.book.comments.first?.sentToSession == session)
        #expect(fixture.book.unsent.isEmpty)

        fixture.book.update(comment.id, body: "two")
        #expect(fixture.book.comments.first?.status == .open)
        #expect(fixture.book.comments.first?.sentToSession == nil)
        #expect(fixture.book.unsent.map(\.id) == [comment.id])
        #expect(await eventually {
            let saved = await stored(fixture).first
            return saved?.body == "two" && saved?.status == .open
        })
    }

    @Test func reopeningAnAnsweredCommentDropsTheReply() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let comment = try #require(fixture.book.create(range: range(of: "First paragraph", in: fixture), body: ""))
        let session = UUID()
        fixture.book.markSent([comment.id], to: session)
        var answered = try #require(fixture.book.comments.first)
        answered.resolve(.declined, reply: "kept on purpose")
        fixture.book.showAnswer(of: answered)
        #expect(fixture.book.comments.first?.status == .declined)
        #expect(fixture.book.comments.first?.agentReply == "kept on purpose")
        #expect(fixture.book.unfinishedCount == 0)

        fixture.book.reopen(comment.id)
        #expect(fixture.book.comments.first?.status == .open)
        #expect(fixture.book.comments.first?.agentReply == nil)
        #expect(fixture.book.unfinishedCount == 1)
    }

    @Test func deletingRemovesTheCommentFromTheStore() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let comment = try #require(fixture.book.create(range: range(of: "First paragraph", in: fixture), body: ""))
        #expect(await eventually { await stored(fixture).count == 1 })
        fixture.book.delete(comment.id)
        #expect(fixture.book.comments.isEmpty)
        #expect(await eventually { await stored(fixture).isEmpty })
    }

    @Test func aFailedWriteReloadsFromTheStoreAndReportsIt() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        // The workspace is gone from the store, so the comment cannot be written.
        let workspace = fixture.book.workspaceID
        try await fixture.model.io { try $0.deleteWorkspace(id: workspace) }
        fixture.book.create(range: range(of: "First paragraph", in: fixture), body: "lost")
        #expect(fixture.book.comments.count == 1, "shown at once")
        #expect(await eventually { fixture.book.comments.isEmpty })
        #expect(fixture.model.presentedError != nil)
    }

    @Test func anAnswerDoesNotUndoWhatTheUserDidMeanwhile() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let comment = try #require(fixture.book.create(range: range(of: "First paragraph", in: fixture), body: "one"))
        let session = UUID()
        fixture.book.markSent([comment.id], to: session)
        var answered = try #require(fixture.book.comments.first)
        answered.resolve(.fixed, reply: "done")
        // The user edits the note before the answer arrives: the comment is open again and stays so.
        fixture.book.update(comment.id, body: "two")
        fixture.book.showAnswer(of: answered)
        #expect(fixture.book.comments.first?.status == .open)
        #expect(fixture.book.comments.first?.body == "two")
        #expect(fixture.book.comments.first?.agentReply == nil)
    }

    @Test func aPositionWrittenLateDoesNotBringBackADeletedComment() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let comment = try #require(fixture.book.create(range: range(of: "Second paragraph stays.", in: fixture), body: ""))
        #expect(await eventually { await stored(fixture).count == 1 })
        type("Moved down.\n\n", at: 0, in: fixture)
        fixture.book.delete(comment.id)
        fixture.book.saveMovedAnchors()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await stored(fixture).isEmpty)
        // The store's own guarantee: a position alone never inserts a row.
        let anchor = comment.anchor
        try await fixture.model.io { try $0.updateMarkdownCommentAnchor(id: comment.id, anchor: anchor) }
        #expect(await stored(fixture).isEmpty)
    }

    // MARK: Following the text

    @Test func commentsFollowTheirTextThroughEdits() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let comment = try #require(fixture.book.create(range: range(of: "Second paragraph stays.", in: fixture), body: ""))
        // Above, below and inside the commented text.
        type("An inserted line.\n\n", at: range(of: "First paragraph", in: fixture).location, in: fixture)
        type(" More.", at: (fixture.session.text as NSString).length - 1, in: fixture)
        type("really ", at: range(of: "stays.", in: fixture).location, in: fixture)

        let anchor = try #require(fixture.book.comments.first).anchor
        #expect((fixture.session.text as NSString).substring(with: anchor.range) == "Second paragraph really stays.")
        #expect(!anchor.isDetached)
        // The highlight in the editor is on the same range.
        let color = fixture.session.controller.textView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: anchor.range.location, effectiveRange: nil)
        #expect(color != nil)

        fixture.book.saveMovedAnchors()
        let saved = try #require(fixture.book.comments.first).anchor
        #expect(saved.quote == "Second paragraph really stays.")
        #expect(saved.startLine == 7)
        #expect(await eventually { await stored(fixture).first?.anchor.quote == "Second paragraph really stays." })
        #expect(fixture.book.comments.first?.id == comment.id)
    }

    @Test func deletingTheCommentedTextDetachesAndUndoBringsItBack() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        fixture.book.create(range: range(of: "Second paragraph stays.", in: fixture), body: "")
        let line = range(of: "Second paragraph stays.\n\n", in: fixture)
        type("", at: line.location, replacing: line.length, in: fixture)
        #expect(fixture.book.comments.first?.anchor.isDetached == true)
        #expect(fixture.book.detached.count == 1)
        #expect(fixture.book.placed.isEmpty)
        // Still readable: the quote is kept.
        #expect(fixture.book.comments.first?.anchor.quote == "Second paragraph stays.")

        fixture.session.controller.undoManager.undo()
        fixture.book.saveMovedAnchors()
        #expect(fixture.book.comments.first?.anchor.isDetached == false)
        #expect(fixture.book.placed.count == 1)
    }

    @Test func replacingTheWholeTextSearchesForEveryComment() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let kept = try #require(fixture.book.create(range: range(of: "Second paragraph stays.", in: fixture), body: ""))
        let gone = try #require(fixture.book.create(range: range(of: "Third paragraph.", in: fixture), body: ""))
        // Another writer (an agent) rewrote the file.
        try "# Plan\n\nA new opening.\n\nIntro.\n\nSecond paragraph stays.\n\nA different ending.\n".write(to: fixture.url, atomically: true, encoding: .utf8)
        fixture.session.diskMayHaveChanged()
        let text = fixture.session.text as NSString
        let byID = Dictionary(uniqueKeysWithValues: fixture.book.comments.map { ($0.id, $0) })
        #expect(text.substring(with: try #require(byID[kept.id]).anchor.range) == "Second paragraph stays.")
        #expect(byID[kept.id]?.anchor.startLine == 7)
        #expect(byID[gone.id]?.anchor.isDetached == true)
        #expect(await eventually { await stored(fixture).first { $0.id == gone.id }?.anchor.isDetached == true })
    }

    @Test func commentsAreFoundAgainWithoutAnEditor() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let comment = try #require(fixture.book.create(range: range(of: "Third paragraph.", in: fixture), body: ""))
        #expect(await eventually { await stored(fixture).count == 1 })
        // The tab closes and opens again: a new book loads the comment from the store, in Read (no editor).
        fixture.model.closeFile(fixture.path, in: fixture.context)
        try ("Added at the top.\n\n" + Self.text).write(to: fixture.url, atomically: true, encoding: .utf8)
        fixture.model.openFile(fixture.path, in: fixture.context)
        let book = try #require(fixture.model.openMarkdownComments(for: fixture.path, in: fixture.context))
        #expect(await eventually { book.isLoaded && book.comments.count == 1 })
        #expect(book.session == nil)
        let anchor = try #require(book.comments.first).anchor
        #expect(book.comments.first?.id == comment.id)
        #expect(anchor.startLine == 9)
        #expect(((try String(contentsOf: fixture.url, encoding: .utf8)) as NSString).substring(with: anchor.range) == "Third paragraph.")
    }

    @Test func theSelectionLightsTheCommentItIsIn() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let comment = try #require(fixture.book.create(range: range(of: "Second paragraph stays.", in: fixture), body: ""))
        fixture.session.controller.textView.setSelectedRange(NSRange(location: range(of: "paragraph stays", in: fixture).location, length: 0))
        #expect(fixture.book.activeID == comment.id)
        fixture.session.controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(fixture.book.activeID == nil)
        #expect(fixture.book.comment(on: range(of: "Second paragraph stays.", in: fixture))?.id == comment.id)
        #expect(fixture.book.comment(on: range(of: "Second paragraph", in: fixture)) == nil)
    }

    @Test func revealSwitchesToEditAndSelectsTheText() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let comment = try #require(fixture.book.create(range: range(of: "Third paragraph.", in: fixture), body: ""))
        fixture.session.mode = .read
        fixture.book.reveal(comment.id)
        #expect(fixture.session.mode == .edit)
        #expect(await eventually { fixture.session.controller.selectedRange == comment.anchor.range })
    }

    // MARK: Sending

    @Test func copyingMarksCommentsSentToNoSessionAndSavesTheFileFirst() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        // A pasteboard of its own: the test leaves the user's clipboard alone.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("suijin.tests.comments.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        fixture.book.create(range: range(of: "Third paragraph.", in: fixture), body: "end with a question")
        type("Unsaved line.\n\n", at: 0, in: fixture)
        #expect(fixture.session.isDirty)
        fixture.book.copy(fixture.book.unsent, to: pasteboard)
        // The agent reads the file: it must hold the text the line numbers refer to.
        #expect(!fixture.session.isDirty)
        #expect(try String(contentsOf: fixture.url, encoding: .utf8).hasPrefix("Unsaved line.\n\n# Plan"))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains("Review comments on plan.md."))
        #expect(copied.contains("] line 9\n> Third paragraph.\nNote: end with a question\n"))
        #expect(!copied.contains("suijin comment"), "a copied block cannot be answered with the command")
        #expect(fixture.book.comments.first?.status == .sent)
        #expect(fixture.book.comments.first?.sentToSession == nil)
    }

    @Test func sendingAgainWithoutItsSessionMakesTheCommentOpen() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let comment = try #require(fixture.book.create(range: range(of: "Third paragraph.", in: fixture), body: ""))
        fixture.book.markSent([comment.id], to: UUID())
        fixture.book.sendAgain(comment.id)
        #expect(fixture.book.comments.first?.status == .open)
        #expect(fixture.book.unsent.map(\.id) == [comment.id])
    }
}
