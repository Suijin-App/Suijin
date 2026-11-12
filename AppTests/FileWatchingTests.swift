import AppKit
import CoreServices
import Foundation
import SevindaCore
import SwiftUI
import Testing
@testable import Sevinda

/// Changes made outside Sevinda (Finder, editors, agents' shells) reach the file tree and open viewer tabs.
@MainActor
@Suite(.serialized)
struct FileWatchingTests {
    // MARK: Watcher

    @Test func watcherReportsCreatesDeletesRenamesAndAtomicSavesByFolder() async throws {
        let root = try TemporaryFolder()
        try root.write("sub/a.txt", "one")
        let recorder = ChangeRecorder()
        // The temporary folder lives under /var, a link to /private/var: reported paths map back to the root as given.
        let watcher = FileSystemWatcher(root: root.url) { recorder.changes.append($0) }
        defer { watcher.stop() }
        #expect(watcher.isWatching)
        try await settle()

        try root.write("b.txt", "new")
        try await recorder.waitFor { $0.folders.contains("") }

        try root.write("sub/a.txt", "two", atomically: false)
        try await recorder.waitFor { $0.folders.contains("sub") }

        try root.write("sub/a.txt", "three", atomically: true)
        try await recorder.waitFor { $0.folders.contains("sub") }

        try FileManager.default.moveItem(at: root.url("b.txt"), to: root.url("c.txt"))
        try await recorder.waitFor { $0.folders.contains("") }

        try FileManager.default.removeItem(at: root.url("sub/a.txt"))
        try await recorder.waitFor { $0.folders.contains("sub") }
    }

