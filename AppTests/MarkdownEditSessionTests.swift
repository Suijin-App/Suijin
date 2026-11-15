import Foundation
import SuijinCore
import Testing
@testable import Suijin

/// Editing a Markdown file in its tab: what is written is exactly what the editor holds, and a file that changes on
/// disk meanwhile is never overwritten or dropped without the user's answer.
@MainActor
struct MarkdownEditSessionTests {
    private func makeFile(_ bytes: Data, name: String = "note.md") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func makeFile(_ text: String) throws -> URL { try makeFile(Data(text.utf8)) }

    private func cleanUp(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    /// Types `text` at `location`, as the keyboard would.
    private func type(_ text: String, at location: Int, in session: MarkdownEditSession) {
        session.controller.textView.insertText(text, replacementRange: NSRange(location: location, length: 0))
    }

    // MARK: Bytes

    @Test(arguments: [
        "# Title\n\ntext\n",
        "# Title\r\n\r\ntext\r\n",
        "no trailing newline",
        "trailing blank lines\n\n\n",
        "Tiếng Việt 🎉 **đậm**\n",
        "",
    ])
    func loadingAndSavingKeepsEveryByte(text: String) throws {
        let url = try makeFile(text)
        defer { cleanUp(url) }
        let contents = try MarkdownFile.read(url)
        #expect(contents.text == text)
        try MarkdownFile.write(contents, to: url)
        #expect(try Data(contentsOf: url) == Data(text.utf8))
    }

    @Test func aByteOrderMarkIsKeptOutOfTheTextAndWrittenBack() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("# Title\n".utf8)
        let url = try makeFile(bytes)
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        #expect(session.text == "# Title\n")
        type("New ", at: 2, in: session)
        #expect(session.save())
        #expect(try Data(contentsOf: url) == Data([0xEF, 0xBB, 0xBF]) + Data("# New Title\n".utf8))
    }

    @Test func savingChangesOnlyWhatWasTyped() throws {
        let original = "# Title\n\n- one\n- two   \n\n\ttabbed\n\nlast line without newline"
        let url = try makeFile(original)
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        #expect(!session.isDirty)
        type("x", at: (original as NSString).range(of: "one").location, in: session)
        #expect(session.isDirty)
        #expect(session.save())
        #expect(!session.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == original.replacingOccurrences(of: "- one", with: "- xone"))
    }

    @Test func returnInACRLFFileInsertsCRLF() throws {
        let url = try makeFile("one\r\ntwo\r\n")
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        session.controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        session.controller.textView.insertNewline(nil)
        type("new", at: 5, in: session)
        #expect(session.save())
        #expect(try Data(contentsOf: url) == Data("one\r\nnew\r\ntwo\r\n".utf8))
    }

    @Test func aLineFeedPastedIntoACRLFFileIsSavedAsCRLF() throws {
        let url = try makeFile("one\r\ntwo\r\n")
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        type("a\nb\n", at: 0, in: session)
        #expect(session.save())
        #expect(try Data(contentsOf: url) == Data("a\r\nb\r\none\r\ntwo\r\n".utf8))
        #expect(session.text == "a\r\nb\r\none\r\ntwo\r\n")
        #expect(!session.isDirty)
    }

