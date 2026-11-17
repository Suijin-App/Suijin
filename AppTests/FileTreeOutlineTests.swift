import AppKit
import Foundation
import SuijinCore
import SwiftUI
import Testing
@testable import Suijin

/// The inspector's file tree on the system outline view: selecting a row (what pressing does) opens and folds
/// nothing, a click opens a file or folds a folder once, a drag carries the rows' file URLs and opens nothing, and
/// refreshes, reveals and relaunches keep what is expanded and selected. Everything is driven through the controller
/// and the outline view's own API, in views that are never put on screen: no window is shown or made key and no
/// event is posted, so the tests never take the keyboard or the mouse from whoever uses the machine. AppKit itself
/// tells a click from a drag (it sends the action on a release without drag, and nothing for a drag).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct FileTreeOutlineTests {
    // MARK: Fixture

    /// What the controller asked of the app: files opened and the expanded folders it stored.
    @MainActor
    final class Recorder {
        var opened: [String] = []
        var expanded: Set<String> = []
    }

    @MainActor
    final class Fixture {
        let folder: URL
        let tree: FileTree
        let controller = FileOutlineController()
        let outline = FileOutlineView()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let recorder: Recorder

        init(files: [String], expanded: [String] = []) throws {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("suijin-tree-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
            self.folder = folder
            for file in files { try Self.write(folder.appendingPathComponent(file)) }
            let recorder = Recorder()
            self.recorder = recorder
            recorder.expanded = Set(expanded.map { folder.appendingPathComponent($0).path })
            tree = FileTree(directory: folder) { recorder.expanded }
            scroll.hasVerticalScroller = true
            scroll.documentView = outline
            controller.attach(outline)
            controller.open = { [recorder] url in recorder.opened.append(url.path) }
            controller.setExpanded = { [recorder] folders in recorder.expanded = folders }
            push()
        }

        static func write(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x\n".write(to: url, atomically: true, encoding: .utf8)
        }

        func path(_ relative: String) -> String { folder.appendingPathComponent(relative).path }

        /// Hands the controller the current state, as the SwiftUI view does on every change.
        func push(matches: [FileNode]? = nil, reveal: FileOutlineController.Reveal? = nil) {
            controller.update(.init(tree: tree, revision: tree.revision, matches: matches, expanded: recorder.expanded,
                                    reveal: reveal))
            scroll.layoutSubtreeIfNeeded()
        }

        var rowNames: [String] {
            (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode)?.name }
        }

        func row(_ relative: String) throws -> Int {
            let node = try #require(tree.node(at: path(relative)))
            let row = outline.row(forItem: node)
            try #require(row >= 0, "\(relative) is not on screen")
            return row
        }

        var selectedPaths: [String] {
            outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.url.path }
        }

        /// What a press on a row does: it selects the row (extending the selection with ⌘ or ⇧).
        func press(_ relative: String, extending: Bool = false) throws {
            outline.selectRowIndexes([try row(relative)], byExtendingSelection: extending)
        }

        /// A click: the press, then the outline view's action once the mouse is released without dragging.
        func click(_ relative: String, _ click: FileOutlineController.Click = .init()) throws {
            let row = try row(relative)
            try press(relative, extending: !click.modifiers.intersection([.command, .shift]).isEmpty)
            controller.handle(click, onRow: row)
            push()
        }

        /// What a drag does once it passes the system threshold: the outline view asks the data source for a
        /// pasteboard writer for each dragged row (all the selected rows when the drag starts on one of them, else
        /// that row) and sends no action. Returns the URLs the drag carries.
        func drag(from relative: String) throws -> [URL] {
            let row = try row(relative)
            if !outline.selectedRowIndexes.contains(row) { try press(relative) }
            let rows = outline.selectedRowIndexes
            #expect(outline.canDragRows(with: rows, at: outline.rect(ofRow: row).origin))
            let writers = rows.compactMap { outline.item(atRow: $0) }
                .compactMap { controller.outlineView(outline, pasteboardWriterForItem: $0) }
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("suijin.test.tree.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.writeObjects(writers)
            #expect(pasteboard.pasteboardItems?.allSatisfy { $0.types == [.fileURL] } == true, "file URLs only, no text")
            push()
            return pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Click versus drag

    @Test func pressingOpensNothingAndAClickOpensAFile() throws {
        let fixture = try Fixture(files: ["src/main.swift", "README.md"])
        defer { fixture.tearDown() }
        #expect(fixture.rowNames == ["src", "README.md"])

        try fixture.press("README.md")
        try fixture.press("src")
        #expect(fixture.recorder.opened.isEmpty, "selecting a row opens nothing")
        #expect(fixture.recorder.expanded.isEmpty, "selecting a folder folds nothing")

        try fixture.click("README.md")
        #expect(fixture.recorder.opened == [fixture.path("README.md")])
        #expect(fixture.selectedPaths == [fixture.path("README.md")])
        // A double click sends the action again (clickCount 2), which only selects the file's tab again.
        try fixture.click("README.md", .init(clickCount: 2))
        #expect(fixture.recorder.opened == [fixture.path("README.md"), fixture.path("README.md")])
    }

    @Test func clickingAFolderFoldsItOnceEveryTime() throws {
        let fixture = try Fixture(files: ["src/main.swift", "src/lib/util.swift", "README.md"])
        defer { fixture.tearDown() }
        let src = fixture.path("src")

        try fixture.click("src")
        #expect(fixture.recorder.expanded == [src])
        #expect(fixture.rowNames == ["src", "lib", "main.swift", "README.md"])
        // A second click on the now selected folder folds it again.
        try fixture.click("src")
        #expect(fixture.recorder.expanded.isEmpty)
        #expect(fixture.rowNames == ["src", "README.md"])

        // The disclosure triangle folds the row by itself; the action that may follow does not fold it back.
        let node = try #require(fixture.tree.node(at: src))
        fixture.outline.expandItem(node)
        try fixture.click("src", .init(onDisclosure: true))
        #expect(fixture.recorder.expanded == [src])

        // A double click folds once: its second click does not fold back what the first one did.
        try fixture.click("src")
        #expect(fixture.recorder.expanded.isEmpty)
        try fixture.click("src", .init(clickCount: 2))
        #expect(fixture.recorder.expanded.isEmpty)
        #expect(fixture.recorder.opened.isEmpty, "a folder never opens a tab")
    }

    @Test func modifiedClicksOnlySelect() throws {
        let fixture = try Fixture(files: ["src/main.swift", "a.txt", "c.txt"])
        defer { fixture.tearDown() }
        try fixture.click("a.txt", .init(modifiers: .control))
        try fixture.click("src", .init(modifiers: .command))
        try fixture.click("c.txt", .init(modifiers: .shift))
        #expect(fixture.recorder.opened.isEmpty)
        #expect(fixture.recorder.expanded.isEmpty)
        #expect(Set(fixture.selectedPaths) == [fixture.path("src"), fixture.path("a.txt"), fixture.path("c.txt")])
    }

    @Test func draggingCarriesFileURLsAndOpensNothing() throws {
        let fixture = try Fixture(files: ["src/main.swift", "a.txt", "b.txt", "c.txt"])
        defer { fixture.tearDown() }

        #expect(try fixture.drag(from: "a.txt").map(\.path) == [fixture.path("a.txt")])
        #expect(try fixture.drag(from: "src").map(\.path) == [fixture.path("src")], "folders drag too")
        #expect(fixture.recorder.opened.isEmpty)
        #expect(fixture.recorder.expanded.isEmpty)

        // A drag from a selected row carries every selected row and keeps the selection.
        let selection = [fixture.path("src"), fixture.path("a.txt"), fixture.path("c.txt")]
        fixture.outline.selectRowIndexes(IndexSet(try ["src", "a.txt", "c.txt"].map { try fixture.row($0) }),
                                         byExtendingSelection: false)
        #expect(Set(try fixture.drag(from: "c.txt").map(\.path)) == Set(selection))
        #expect(Set(fixture.selectedPaths) == Set(selection))
        // A drag from a row outside the selection carries that row alone.
        #expect(try fixture.drag(from: "b.txt").map(\.path) == [fixture.path("b.txt")])
        #expect(fixture.recorder.opened.isEmpty)
        #expect(fixture.recorder.expanded.isEmpty)
    }

    // MARK: Keyboard

    @Test func returnOpensTheSelectedFilesOrFoldsTheSelectedFolder() throws {
        let fixture = try Fixture(files: ["src/main.swift", "a.txt", "b.txt"])
        defer { fixture.tearDown() }
        // An event object handed straight to the view; nothing is posted to the system.
        let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: "\r",
                                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        fixture.outline.selectRowIndexes([try fixture.row("a.txt"), try fixture.row("b.txt")], byExtendingSelection: false)
        fixture.outline.keyDown(with: returnKey)
        #expect(fixture.recorder.opened == [fixture.path("a.txt"), fixture.path("b.txt")])

        fixture.outline.selectRowIndexes([try fixture.row("src")], byExtendingSelection: false)
        fixture.outline.keyDown(with: returnKey)
        fixture.push()
        #expect(fixture.recorder.expanded == [fixture.path("src")])
        #expect(fixture.rowNames.contains("main.swift"))
    }

    // MARK: Refresh, reveal, filter

    @Test func refreshKeepsExpansionSelectionAndScrollPosition() throws {
        let files = ["src/main.swift", "src/lib/util.swift"] + (0..<60).map { String(format: "f%02d.txt", $0) }
        let fixture = try Fixture(files: files, expanded: ["src", "src/lib"])
        defer { fixture.tearDown() }
        #expect(Array(fixture.rowNames.prefix(4)) == ["src", "lib", "util.swift", "main.swift"])
        let src = try #require(fixture.tree.node(at: fixture.path("src")))
        fixture.outline.selectRowIndexes([try fixture.row("src/main.swift")], byExtendingSelection: false)

        // Scrolled so that f30.txt is the first visible row.
        let anchorRow = try fixture.row("f30.txt")
        fixture.outline.scroll(NSPoint(x: 0, y: fixture.outline.rect(ofRow: anchorRow).minY))
        let firstVisible = { fixture.outline.row(at: NSPoint(x: 1, y: fixture.outline.visibleRect.minY + 1)) }
        #expect(firstVisible() == anchorRow)

        try Fixture.write(URL(fileURLWithPath: fixture.path("src/added.swift")))
        try Fixture.write(URL(fileURLWithPath: fixture.path("docs/guide.md")))
        try Fixture.write(URL(fileURLWithPath: fixture.path("e.txt")))
        fixture.tree.apply(.init(folders: ["", "src"]))
        fixture.push()

        #expect(Array(fixture.rowNames.prefix(6)) == ["docs", "src", "lib", "util.swift", "added.swift", "main.swift"])
        #expect(fixture.tree.node(at: fixture.path("src")) === src)
        #expect(fixture.outline.isItemExpanded(src))
        #expect(fixture.selectedPaths == [fixture.path("src/main.swift")])
        #expect(firstVisible() == (try fixture.row("f30.txt")), "the rows in view stay in view")
        #expect(fixture.recorder.opened.isEmpty)

        // The selected file deleted on disk leaves no selection behind.
        try FileManager.default.removeItem(atPath: fixture.path("src/main.swift"))
        fixture.tree.apply(.init(folders: ["src"]))
        fixture.push()
        #expect(!fixture.rowNames.contains("main.swift"))
        #expect(fixture.selectedPaths.isEmpty)

        // A folder folded away and changed meanwhile shows its new entries when it opens again.
        fixture.outline.collapseItem(src)
        try Fixture.write(URL(fileURLWithPath: fixture.path("src/later.swift")))
        fixture.tree.apply(.init(folders: ["src"]))
        fixture.push()
        fixture.outline.expandItem(src)
        #expect(Array(fixture.rowNames.prefix(6)) == ["docs", "src", "lib", "util.swift", "added.swift", "later.swift"])
        #expect(fixture.recorder.expanded == [fixture.path("src"), fixture.path("src/lib")])
    }

    @Test func revealUnfoldsTheWaySelectsAndOpensNothing() throws {
        let fixture = try Fixture(files: ["a/b/c/deep.txt", "a/other.txt", "z.txt"])
        defer { fixture.tearDown() }
        let request = FileOutlineController.Reveal(path: fixture.path("a/b/c/deep.txt"), id: UUID())
        fixture.push(reveal: request)
        #expect(fixture.recorder.expanded == [fixture.path("a"), fixture.path("a/b"), fixture.path("a/b/c")])
        #expect(fixture.selectedPaths == [fixture.path("a/b/c/deep.txt")])
        #expect(fixture.recorder.opened.isEmpty)

        // The same request is handled once; a folder is revealed unfolded; paths outside the folder are ignored.
        fixture.outline.deselectAll(nil)
        fixture.push(reveal: request)
        #expect(fixture.selectedPaths.isEmpty)
        fixture.push(reveal: .init(path: fixture.path("a/b"), id: UUID()))
        #expect(fixture.selectedPaths == [fixture.path("a/b")])
        fixture.push(reveal: .init(path: "/elsewhere/file.txt", id: UUID()))
        #expect(fixture.selectedPaths == [fixture.path("a/b")])
    }

    @Test func expansionChangedElsewhereIsFollowed() throws {
        let fixture = try Fixture(files: ["a/b/inner.txt", "a/top.txt"])
        defer { fixture.tearDown() }
        fixture.recorder.expanded = [fixture.path("a"), fixture.path("a/b")]
        fixture.push()
        #expect(fixture.rowNames == ["a", "b", "inner.txt", "top.txt"])
        // Folding the parent and opening it again brings its expanded child back with it.
        let a = try #require(fixture.tree.node(at: fixture.path("a")))
        fixture.outline.collapseItem(a)
        #expect(fixture.recorder.expanded == [fixture.path("a/b")])
        fixture.outline.expandItem(a)
        #expect(fixture.rowNames == ["a", "b", "inner.txt", "top.txt"])
        fixture.recorder.expanded = []
        fixture.push()
        #expect(fixture.rowNames == ["a"])
    }

    @Test func filteredRowsAreAFlatListThatOpensOnClick() throws {
        let fixture = try Fixture(files: ["src/main.swift", "src/lib/main.c", "README.md"])
        defer { fixture.tearDown() }
        let matches = ["src/lib/main.c", "src/main.swift"].compactMap { fixture.tree.node(at: fixture.path($0)) }
        fixture.push(matches: matches)
        #expect(fixture.rowNames == ["main.c", "main.swift"])
        #expect(!fixture.outline.isExpandable(matches[0]))
        let cell = try #require(fixture.outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? FileOutlineCell)
        #expect(cell.toolTip == fixture.path("src/lib/main.c"))

        // The click clears nothing by itself; the next update without matches is the filter cleared.
        try fixture.click("src/main.swift")
        #expect(fixture.recorder.opened == [fixture.path("src/main.swift")])
        #expect(fixture.rowNames == ["src", "README.md"], "clearing the filter shows the tree again")
    }

    // MARK: App wiring and persistence

    @Test func expandedFoldersSurviveARelaunch() async throws {
        let key = "fileTree.expandedFolders"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("kept").path
        try FileManager.default.createDirectory(atPath: kept, withIntermediateDirectories: true)
        let context = SessionContext.workspace(UUID())

        let first = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        first.setExpandedFolders([kept, root.appendingPathComponent("gone").path], in: context)
        let relaunched = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        #expect(relaunched.expandedFolders(in: context) == [kept], "folders deleted since are dropped")
        relaunched.setExpandedFolders([], in: context)
        #expect((UserDefaults.standard.dictionary(forKey: key)?[context.storageValue]) == nil)
    }

    /// A window that is never ordered in: SwiftUI lays out and runs the view's tasks, nothing appears on screen and
    /// nothing takes the keyboard.
    private func hiddenWindow<V: View>(width: CGFloat, dark: Bool = false, _ view: V) -> (NSWindow, NSHostingView<V>) {
        let window = OffscreenWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        return (window, host)
    }

    /// The inspector's view drives the app: a click on a file opens its tab, a click on a folder stores it expanded.
    @Test func fileTreeViewOpensTabsAndStoresFolding() async throws {
        let key = "fileTree.expandedFolders"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("work", isDirectory: true)
        for file in ["src/main.swift", "README.md"] { try Fixture.write(folder.appendingPathComponent(file)) }
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        let directory = try #require(model.directory(of: context)).standardizedFileURL

        let (window, host) = hiddenWindow(width: 300, FileTreeView(context: context).environment(model))
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let outline = try #require(await eventuallyValue { () -> FileOutlineView? in
            host.layoutSubtreeIfNeeded()
            return Self.outline(in: host)
        })
        #expect(await eventually { host.layoutSubtreeIfNeeded(); return outline.numberOfRows == 2 })
        let controller = try #require(outline.target as? FileOutlineController)

        controller.handle(.init(), onRow: 1)
        let readme = directory.appendingPathComponent("README.md").path
        #expect(model.currentTab(in: context) == .file(readme))
        controller.handle(.init(), onRow: 0)
        #expect(model.expandedFolders(in: context) == [directory.appendingPathComponent("src").path])
        #expect(await eventually { host.layoutSubtreeIfNeeded(); return outline.numberOfRows == 3 })
        model.setExpandedFolders([], in: context)
    }

    /// Offscreen renders of the tree (a revealed file selected) and of the filtered list, in a narrow and a wide
    /// inspector, light and dark. Runs when `SUIJIN_SCREENSHOTS` names an output folder; reviewed by eye. The views'
    /// cached display is drawn over the window background; the selection's material does not render this way.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] != nil))
    func screenshots() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"]))
        let key = "fileTree.expandedFolders"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("demo", isDirectory: true)
        let files = ["App/Features/Files/FileOutline.swift", "App/Features/Files/FileTreeView.swift",
                     "App/Features/Terminal/A very long file name that cannot fit in a narrow inspector.swift",
                     "App/Resources/Localizable.xcstrings", "docs/architecture.md", "Assets/logo.png", "Package.swift",
                     "README.md", "scripts/ci-local.sh"]
        for file in files { try Fixture.write(folder.appendingPathComponent(file)) }
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        let directory = try #require(model.directory(of: context)).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        func render(_ name: String, width: CGFloat, dark: Bool, _ view: some View) async throws {
            let (window, host) = hiddenWindow(width: width, dark: dark, view.environment(model))
            // Released afterwards, so that this view does not take the next render's reveal request.
            defer { window.contentView = nil; window.close() }
            for _ in 0..<10 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let image = NSImage(size: host.bounds.size)
            image.lockFocus()
            (window.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: host.bounds.size).fill()
            }
            rep.draw(in: NSRect(origin: .zero, size: host.bounds.size))
            image.unlockFocus()
            let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
        }

        for dark in [false, true] {
            for width in [220.0, 440.0] {
                model.setExpandedFolders([], in: context)
                model.fileTreeReveal = (directory.appendingPathComponent(files[2]).path, UUID())
                try await render("file-tree", width: width, dark: dark, InspectorView(context: context))
                let tree = FileTree(directory: directory) { [] }
                let matches = ["App/Features/Files/FileOutline.swift", "App/Features/Files/FileTreeView.swift", files[2]]
                    .compactMap { tree.node(at: directory.appendingPathComponent($0).path) }
                let filtered = FileOutline(content: .init(tree: tree, revision: 0, matches: matches, expanded: [], reveal: nil),
                                           open: { _ in }, setExpanded: { _ in })
                try await render("file-tree-filtered", width: width, dark: dark, filtered)
            }
        }
        model.setExpandedFolders([], in: context)
    }

    private static func outline(in view: NSView?) -> FileOutlineView? {
        guard let view else { return nil }
        if let outline = view as? FileOutlineView { return outline }
        for subview in view.subviews { if let found = outline(in: subview) { return found } }
        return nil
    }

    private func eventuallyValue<T>(_ timeout: Duration = .seconds(5), _ value: () -> T?) async -> T? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = value() { return value }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return value()
    }

    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        await eventuallyValue(timeout) { condition() ? true : nil } ?? false
    }
}
