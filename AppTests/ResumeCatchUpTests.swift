import AppKit
import Foundation
import SuijinCore
import SuijinTerminal
import SwiftUI
import Testing
@testable import Suijin

/// Resume Session reopens a conversation, and the agent prints all of it again as it starts. The pane shows "Resuming
/// session…" over a hidden terminal until that output settles, then the terminal already at its end: no scrolling
/// through the history, and nothing typed meanwhile is lost. A script stands in for the agent.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ResumeCatchUpTests {
    @Test func aResumedSessionShowsAtItsEndWithoutScrolling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-resume-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Re-prints a long conversation at once, as `claude --resume` does, then waits for the user.
        let script = root.appendingPathComponent("resumed-agent.sh")
        try """
        #!/bin/sh
        seq -f 'conversation line %g' 1 4000
        printf 'HISTORY END\\n'
        IFS= read -r line
        printf 'GOT:%s\\n' "$line"
        while :; do sleep 1; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspace = try #require(model.workspaces.first)
        let context = SessionContext.workspace(workspace.id)
        model.selection = context
        await model.runtimes.bootstrap()
        var record = AgentSessionRecord(workspaceID: workspace.id, agent: .claude, title: "Claude", cwd: folder.path)
        record.state = .exited
        record.endedAt = Date()
        await model.upsert(record)
        model.selectedTab[context] = .session(record.id)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SessionTabsView(context: context).environment(model))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let states = StateRecorder { model.paneState(of: record.id) }
        let launch = ShellLaunch.command(script.path, [], cwd: folder, environment: [:], interactive: false)
        try await model.runtimes.relaunch(record, launch: launch, catchUp: true)
        let terminal = try #require(model.runtimes.runtime(for: record.id)).terminal
        // Typed while the history prints: it waits in the terminal for the agent to read it.
        terminal.view.send(txt: "typed meanwhile\r")

        // Watch until the terminal shows: it stays invisible until the whole history is on it.
        var shownEarly = false
        let start = ContinuousClock.now
        while model.paneState(of: record.id) != .terminal, ContinuousClock.now - start < .seconds(5) {
            if terminal.view.alphaValue != 0 { shownEarly = true }
            try await Task.sleep(for: .milliseconds(5))
        }
        let revealedAfter = ContinuousClock.now - start
        #expect(!shownEarly, "the terminal showed while the history was still printing")
        #expect(model.paneState(of: record.id) == .terminal)
        #expect(revealedAfter < .seconds(3) + .milliseconds(500))
        // Shown at the end: the last line of the history is on screen, the first is not, and the view sits at the
        // bottom of its scrollback.
        let screen = terminal.view.visibleText()
        #expect(screen.contains("HISTORY END"))
        #expect(!screen.contains("conversation line 1\n"))
        #expect(terminal.view.window === window && terminal.view.alphaValue == 1)
        #expect(terminal.view.scrollPosition >= 0.999)
        #expect(await waitUntil { terminal.view.visibleText().contains("GOT:typed meanwhile") })
        // The recorder reads each change back on a later main-actor turn.
        try await Task.sleep(for: .milliseconds(50))
        #expect(states.values == [.ended, .resuming, .terminal])

        for session in model.sessions { await model.closeSession(session.id) }
    }

    /// Renders the resuming pane for review, narrow and wide, light and dark, then runs a resume with and without the
    /// catch-up for comparison. Opt-in with `TEST_RUNNER_SUIJIN_RESUME_SHOT=<file>`: at each step the file receives
    /// `<name> <window number>` and the window stays up while the caller captures it with `screencapture -l`. The
    /// window is ordered in without activating the app.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUIJIN_RESUME_SHOT"] != nil))
    func resumingScreens() async throws {
        let output = ProcessInfo.processInfo.environment["SUIJIN_RESUME_SHOT"] ?? ""
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-resume-shots-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("resumed-agent.sh")
        try """
        #!/bin/sh
        [ "$1" = quiet ] || seq -f 'conversation line %g of the resumed session' 1 4000
        printf 'HISTORY END\\n> '
        while :; do sleep 1; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspace = try #require(model.workspaces.first)
        let context = SessionContext.workspace(workspace.id)
        model.selection = context
        await model.runtimes.bootstrap()

        func endedRecord() async -> AgentSessionRecord {
            for session in model.sessions { await model.closeSession(session.id) }
            var record = AgentSessionRecord(workspaceID: workspace.id, agent: .claude, title: "Claude", cwd: folder.path)
            record.state = .exited
            record.endedAt = Date()
            await model.upsert(record)
            model.selectedTab[context] = .session(record.id)
            return record
        }
        func window(_ size: CGSize, dark: Bool) -> NSWindow {
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 40, y: 40), size: size), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = NSHostingView(rootView: SessionTabsView(context: context).environment(model))
            window.orderFrontRegardless()
            return window
        }

        // The resuming pane itself: an agent that prints nothing, held in its catch-up long enough to look at.
        for dark in [false, true] {
            for width in [900.0, 1400.0] {
                let record = await endedRecord()
                let shown = window(CGSize(width: width, height: 640), dark: dark)
                let launch = ShellLaunch.command(script.path, ["quiet"], cwd: folder, environment: [:], interactive: false)
                try await model.runtimes.relaunch(record, launch: launch, catchUp: true)
                model.runtimes.runtime(for: record.id)?.terminal.catchUp(quiet: .seconds(60), quietBeforeScreenful: .seconds(60),
                                                                         limit: .seconds(60))
                try await Task.sleep(for: .milliseconds(900))
                try "resuming-\(Int(width))-\(dark ? "dark" : "light") \(shown.windowNumber)"
                    .write(toFile: output, atomically: true, encoding: .utf8)
                try await Task.sleep(for: .milliseconds(1_800))
                shown.orderOut(nil)
            }
        }
        // A whole resume, with the catch-up and without it (as before), for a frame sequence. Drawn with CoreGraphics:
        // the Metal surface of a window of an app in the background does not show in captures.
        model.setSetting(.terminalGPURendering, "false")
        for catchUp in [true, false] {
            let record = await endedRecord()
            let shown = window(CGSize(width: 1000, height: 640), dark: false)
            try "flow-\(catchUp ? "catchup" : "plain") \(shown.windowNumber)".write(toFile: output, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(1_200))
            let launch = ShellLaunch.command(script.path, [], cwd: folder, environment: [:], interactive: false)
            try await model.runtimes.relaunch(record, launch: launch, catchUp: catchUp)
            try await Task.sleep(for: .seconds(3))
            shown.orderOut(nil)
        }
        try "done 0".write(toFile: output, atomically: true, encoding: .utf8)
        for session in model.sessions { await model.closeSession(session.id) }
    }

    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }
}
