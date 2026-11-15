import Foundation
import SuijinCore
import SuijinMarkdown
import Testing
@testable import Suijin

/// ⌘-clicked terminal links: files open in a viewer tab of the session's context, web links go to the browser.
@MainActor
struct TerminalLinkTests {
    @Test func pathsOpenFileTabsAndWebLinksDoNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-links-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = docs.appendingPathComponent("plan.md")
        try "# Plan\n".write(to: plan, atomically: true, encoding: .utf8)
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: root)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        let path = plan.standardizedFileURL.path

        #expect(model.openTerminalLink(plan.path, in: context, relativeTo: nil))
        #expect(model.currentTab(in: context) == .file(path))
        #expect(model.openTerminalLink("docs/plan.md:12:4", in: context, relativeTo: root))
        #expect(model.openTerminalLink("file://\(plan.path)", in: context, relativeTo: nil))
        #expect(model.openFiles[context] == [path], "the same file opens once")

        #expect(!model.openTerminalLink("https://example.com/a.md", in: context, relativeTo: root))
        #expect(model.openTerminalLink("docs/missing.md", in: context, relativeTo: root), "a dead path is swallowed, not sent to the browser")
        #expect(model.openFiles[context] == [path])

        model.closeActive(in: context)
        #expect(model.openFiles[context]?.isEmpty == true)
    }

    @Test func fileViewerReadsMarkdownTextImagesAndRejectsBinary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-viewer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("a.md"), text = root.appendingPathComponent("a.swift"), binary = root.appendingPathComponent("a.bin")
        try "# Title".write(to: markdown, atomically: true, encoding: .utf8)
        try "let x = 1".write(to: text, atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: binary)
        if case .markdown(let value) = FileViewer.read(markdown) { #expect(value == "# Title") } else { Issue.record("not markdown") }
        if case .code(let value, let language) = FileViewer.read(text) {
            #expect(value == "let x = 1")
            #expect(language == "swift")
        } else {
            Issue.record("Swift source not shown as highlighted code")
        }
        let plain = root.appendingPathComponent("a.log")
        try "line".write(to: plain, atomically: true, encoding: .utf8)
        if case .text(let value) = FileViewer.read(plain) { #expect(value == "line") } else { Issue.record("not text") }
        if case .unsupported = FileViewer.read(binary) {} else { Issue.record("binary shown as text") }
        if case .missing = FileViewer.read(root.appendingPathComponent("nope.md")) {} else { Issue.record("missing file not reported") }
    }
}

struct MarkdownDocumentTests {
    @Test func frontMatterIsSplitFromTheBody() {
        let document = MarkdownDocument("---\ntitle: \"Plan\"\nstatus: pending\ntags: [a, b]\n---\n\n# Plan\nText")
        #expect(document.frontMatter.map(\.key) == ["title", "status", "tags"])
        #expect(document.frontMatter.first?.value == "Plan")
        #expect(document.body == "\n# Plan\nText")
        #expect(MarkdownDocument("# No front matter").frontMatter.isEmpty)
        #expect(MarkdownDocument("---\nunclosed").body == "---\nunclosed")
    }
}