    @Test func watcherCoalescesBurstsAndStillReportsUnderSteadyActivity() async throws {
        let root = try TemporaryFolder()
        let recorder = ChangeRecorder()
        let watcher = FileSystemWatcher(root: root.url) { recorder.changes.append($0) }
        defer { watcher.stop() }
        try await settle()

        // Twenty writes 20 ms apart arrive as one or two batches, not twenty reloads.
        for index in 0..<20 {
            try root.write("burst.txt", "\(index)", atomically: false)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await recorder.waitFor { $0.folders.contains("") }
        try await Task.sleep(for: .milliseconds(600))
        #expect(recorder.changes.count <= 3, "got \(recorder.changes.count) deliveries")

        // A folder written every 100 ms never goes quiet; a change beside it is still reported within the maximum delay.
        recorder.changes.removeAll()
        let busy = Task {
            for index in 0..<30 {
                try? root.write("busy/log.txt", "\(index)", atomically: false)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { busy.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        try root.write("edited.txt", "x")
        try await recorder.waitFor(timeout: .seconds(2)) { $0.folders.contains("") }
        #expect(ContinuousClock.now - start < .milliseconds(1500))
    }

    @Test func stoppedOrReleasedWatcherReportsNothingAndIsFreed() async throws {
        let root = try TemporaryFolder()
        let recorder = ChangeRecorder()
        var watcher: FileSystemWatcher? = FileSystemWatcher(root: root.url) { recorder.changes.append($0) }
        weak let weakWatcher = watcher
        try await settle()
        watcher?.stop()
        #expect(watcher?.isWatching == false)
        watcher = nil
        #expect(weakWatcher == nil, "nothing keeps a stopped watcher alive")

        // Released without stop(): the stream is torn down with it.
        var unstopped: FileSystemWatcher? = FileSystemWatcher(root: root.url) { recorder.changes.append($0) }
        weak let weakUnstopped = unstopped
        try await settle()
        unstopped = nil
        #expect(weakUnstopped == nil)

        try root.write("late.txt", "x")
        try await Task.sleep(for: .seconds(1))
        #expect(recorder.changes.isEmpty)
    }

    @Test func eventPathsMapToTheRoot() {
        #expect(FileSystemWatcher.relativePath(of: "/private/tmp/a", root: "/private/tmp/a") == "")
        #expect(FileSystemWatcher.relativePath(of: "/private/tmp/a/b/c/", root: "/private/tmp/a") == "b/c")
        #expect(FileSystemWatcher.relativePath(of: "/private/tmp/A/b", root: "/private/tmp/a") == "b")
        #expect(FileSystemWatcher.relativePath(of: "/private/tmp/ab", root: "/private/tmp/a") == nil)
        #expect(FileSystemWatcher.relativePath(of: "/elsewhere", root: "/private/tmp/a") == nil)

        var change = FileSystemWatcher.Change()
        FileSystemWatcher.record(path: "/private/tmp/a/src", flags: 0, into: &change,
                                 rootPath: "/tmp/a", canonicalRootPath: "/private/tmp/a")
        FileSystemWatcher.record(path: "/tmp/a/lib", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                                 into: &change, rootPath: "/tmp/a", canonicalRootPath: "/private/tmp/a")
        #expect(change.folders == ["src"] && change.subtrees == ["lib"])
        FileSystemWatcher.record(path: "/private/tmp", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged),
                                 into: &change, rootPath: "/tmp/a", canonicalRootPath: "/private/tmp/a")
        #expect(change.subtrees.contains(""), "the root moving or being deleted rescans the whole tree")
    }

    // MARK: File tree

    @Test func treeFollowsCreatesDeletesAndRenamesKeepingNodes() throws {
        let root = try TemporaryFolder()
        try root.write("src/main.swift", "")
        try root.write("README.md", "")
        var expanded: Set<String> = [root.url("src").path]
        let tree = FileTree(directory: root.url) { expanded }
        let src = try #require(tree.roots.first { $0.name == "src" })
        let readme = try #require(tree.roots.first { $0.name == "README.md" })
        _ = src.children

        try root.write("notes.txt", "")
        try root.write("src/util.swift", "")
        let before = tree.revision
        tree.apply(.init(folders: ["", "src"]))
        #expect(tree.revision > before)
        #expect(tree.roots.map(\.name) == ["src", "notes.txt", "README.md"])
        #expect(tree.roots.first { $0.name == "src" } === src, "an unchanged folder keeps its node, so it stays expanded")
        #expect(tree.roots.first { $0.name == "README.md" } === readme)
        #expect(src.loaded?.map(\.name) == ["main.swift", "util.swift"])

        try FileManager.default.moveItem(at: root.url("notes.txt"), to: root.url("todo.txt"))
        try FileManager.default.removeItem(at: root.url("src/main.swift"))
        tree.apply(.init(folders: ["", "src"]))
        #expect(tree.roots.map(\.name) == ["src", "README.md", "todo.txt"])
        #expect(src.loaded?.map(\.name) == ["util.swift"])

        // Nothing changed on disk: no new revision, nothing redrawn.
        let settled = tree.revision
        tree.apply(.init(folders: ["", "src"]))
        #expect(tree.revision == settled)

        // A folder that was read but is folded now is forgotten, then read again when it opens.
        expanded = []
        try root.write("src/later.swift", "")
        tree.apply(.init(folders: ["src"]))
        #expect(src.loaded == nil)
        expanded = [root.url("src").path]
        #expect(src.children?.map(\.name) == ["later.swift", "util.swift"])

        // A whole-tree rescan (events dropped, root moved) re-reads every loaded folder.
        try FileManager.default.removeItem(at: root.url("src/util.swift"))
        try root.write("z.txt", "")
        tree.apply(.init(subtrees: [""]))
        #expect(src.loaded?.map(\.name) == ["later.swift"])
        #expect(tree.roots.contains { $0.name == "z.txt" })
    }

    @Test func treeIgnoresGitNoiseAndFoldersItNeverRead() throws {
        let root = try TemporaryFolder()
        try root.write(".git/HEAD", "ref: refs/heads/main")
        try root.write("node_modules/pkg/index.js", "")
        let tree = FileTree(directory: root.url) { [] }
        #expect(tree.roots.map(\.name) == ["node_modules"], ".git is never listed")
        let nodeModules = try #require(tree.roots.first)

        let before = tree.revision
        try root.write(".git/index.lock", "")
        tree.apply(.init(folders: [".git", ".git/refs/heads"], subtrees: [".git/objects"]))
        try root.write("node_modules/pkg/other.js", "")
        tree.apply(.init(folders: ["node_modules/pkg"]))
        #expect(tree.revision == before)
        #expect(nodeModules.loaded == nil, "a folder never opened is not read because something changed in it")
    }

    @Test func watchedTreeUpdatesLive() async throws {
        let root = try TemporaryFolder()
        try root.write("Screenshot.png", "png")
        let tree = FileTree(directory: root.url) { [] }
        #expect(tree.roots.map(\.name) == ["Screenshot.png"])
        tree.startWatching()
        defer { tree.stopWatching() }
        try await settle()

        try FileManager.default.removeItem(at: root.url("Screenshot.png"))
        try root.write("folder/inside.txt", "")
        try await waitUntil { tree.roots.map(\.name) == ["folder"] }

        tree.stopWatching()
        #expect(!tree.isWatching)
        try root.write("after-stop.txt", "")
        try await Task.sleep(for: .seconds(1))
        #expect(tree.roots.map(\.name) == ["folder"])
    }

    // MARK: Viewer

    @Test func viewerReloadsShowsDeletionAndReloadsWhenTheFileReturns() async throws {
        let root = try TemporaryFolder()
        try root.write("plan.md", "# One")
        let viewer = FileViewerModel(path: root.url("plan.md").path)
        await viewer.start()
        defer { viewer.stop() }
        #expect(viewer.content.text == "# One")
        #expect(viewer.isWatching)
        try await settle()

        try root.write("plan.md", "# Two", atomically: false)
        try await waitUntil { viewer.content.text == "# Two" }

        try FileManager.default.removeItem(at: root.url("plan.md"))
        try await waitUntil { viewer.content.isMissing }

        try root.write("plan.md", "# Three")
        try await waitUntil { viewer.content.text == "# Three" }

        // Moved away is gone as well.
        try FileManager.default.moveItem(at: root.url("plan.md"), to: root.url("moved.md"))
        try await waitUntil { viewer.content.isMissing }
    }

    @Test func atomicSavesReloadWithoutPassingThroughDeleted() async throws {
        let root = try TemporaryFolder()
        try root.write("main.swift", "let a = 1\n")
        let viewer = FileViewerModel(path: root.url("main.swift").path)
        await viewer.start()
        defer { viewer.stop() }
        try await settle()
        var sawMissing = false

        // Write to a temporary file and rename it over the original, as most editors and `write(atomically:)` do.
        try root.write(".main.swift.tmp", "let a = 2\n")
        _ = try FileManager.default.replaceItemAt(root.url("main.swift"), withItemAt: root.url(".main.swift.tmp"))
        try await waitUntil { sawMissing = sawMissing || viewer.content.isMissing; return viewer.content.text == "let a = 2\n" }

        // Delete, then rename the new version in shortly after (another editor strategy).
        try root.write(".main.swift.new", "let a = 3\n")
        try FileManager.default.removeItem(at: root.url("main.swift"))
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.moveItem(at: root.url(".main.swift.new"), to: root.url("main.swift"))
        try await waitUntil { sawMissing = sawMissing || viewer.content.isMissing; return viewer.content.text == "let a = 3\n" }
        #expect(!sawMissing, "a save is a modification, never a deletion")
    }

    @Test func viewerIgnoresChangesToOtherFiles() async throws {
        let root = try TemporaryFolder()
        try root.write("a.md", "A")
        let viewer = FileViewerModel(path: root.url("a.md").path)
        await viewer.start()
        defer { viewer.stop() }
        let revision = viewer.revision
        try await settle()
        try root.write("b.md", "B")
        try root.write("sub/c.md", "C")
        try await Task.sleep(for: .seconds(1))
        #expect(viewer.revision == revision, "the file was not read again")
    }

    @Test func viewerKeepsScrollPositionAndZoomAcrossReloads() async throws {
        let root = try TemporaryFolder()
        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: root.url("data"))
        let context = SessionContext.workspace(UUID())
        let lines = (1...300).map { "Line \($0) of a long file." }
        // Paragraphs in Markdown, lines in code: both much taller than the pane.
        try root.write("long.md", lines.joined(separator: "\n\n"))
        try root.write("long.swift", lines.map { "// \($0)" }.joined(separator: "\n"))
        try writePNG(root.url("shot.png"), width: 2400, height: 1600)

        for name in ["long.md", "long.swift"] {
            let (window, host) = show(FileViewer(path: root.url(name).path, context: context).environment(model))
            defer { window.orderOut(nil) }
            let scrollView = try await scrollable(in: host)
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: 1500))
            scrollView.reflectScrolledClipView(clip)
            let before = clip.bounds.origin.y
            #expect(before > 1000, "\(name) scrolled")

            let separator = name.hasSuffix(".md") ? "\n\n" : "\n"
            try root.write(name, (["Edited first line."] + lines.dropFirst()).joined(separator: separator), atomically: true)
            try await Task.sleep(for: .milliseconds(1500))
            if let text = scrollView.documentView as? NSTextView { #expect(text.string.hasPrefix("Edited"), "the code reloaded") }
            #expect(abs(clip.bounds.origin.y - before) < 2, "\(name) kept its scroll position: \(before) → \(clip.bounds.origin.y)")
        }

        let (window, host) = show(FileViewer(path: root.url("shot.png").path, context: context).environment(model))
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(800))
        let imageScroll = try #require(scrollViews(in: host).first { $0.allowsMagnification })
        #expect(imageScroll.magnification < 1, "a large image opens fitted")
        // A fitted image is fitted again when it changes size.
        try writePNG(root.url("shot.png"), width: 1200, height: 800)
        try await Task.sleep(for: .milliseconds(1500))
        let fitted = imageScroll.magnification
        #expect(((imageScroll.documentView as? NSImageView)?.image?.size.width ?? 0) == 1200)
        // A zoom the user chose survives the next write.
        imageScroll.magnification = 2
        try writePNG(root.url("shot.png"), width: 1200, height: 800, red: 1)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(abs(imageScroll.magnification - 2) < 0.001, "zoom kept: \(imageScroll.magnification), fitted was \(fitted)")
    }

