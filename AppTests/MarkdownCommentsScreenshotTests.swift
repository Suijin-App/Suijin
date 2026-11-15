import AppKit
import Foundation
import SuijinCore
import SwiftUI
import Testing
@testable import Suijin

/// Offscreen renders of the comments on a Markdown tab: the editor with the Comments column showing every state a
/// comment can be in, the column alone as it opens in a popover on a narrow tab, its empty state, the note popover,
/// and the column while the helper is too old for agents to answer. Light and dark. Runs when `SUIJIN_SCREENSHOTS`
/// names an output folder; reviewed by eye.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] != nil))
struct MarkdownCommentsScreenshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] ?? NSTemporaryDirectory())

    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func commentsColumnAndPopovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-comment-shots-\(UUID().uuidString)/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent("release-checklist.md").standardizedFileURL
        let empty = root.appendingPathComponent("notes.md").standardizedFileURL
        try (MarkdownEditorScreenshotTests.document + "\nA closing paragraph that will be removed again.\n").write(to: file, atomically: true, encoding: .utf8)
        try "# Notes\n\nNothing commented yet.\n".write(to: empty, atomically: true, encoding: .utf8)
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.deletingLastPathComponent().appendingPathComponent("data"))
        await model.addWorkspace(at: root)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.selection = context
        model.runtimes.orchestration.assumesCommentSupportForPreview = true

        model.openFile(file.path, in: context)
        let book = try #require(model.openMarkdownComments(for: file.path, in: context))
        #expect(await eventually { book.isLoaded })
        let session = try #require(model.markdownSession(for: file.path, in: context, create: true))
        session.mode = .edit
        func range(_ text: String) -> NSRange { (session.text as NSString).range(of: text) }

        // One comment in each state.
        book.create(range: range("Everything that must be true"), body: "Say who checks this, and when.")
        let sent = try #require(book.create(range: range("Bump the version in *both* places"), body: ""))
        let fixed = try #require(book.create(range: range("Releases are notarized."), body: "Mention stapling here too."))
        let declined = try #require(book.create(range: range("| Sign | CI    |"), body: "Add a row for the changelog, with an owner, and keep the columns aligned with the header so the table still reads well as plain text."))
        book.create(range: range("A closing paragraph that will be removed again."), body: "Is this needed?")
        let agent = UUID()
        book.markSent([sent.id, fixed.id, declined.id], to: agent)
        for (id, outcome, reply) in [(fixed.id, MarkdownCommentOutcome.fixed, "Added a sentence on stapling after notarization."),
                                     (declined.id, .declined, "The changelog has no single owner; I left the table as it is and noted the question in the summary.")] {
            var comment = try #require(book.comments.first { $0.id == id })
            comment.resolve(outcome, reply: reply)
            book.showAnswer(of: comment)
        }
        let closing = range("\nA closing paragraph that will be removed again.\n")
        session.controller.textView.insertText("", replacementRange: closing)
        #expect(book.detached.count == 1)
        session.controller.textView.setSelectedRange(NSRange(location: range("Bump the version").location + 4, length: 0))

        for dark in [false, true] {
            try await MarkdownEditorScreenshotTests.render("markdown-comments", size: CGSize(width: 1200, height: 860), dark: dark, output: output) {
                FileViewer(path: file.path, context: context).environment(model)
            }
            // A narrow tab hides the column; its button opens the same panel in a popover of this size.
            try await MarkdownEditorScreenshotTests.render("markdown-comments-narrow-tab", size: CGSize(width: 560, height: 520), dark: dark, output: output) {
                FileViewer(path: file.path, context: context).environment(model)
            }
            try await MarkdownEditorScreenshotTests.render("markdown-comments-popover", size: CGSize(width: 300, height: 420), dark: dark, output: output) {
                MarkdownCommentsPanel(book: book).environment(model)
            }
            try await MarkdownEditorScreenshotTests.render("markdown-comment-composer", size: CGSize(width: 320, height: 170), dark: dark, output: output) {
                MarkdownCommentComposer(quote: "Bump the version in *both* places, the app and the helper, so the two never drift apart on a user's machine",
                                        note: "", isNew: true, onSubmit: { _ in }, onCancel: {})
            }
        }

        // The empty state, and the note shown while the running helper cannot take agents' answers yet.
        model.openFile(empty.path, in: context)
        let emptyBook = try #require(model.openMarkdownComments(for: empty.path, in: context))
        #expect(await eventually { emptyBook.isLoaded })
        emptyBook.panelPreference = true
        model.runtimes.orchestration.assumesCommentSupportForPreview = false
        for dark in [false, true] {
            try await MarkdownEditorScreenshotTests.render("markdown-comments-empty", size: CGSize(width: 900, height: 420), dark: dark, output: output) {
                FileViewer(path: empty.path, context: context).environment(model)
            }
        }
    }
}