    @Test func savingKeepsThePermissionsAndWritesThroughASymbolicLink() throws {
        let url = try makeFile("text\n")
        defer { cleanUp(url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let link = url.deletingLastPathComponent().appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let session = try #require(MarkdownEditSession(path: link.path))
        type("more ", at: 0, in: session)
        #expect(session.save())
        #expect(try String(contentsOf: url, encoding: .utf8) == "more text\n")
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == url.path)
    }

    @Test func aFileThatIsNotUTF8CannotBeEdited() throws {
        let url = try makeFile(Data([0xFF, 0xFE, 0x41, 0x00]))
        defer { cleanUp(url) }
        #expect(MarkdownEditSession(path: url.path) == nil)
    }

    // MARK: Dirty state

    @Test func undoingBackToTheSavedTextIsNotDirty() throws {
        let url = try makeFile("text\n")
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        type("x", at: 0, in: session)
        #expect(session.isDirty && session.canSave)
        session.controller.undoManager.undo()
        #expect(session.text == "text\n")
        #expect(!session.isDirty && !session.canSave)
    }

    @Test func aFailedSaveKeepsTheTextAndReportsTheError() throws {
        let url = try makeFile("text\n")
        let session = try #require(MarkdownEditSession(path: url.path))
        type("kept ", at: 0, in: session)
        // The folder is gone, so the file cannot be written back.
        cleanUp(url)
        #expect(!session.save())
        #expect(session.saveError != nil)
        #expect(session.text == "kept text\n")
        #expect(session.isDirty)
    }

    // MARK: Disk changes

    @Test func itsOwnSaveIsNotADiskChange() throws {
        let url = try makeFile("text\n")
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        type("x", at: 0, in: session)
        #expect(session.save())
        type("y", at: 0, in: session)
        session.diskMayHaveChanged()
        #expect(session.conflict == nil)
        #expect(session.text == "yxtext\n")
    }

    @Test func anOutsideChangeWithoutUnsavedEditsReplacesTheText() throws {
        let url = try makeFile("one\ntwo\n")
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        var replaced = 0
        session.onTextReplaced = { replaced += 1 }
        try "one\ntwo\nthree\n".write(to: url, atomically: true, encoding: .utf8)
        session.diskMayHaveChanged()
        #expect(session.text == "one\ntwo\nthree\n")
        #expect(session.conflict == nil)
        #expect(!session.isDirty)
        #expect(replaced == 1)
    }

    @Test func anOutsideChangeWithUnsavedEditsAsksAndReloadTakesTheDiskVersion() throws {
        let url = try makeFile("text\n")
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        type("mine ", at: 0, in: session)
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        session.diskMayHaveChanged()
        #expect(session.conflict == .changed)
        // Nothing is lost on either side until the user answers.
        #expect(session.text == "mine text\n")
        #expect(try String(contentsOf: url, encoding: .utf8) == "theirs\n")
        #expect(!session.save(), "saving must not overwrite the newer version")
        #expect(try String(contentsOf: url, encoding: .utf8) == "theirs\n")

        session.reload()
        #expect(session.text == "theirs\n")
        #expect(session.conflict == nil)
        #expect(!session.isDirty)
    }

    @Test func keepingOwnChangesAsksOnceMoreBeforeOverwriting() throws {
        let url = try makeFile("text\n")
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        type("mine ", at: 0, in: session)
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        session.diskMayHaveChanged()
        session.keepOwnChanges()
        #expect(session.conflict == nil)
        // The same version on disk does not raise the conflict again.
        session.diskMayHaveChanged()
        #expect(session.conflict == nil)

        #expect(!session.save())
        #expect(session.isConfirmingOverwrite)
        #expect(try String(contentsOf: url, encoding: .utf8) == "theirs\n")
        session.isConfirmingOverwrite = false
        #expect(session.save(overwriting: true))
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine text\n")
        #expect(!session.isDirty)
        // Answered: the next save is a plain save.
        type("x", at: 0, in: session)
        #expect(session.save())
    }

    @Test func aSecondOutsideChangeAfterKeepingAsksAgain() throws {
        let url = try makeFile("text\n")
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        type("mine ", at: 0, in: session)
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        session.diskMayHaveChanged()
        session.keepOwnChanges()
        try "theirs again\n".write(to: url, atomically: true, encoding: .utf8)
        session.diskMayHaveChanged()
        #expect(session.conflict == .changed)
    }

    @Test func aDeletedFileKeepsTheTextAndSaveCreatesItAgain() throws {
        let url = try makeFile("text\n")
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        try FileManager.default.removeItem(at: url)
        session.diskMayHaveChanged()
        #expect(session.conflict == .deleted)
        #expect(session.text == "text\n")
        #expect(session.canSave)
        #expect(session.save())
        #expect(try String(contentsOf: url, encoding: .utf8) == "text\n")
        #expect(session.conflict == nil)
    }

    @Test func aConflictedSaveShowsTheEditorWithItsQuestion() throws {
        let url = try makeFile("text\n")
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        type("mine ", at: 0, in: session)
        session.mode = .read
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(!session.save())
        #expect(session.conflict == .changed)
        #expect(session.mode == .edit, "the bar with Reload and Keep My Changes is in the editor")
    }

    @Test func savingACRLFFileDownToOneLineIsStillItsOwnSave() throws {
        let url = try makeFile("one\r\ntwo\r\n")
        defer { cleanUp(url) }
        let session = try #require(MarkdownEditSession(path: url.path))
        session.controller.textView.insertText("", replacementRange: NSRange(location: 3, length: 7))
        #expect(session.text == "one")
        #expect(session.save())
        type("x", at: 0, in: session)
        session.diskMayHaveChanged()
        #expect(session.conflict == nil, "its own save is not a change by someone else")
        // The file is still a CRLF file: a new line gets CRLF.
        session.controller.textView.setSelectedRange(NSRange(location: 4, length: 0))
        session.controller.textView.insertNewline(nil)
        #expect(session.save())
        #expect(try Data(contentsOf: url) == Data("xone\r\n".utf8))
    }

    @Test func savingKeepsExtendedAttributes() throws {
        let url = try makeFile("text\n")
        defer { cleanUp(url) }
        let name = "com.tekmium.suijin.test"
        let value = Array("tagged".utf8)
        #expect(setxattr(url.path, name, value, value.count, 0, 0) == 0)
        let session = try #require(MarkdownEditSession(path: url.path))
        type("more ", at: 0, in: session)
        #expect(session.save())
        var buffer = [UInt8](repeating: 0, count: 32)
        let length = getxattr(url.path, name, &buffer, buffer.count, 0, 0)
        #expect(length == value.count)
        #expect(Array(buffer.prefix(max(0, length))) == value)
        // No staging file is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["note.md"])
    }

    @Test func savingThroughALinkWhoseFileWasDeletedCreatesTheFileAndKeepsTheLink() throws {
        let url = try makeFile("text\n")
        defer { cleanUp(url) }
        let link = url.deletingLastPathComponent().appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let session = try #require(MarkdownEditSession(path: link.path))
        try FileManager.default.removeItem(at: url)
        session.diskMayHaveChanged()
        #expect(session.conflict == .deleted)
        #expect(session.save())
        #expect(try String(contentsOf: url, encoding: .utf8) == "text\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == url.path)
    }

    // MARK: Tabs

    private func makeModel(with url: URL) async throws -> (AppModel, SessionContext) {
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: url.deletingLastPathComponent().appendingPathComponent("data"))
        await model.addWorkspace(at: url.deletingLastPathComponent())
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.selection = context
        model.openFile(url.path, in: context)
        return (model, context)
    }

