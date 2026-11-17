import AppKit
import Foundation
import SuijinCore
import SuijinTerminal
import SwiftUI
import Testing
@testable import Suijin

/// Dropping files on the terminals of a split tab, in the real view hierarchy with real shells: the drag is routed to
/// the pane's terminal the way AppKit routes it (the deepest view under the pointer registered for the dragged type),
/// pasted as Terminal.app pastes it, and the pane takes the keyboard. Ended panes, pane drags and tab drags never
/// reach a terminal. With `SUIJIN_SCREENSHOTS` set, the drop highlight and the result are rendered there.
@MainActor
@Suite(.endsHostedSessions, .serialized, .timeLimit(.minutes(2)))
struct TerminalFileDropTests {
    let root: URL
    let folder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-drop-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// The view AppKit would ask about a drag of `types` at `point` (window coordinates): the deepest view under it
    /// registered for one of the types.
    private func destination(in window: NSWindow, at point: NSPoint, for types: [NSPasteboard.PasteboardType]) -> NSView? {
        guard let content = window.contentView,
              var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else { return nil }
        while true {
            if !Set(view.registeredDraggedTypes).isDisjoint(with: types) { return view }
            guard let parent = view.superview else { return nil }
            view = parent
        }
    }

    private func center(of view: NSView) -> NSPoint {
        view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    /// The terminal's recent lines (wrapped rows joined), composed (NFC): a file name may come back from the pasteboard
    /// decomposed, and the screen keeps a letter and its accent in one cell either way.
    private func screen(_ view: SuijinTerminalView) -> String {
        view.recentText(lineCount: 10).precomposedStringWithCanonicalMapping
    }

    private func snapshot(_ host: NSView, _ name: String, dark: Bool) throws {
        guard let folder = ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] else { return }
        let output = URL(fileURLWithPath: folder)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    @Test("pasted images of a data root that is not the user's own are saved under that root")
    func pastedImagesStayInAnIsolatedDataRoot() throws {
        let dataRoot = root.appendingPathComponent("data")
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: dataRoot)
        #expect(model.pastedImageStore.directory == dataRoot.appendingPathComponent("PastedImages", isDirectory: true))
    }

    @Test(arguments: [false, true])
    func filesDroppedOnAPaneArePastedAsPaths(dark: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        model.setSetting(.terminalGPURendering, "false")
        await model.addWorkspace(at: folder)
        let workspaceID = try #require(model.workspaces.first).id
        let context = SessionContext.workspace(workspaceID)
        model.selection = context
        await model.runtimes.bootstrap()
        // [ended | plain shell | shell with bracketed paste on]
        let ended = AgentSessionRecord(workspaceID: workspaceID, worktreeID: nil, agent: .shell, accountID: nil,
                                       title: "ended", cwd: folder.path, state: .exited)
        await model.upsert(ended)
        let plain = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
        let bracketed = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
        defer { Task { await model.closeSessions([plain, bracketed]) } }
        try model.insertPane(plain, beside: ended.id, edge: .right)
        try model.insertPane(bracketed, beside: plain, edge: .right)
        let plainView = try #require(model.runtimes.runtime(for: plain)).terminal.view
        let bracketedView = try #require(model.runtimes.runtime(for: bracketed)).terminal.view

        let window = OffscreenWindow(contentRect: CGRect(x: 0, y: 0, width: 1500, height: 460), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: SessionTabsView(context: context).environment(model))
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        #expect(await eventually { plainView.window === window && bracketedView.window === window })

        // `cat` stores exactly the bytes the program receives; the terminal's echo shows them, escapes as `^[`.
        let plainOutput = root.appendingPathComponent("plain.bin"), bracketedOutput = root.appendingPathComponent("bracketed.bin")
        for (id, command) in [(plain, "clear; echo RE''ADY; cat > '\(plainOutput.path)'\r"),
                              (bracketed, "clear; printf '\\e[?2004h'; echo RE''ADY; cat > '\(bracketedOutput.path)'\r")] {
            let view = try #require(model.runtimes.runtime(for: id)).terminal.view
            #expect(await eventually { !view.visibleText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            model.runtimes.runtime(for: id)?.terminal.engine.write(Array(command.utf8)[...])
            #expect(await eventually { view.visibleText().split(separator: "\n").contains { $0 == "READY" } })
        }
        #expect(await eventually { !plainView.isBracketedPasteMode && bracketedView.isBracketedPasteMode })

        let image = folder.appendingPathComponent("Ảnh chụp (1).png")
        let notes = folder.appendingPathComponent("it's $notes.md")
        try Data().write(to: image)
        try Data().write(to: notes)
        let files = NSPasteboard(name: NSPasteboard.Name("suijin.test.drop.\(UUID().uuidString)"))
        files.clearContents()
        files.writeObjects([image as NSURL, notes as NSURL])
        #expect(TerminalFileDrop.text(for: [image, notes]) == "\(folder.path)/Ảnh\\ chụp\\ \\(1\\).png \(folder.path)/it\\'s\\ \\$notes.md")
        // File URLs come back from a pasteboard with their names decomposed (NFD), as the file system spells them;
        // the paste keeps them that way, byte for byte.
        let dropped = try #require(files.readObjects(forClasses: [NSURL.self]) as? [URL])
        let pasted = TerminalFileDrop.text(for: dropped)
        #expect(pasted.precomposedStringWithCanonicalMapping
                == TerminalFileDrop.text(for: [image, notes]).precomposedStringWithCanonicalMapping)