    // MARK: Helpers

    private func show(_ view: some View) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        return (window, host)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// The scroll view showing the file, once its content is taller than the pane.
    private func scrollable(in host: NSView) async throws -> NSScrollView {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let found = scrollViews(in: host).first(where: { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 1000 }) {
                return found
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }

    private func writePNG(_ url: URL, width: Int, height: Int, red: CGFloat = 0) throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: red, green: 0.4, blue: 0.8, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(rep.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }

    /// Lets a new FSEvents stream start before the test changes files.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class ChangeRecorder {
    var changes: [FileSystemWatcher.Change] = []

    /// Waits for a delivered change matching `predicate`, then forgets what was recorded.
    func waitFor(timeout: Duration = .seconds(3), _ predicate: (FileSystemWatcher.Change) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !changes.contains(where: predicate) {
            guard ContinuousClock.now < deadline else {
                Issue.record("no matching change in \(changes)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        changes.removeAll()
    }
}

/// A temporary folder removed when the test ends.
private final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func url(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    func write(_ relative: String, _ text: String, atomically: Bool = true) throws {
        let file = url(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: atomically, encoding: .utf8)
    }
}

private extension FileViewer.Content {
    var text: String? {
        switch self {
        case .markdown(let text), .text(let text), .code(let text, _): text
        default: nil
        }
    }

    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}
