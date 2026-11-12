import AppKit
import Foundation
import SevindaCore
import SevindaTerminal
import SwiftUI
import Testing
@testable import Sevinda

/// Paths printed by a real shell in a real terminal pane: underlined when they exist, resolved against the directory the
/// shell reports (OSC 7) after a `cd`. Output imitating agents is printed with `printf`; no agent runs.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct TerminalPathLinkTests {
    @MainActor
    struct Fixture {
        let root: URL
        let folder: URL
        let model: AppModel
        let context: SessionContext
        let id: UUID
        let view: SevindaTerminalView
        let window: NSWindow

        func close() async {
            window.orderOut(nil)
            await model.closeSession(id)
            try? FileManager.default.removeItem(at: root)
        }

        /// Types a command into the shell.
        func run(_ command: String) {
            model.runtimes.runtime(for: id)?.terminal.send(command + "\n")
        }

        func waitForLink(_ displayText: String, timeout: Duration = .seconds(10)) async -> TerminalLink? {
            let start = ContinuousClock.now
            while ContinuousClock.now - start < timeout {
                if let link = view.shownLinks.last(where: { $0.match.displayText == displayText }) { return link }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
    }

    static func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-pathlinks-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true).standardizedFileURL
        for directory in ["docs", "src", "sub"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for file in ["docs/plan.md", "src/a.ts", "sub/inner.md", "README.md"] {
            try "content\n".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.selection = context
        await model.runtimes.bootstrap()
        let id = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
        let runtime = try #require(model.runtimes.runtime(for: id))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TerminalPane(runtime: runtime, context: context, isFocused: true).environment(model))
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        return Fixture(root: root, folder: folder, model: model, context: context, id: id, view: runtime.terminal.view, window: window)
    }

    /// The file a link opens, its path with symbolic links resolved (`/var` is `/private/var`).
    static func file(_ link: TerminalLink) -> TerminalFileTarget? {
        guard case .file(var file) = link.target else { return nil }
        file.path = URL(fileURLWithPath: file.path).resolvingSymlinksInPath().path
        return file
    }

    static func real(_ folder: URL, _ relative: String) -> String {
        folder.appendingPathComponent(relative).resolvingSymlinksInPath().path
    }

    @Test func existingPathsAreUnderlinedAndResolvedFromTheShellsDirectory() async throws {
        let fixture = try await Self.makeFixture()
        // Built from pieces so the typed command line itself names none of the paths.
        fixture.run(#"p=plan; printf '%s\n' "Read \`docs/$p.md\` then src/a.ts:12:4 and src/miss$p.ts""#)
        let plan = try #require(await fixture.waitForLink("docs/plan.md"))
        #expect(Self.file(plan) == TerminalFileTarget(path: Self.real(fixture.folder, "docs/plan.md"), isDirectory: false))
        let source = try #require(await fixture.waitForLink("src/a.ts:12:4"))
        #expect(Self.file(source) == TerminalFileTarget(path: Self.real(fixture.folder, "src/a.ts"), isDirectory: false, line: 12, column: 4))
        #expect(!fixture.view.shownLinks.contains { $0.match.text == "src/missplan.ts" }, "a missing file is not underlined")

        // After `cd`, a bare name resolves in the new directory, which the shell reports at its next prompt.
        fixture.run(#"cd sub && n=inner; printf '%s\n' "$n.md""#)
        let inner = try #require(await fixture.waitForLink("inner.md"))
        #expect(Self.file(inner) == TerminalFileTarget(path: Self.real(fixture.folder, "sub/inner.md"), isDirectory: false))
        #expect(fixture.view.reportedDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == Self.real(fixture.folder, "sub"))
        await fixture.close()
    }

    @Test func codeViewerScrollsToTheRequestedLine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-line-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.swift")
        try (1...200).map { "let value\($0) = \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: root)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.fileLineReveal = (file.path, 150, UUID())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FileViewer(path: file.path, context: context).environment(model))
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(textView).first
        }
        var selected: String?
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(5) {
            if let text = window.contentView.flatMap(textView), text.selectedRange().length > 0 {
                selected = (text.string as NSString).substring(with: text.selectedRange())
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(selected == "let value150 = 150\n")
        #expect(model.fileLineReveal == nil, "the request is used once")
    }

    /// The inspector's own preferences, which opening a folder writes; the test host shares the app's defaults.
    static let inspectorKeys = ["inspector.shown", "inspector.tab"]

    @Test func commandClickOpensFilesAtTheirLineAndFoldersInTheTree() async throws {
        let saved = Self.inspectorKeys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(Self.inspectorKeys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let fixture = try await Self.makeFixture()
        fixture.run(#"s=src; printf '%s\n' "$s/a.ts:12:4 in ./$s""#)
        let source = try #require(await fixture.waitForLink("src/a.ts:12:4"))
        let folder = try #require(await fixture.waitForLink("./src"))
        let window = fixture.window

        func commandClick(_ link: TerminalLink) throws {
            let view = fixture.view
            let segment = try #require(link.match.segments.first)
            let cell = view.getTerminal().buffer.yDisp
            let size = try #require(view.cellSizeInPixels(source: view.getTerminal()))
            let scale = window.backingScaleFactor
            let point = view.convert(CGPoint(x: (CGFloat(segment.columns.lowerBound) + 0.5) * CGFloat(size.width) / scale,
                                             y: view.bounds.height - (CGFloat(segment.row - cell) + 0.5) * CGFloat(size.height) / scale),
                                     to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                view.perform(type == .leftMouseDown ? #selector(NSView.mouseDown(with:)) : #selector(NSView.mouseUp(with:)),
                             with: NSEvent.mouseEvent(with: type, location: point, modifierFlags: .command,
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                      clickCount: 1, pressure: 1))
            }
        }

        try commandClick(source)
        let opened = try #require(fixture.model.currentTab(in: fixture.context))
        guard case .file(let path) = opened else { Issue.record("no file tab: \(opened)"); return }
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath().path == Self.real(fixture.folder, "src/a.ts"))
        #expect(fixture.model.fileLineReveal?.line == 12)

        try commandClick(folder)
        #expect(fixture.model.fileTreeReveal.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path } == Self.real(fixture.folder, "src"))
        await fixture.close()
    }
}

/// The right-click menu on paths and links, and finding the full path of an elided one.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct TerminalLinkMenuTests {
    private func titles(_ menu: NSMenu?) -> [String] {
        menu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
    }

    @Test func menusForFilesFoldersLinksElidedAndMissingPaths() async throws {
        let fixture = try await TerminalPathLinkTests.makeFixture()
        defer { Task { await fixture.close() } }
        let view = fixture.view
        let menu = TerminalLinkMenu(model: fixture.model, context: fixture.context, view: view, bases: [fixture.folder])
        let point = CGPoint(x: 10, y: 10)
        func request(_ text: String, kind: TerminalPathMatch.Kind, line: Int? = nil) -> TerminalLinkMenuRequest {
            TerminalLinkMenuRequest(link: nil, candidates: [TerminalPathMatch(kind: kind, text: text, displayText: text, line: line,
                                                                              segments: [.init(row: 0, columns: 0..<text.count)])],
                                    point: point)
        }
        let terminal = ["—", "Copy", "Paste", "Select All", "Find…"]

        #expect(titles(menu.menu(for: request("src/a.ts", kind: .path, line: 12))) == [
            "Open", "Open With Default App", "Reveal in File Tree", "Show in Finder", "—", "Copy Path", "Copy Relative Path",
            "Copy Path with Line",
        ] + terminal)
        #expect(titles(menu.menu(for: request("./src", kind: .path))) == [
            "Open", "Reveal in File Tree", "Show in Finder", "—", "Copy Path", "Copy Relative Path",
        ] + terminal)
        #expect(titles(menu.menu(for: request("https://example.com/a", kind: .url))) == ["Open Link", "Copy Link"] + terminal)
        #expect(titles(menu.menu(for: request("…/a.ts", kind: .elided))) == ["Find Full Path…", "Copy Text"] + terminal)
        #expect(titles(menu.menu(for: request("src/none.ts", kind: .path))) == ["Copy Text"] + terminal)
        #expect(menu.menu(for: request("src/a.ts", kind: .path))?.items.first { $0.title == "Copy" }?.isEnabled == false,
                "Copy needs a selection")

        // Copy Path with Line puts the absolute path and its line on the pasteboard.
        let saved = NSPasteboard.general.string(forType: .string)
        defer { if let saved { TerminalLinkMenu.copy(saved) } }
        let item = try #require(menu.menu(for: request("src/a.ts", kind: .path, line: 12))?.items.first { $0.title == "Copy Path with Line" })
        _ = item.target?.perform(item.action, with: item)
        #expect(NSPasteboard.general.string(forType: .string)?.hasSuffix("/src/a.ts:12") == true)
    }

    @Test func rightClickOnTheScreenFindsTheCandidateUnderThePointer() async throws {
        let fixture = try await TerminalPathLinkTests.makeFixture()
        defer { Task { await fixture.close() } }
        fixture.run(#"d=docs; printf '%s\n' "see $d/plan.md and …/sub/inner.md and plain words""#)
        let plan = try #require(await fixture.waitForLink("docs/plan.md"))
        let view = fixture.view
        let geometry = try #require(view.cellGeometry())
        func point(row: Int, column: Int) -> CGPoint {
            let rect = geometry.rect(row: row - view.getTerminal().buffer.yDisp, columns: column..<(column + 1))
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        let segment = try #require(plan.match.segments.first)
        let onPlan = try #require(view.linkMenuRequest(at: point(row: segment.row, column: segment.columns.lowerBound + 2)))
        #expect(onPlan.link == plan)
        let elidedColumn = segment.columns.upperBound + " and ".count + 2
        let onElided = try #require(view.linkMenuRequest(at: point(row: segment.row, column: elidedColumn)))
        #expect(onElided.link == nil && onElided.candidates.first?.kind == .elided)
        #expect(TerminalLinkMenu.subject(of: onElided, bases: [fixture.folder]) == .elided("…/sub/inner.md"))
        // Plain words keep the terminal's own (absent) menu.
        let wordsColumn = segment.columns.upperBound + " and …/sub/inner.md and pl".count
        #expect(view.linkMenuRequest(at: point(row: segment.row, column: wordsColumn)) == nil)
    }

    @Test func findFullPathListsMatchesOpensASingleOneAndSaysWhenThereIsNone() async throws {
        let fixture = try await TerminalPathLinkTests.makeFixture()
        defer { Task { await fixture.close() } }
        try FileManager.default.createDirectory(at: fixture.folder.appendingPathComponent("other/sub"), withIntermediateDirectories: true)
        try "x\n".write(to: fixture.folder.appendingPathComponent("other/sub/inner.md"), atomically: true, encoding: .utf8)

        func show(_ elided: String) async throws -> (NSWindow, () -> Bool) {
            var dismissed = false
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 320), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: FullPathFinder(elided: elided, context: fixture.context) { dismissed = true }
                .environment(fixture.model))
            window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(600))
            return (window, { dismissed })
        }

        // Two files end with sub/inner.md: listed, nothing opened yet.
        let (several, severalDismissed) = try await show("…/sub/inner.md")
        #expect(!severalDismissed())
        #expect(fixture.model.openFiles[fixture.context]?.isEmpty ?? true)
        several.orderOut(nil)

        // One file ends with docs/plan.md: it opens at once.
        let (single, singleDismissed) = try await show("…/docs/plan.md")
        #expect(singleDismissed())
        #expect(fixture.model.openFiles[fixture.context]?.contains { $0.hasSuffix("/docs/plan.md") } == true)
        single.orderOut(nil)

        let (none, noneDismissed) = try await show("…/nothing/here.md")
        #expect(!noneDismissed())
        none.orderOut(nil)
    }
}