    @Test func closingATabWithUnsavedChangesAsksFirst() async throws {
        let url = try makeFile("text\n")
        defer { cleanUp(url) }
        let (model, context) = try await makeModel(with: url)
        let session = try #require(model.markdownSession(for: url.path, in: context, create: true))
        model.requestCloseFile(url.path, in: context)
        #expect(model.openFiles[context]?.isEmpty == true, "an unedited tab closes at once")

        model.openFile(url.path, in: context)
        let edited = try #require(model.markdownSession(for: url.path, in: context, create: true))
        #expect(edited !== session)
        type("x", at: 0, in: edited)
        model.requestCloseFile(url.path, in: context)
        #expect(model.pendingFileClose == FileTabKey(context: context, path: url.path))
        #expect(model.openFiles[context] == [url.path], "nothing closes before the answer")
        #expect(model.unsavedMarkdownSessions.count == 1)
        model.closeFile(url.path, in: context)
        #expect(model.markdownSessions.isEmpty)
    }

    @Test func theEditingStateSurvivesSwitchingTabs() async throws {
        let url = try makeFile("text\n")
        defer { cleanUp(url) }
        let (model, context) = try await makeModel(with: url)
        let session = try #require(model.markdownSession(for: url.path, in: context, create: true))
        session.mode = .edit
        type("x", at: 0, in: session)
        model.selectedTab[context] = .changes
        model.selectedTab[context] = .file(url.path)
        let again = try #require(model.markdownSession(for: url.path, in: context))
        #expect(again === session)
        #expect(again.mode == .edit)
        #expect(again.text == "xtext\n")
    }
}