        // AppKit routes file drags to the terminal under the pointer, and pane or tab drags past it.
        let target = center(of: bracketedView)
        #expect(destination(in: window, at: target, for: [.fileURL]) === bracketedView)
        #expect(!(destination(in: window, at: target, for: [.suijinPane]) is SuijinTerminalView))
        #expect(!(destination(in: window, at: target, for: [.string]) is SuijinTerminalView))
        // The ended pane has no terminal to take it.
        let endedPoint = NSPoint(x: center(of: plainView).x - (target.x - center(of: plainView).x), y: target.y)
        #expect(!(destination(in: window, at: endedPoint, for: [.fileURL]) is SuijinTerminalView))

        // Hovering shows the copy cursor and the ring; the drop pastes with paste markers and focuses the pane.
        let drag = FakeDrag(pasteboard: files, window: window, location: target)
        #expect(bracketedView.draggingEntered(drag) == .copy)
        try snapshot(host, "terminal-file-drop-hover", dark: dark)
        #expect(bracketedView.prepareForDragOperation(drag))
        #expect(bracketedView.performDragOperation(drag))
        bracketedView.draggingEnded(drag)
        #expect(await eventually { screen(bracketedView).contains("^[[200~/") && screen(bracketedView).contains("notes.md^[[201~") })
        #expect(await eventually { window.firstResponder === bracketedView })
        #expect(await eventually { model.activeSession(in: context) == bracketed })

        // Without bracketed paste: the same paths, no markers. Neither drop pressed Return: `cat` printed nothing yet.
        let plainDrag = FakeDrag(pasteboard: files, window: window, location: center(of: plainView))
        #expect(plainView.draggingEntered(plainDrag) == .copy)
        #expect(plainView.performDragOperation(plainDrag))
        plainView.draggingEnded(plainDrag)
        #expect(await eventually { screen(plainView).contains("$notes.md") })
        #expect(!screen(plainView).contains("^["))
        #expect(await eventually { model.activeSession(in: context) == plain })
        try snapshot(host, "terminal-file-drop-result", dark: dark)

        // Neither drop pressed Return: `cat` got no line yet. Return and ^D hand it over and end `cat`.
        try await Task.sleep(for: .milliseconds(300))
        for output in [plainOutput, bracketedOutput] {
            #expect((try? Data(contentsOf: output))?.isEmpty == true)
        }
        for id in [plain, bracketed] { model.runtimes.runtime(for: id)?.terminal.engine.write(Array("\r\u{4}".utf8)[...]) }
        let expected = [(plainOutput, TerminalFileDrop.bytes(for: pasted, bracketedPaste: false) + [0x0A]),
                        (bracketedOutput, TerminalFileDrop.bytes(for: pasted, bracketedPaste: true) + [0x0A])]
        for (output, bytes) in expected {
            #expect(await eventually { (try? Data(contentsOf: output)).map(Array.init) == bytes })
        }
        #expect(Array(try Data(contentsOf: bracketedOutput)).starts(with: Array("\u{1B}[200~".utf8)))

        // A pane drag over a terminal is refused and types nothing.
        let pane = NSPasteboard(name: NSPasteboard.Name("suijin.test.pane.\(UUID().uuidString)"))
        pane.declareTypes([.suijinPane], owner: nil)
        pane.setString(plain.uuidString, forType: .suijinPane)
        // Once the shell's prompt after `cat` has settled.
        try await Task.sleep(for: .milliseconds(500))
        let before = bracketedView.recentText(lineCount: 10)
        let paneDrag = FakeDrag(pasteboard: pane, window: window, location: target)
        #expect(bracketedView.draggingEntered(paneDrag) == [])
        #expect(!bracketedView.performDragOperation(paneDrag))
        try await Task.sleep(for: .milliseconds(300))
        #expect(bracketedView.recentText(lineCount: 10) == before)
    }

    @Test func fileTreeRowsDragTheirFileURLOnly() throws {
        let url = URL(fileURLWithPath: "/tmp/a b/../c.png")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("suijin.test.tree.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([FileOutlineController.pasteboardWriter(for: url)]))
        let types = try #require(pasteboard.pasteboardItems?.first?.types)
        #expect(types == [.fileURL])
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.map(\.path) == ["/tmp/c.png"])
    }
}

/// A drag in progress, for calling a drop destination directly. Offers every operation, as the Finder does. AppKit's
/// protocol predates Swift concurrency; the tests use it on the main thread only.
@MainActor
private final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let window: NSWindow
    let draggingLocation: NSPoint

    init(pasteboard: NSPasteboard, window: NSWindow, location: NSPoint) {
        draggingPasteboard = pasteboard
        self.window = window
        draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic, .move] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
