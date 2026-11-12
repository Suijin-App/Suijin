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
}
