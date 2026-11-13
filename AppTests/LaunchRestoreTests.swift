import AppKit
import Foundation
import Observation
import SuijinCore
import SuijinPTYProtocol
import SuijinTerminal
import Testing
@testable import Suijin

/// Records every distinct value of `read` the window would draw: each change is read back on the main actor after the
/// work that made it (as SwiftUI renders once that work yields), so a state that is replaced within the same turn is
/// never drawn and never recorded, and one that lasts across a suspension is.
@MainActor
final class StateRecorder<Value: Equatable> {
    private(set) var values: [Value] = []
    private let read: @MainActor () -> Value

    init(_ read: @escaping @MainActor () -> Value) {
        self.read = read
        record()
    }

    private func record() {
        let value = withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in self?.record() }
        }
        if values.last != value { values.append(value) }
    }
}

/// Launch after a quit that left sessions behind: the window opens straight into the restored context and tab, and a
/// session whose process is gone shows the ended view without a terminal or a spinner first.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct LaunchRestoreTests {
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return await condition()
    }

    @Test func aRelaunchOpensStraightIntoTheRestoredState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-launch-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Stands in for an agent: prints, then exits once `release` exists, with the code and the hint given.
        let script = root.appendingPathComponent("agent.sh")
        try """
        #!/bin/sh
        printf 'AGENT STARTED\\n'
        while [ ! -f "$1" ]; do sleep 0.05; done
        printf "$2\\n"
        exit "$3"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let codexID = "019a5f3e-8c2b-7d41-a9e0-3b6c1d2e4f50"

        // First run: a session that ends while the app is open, and one still running when the app quits.
        let database = SuijinPaths.database(in: dataRoot)
        let first = AppModel(store: try SuijinStore(url: database), dataRoot: dataRoot)
        await first.addWorkspace(at: folder)
        let workspace = try #require(first.workspaces.first)
        let context = SessionContext.workspace(workspace.id)
        await first.runtimes.bootstrap()
        #expect(first.runtimes.hostProblem == nil)

        func launch(_ release: URL, _ text: String, _ code: Int32) -> TerminalLaunch {
            ShellLaunch.command(script.path, [release.path, text, String(code)], cwd: folder, environment: [:], interactive: false)
        }
        let endedRelease = root.appendingPathComponent("release-ended")
        let ended = AgentSessionRecord(workspaceID: workspace.id, agent: .shell, title: "Ended", cwd: folder.path)
        try await first.runtimes.run(ended, launch: launch(endedRelease, "bye", 0))
        let awayRelease = root.appendingPathComponent("release-away")
        let away = AgentSessionRecord(workspaceID: workspace.id, agent: .codex, title: "Away", cwd: folder.path)
        try await first.runtimes.run(away, launch: launch(awayRelease, "fatal: lost the account\\nTo continue this session, run codex resume \(codexID)", 3))
        first.selection = context
        first.selectedTab[context] = .session(ended.id)
        #expect(await eventually { first.runtimes.runtime(for: ended.id)?.terminal.view.visibleText().contains("AGENT STARTED") == true })

        FileManager.default.createFile(atPath: endedRelease.path, contents: nil)
        #expect(await eventually { first.runtimes.runtime(for: ended.id) == nil })
        #expect(first.sessions.first { $0.id == ended.id }?.state == .exited)
        let endedHost = try #require(first.sessions.first { $0.id == ended.id }?.hostSessionID)
        let awayHost = try #require(first.sessions.first { $0.id == away.id }?.hostSessionID)
        // The host keeps the ended session (and its scrollback) after the app let it go.
        #expect(try await PTYHostClient.shared.listSessions().contains { $0.id == endedHost && !$0.isRunning })

        // Quit with sessions kept, then the second agent exits while the app is closed.
        await first.runtimes.prepareForQuit()
        FileManager.default.createFile(atPath: awayRelease.path, contents: nil)
        #expect(await eventually { (try? await PTYHostClient.shared.listSessions())?.contains { $0.id == awayHost && !$0.isRunning } == true })
        #expect(await eventually { (try? first.store.setting(SettingKey.lastSelection.rawValue)) == context.storageValue })

        // Relaunch, as `SuijinApp` does, recording what the detail column and each session's place show throughout.
        let second = AppModel(store: try SuijinStore(url: database), dataRoot: dataRoot)
        let detail = StateRecorder { second.detailState }
        let endedPane = StateRecorder { second.paneState(of: ended.id) }
        let awayPane = StateRecorder { second.paneState(of: away.id) }
        await second.loadSettings()
        await second.load()
        // The restored context and tab are in place before the sessions attach.
        #expect(second.detailState == .context(context))
        #expect(second.paneState(of: ended.id) == .ended)
        await second.runtimes.bootstrap()
        #expect(await eventually { second.paneState(of: away.id) == .ended })
        try await Task.sleep(for: .milliseconds(300))

        // One transition from the blank column to the restored context: no "Add your first workspace", no "No
        // Workspace Selected" in between.
        #expect(detail.values == [.loading, .context(context)])
        // The session that had ended shows the ended view from the first frame it has, never a terminal or a spinner.
        #expect(endedPane.values == [.missing, .ended])
        // The one that exited while the app was closed waits while launch finds out, then ends once, without its
        // dead terminal ever showing.
        #expect(awayPane.values == [.missing, .reconnecting, .ended])
        #expect(second.runtimes.runtime(for: ended.id) == nil && second.runtimes.runtime(for: away.id) == nil)

        // What the ended view needs still comes from the scrollback of the session that exited while away.
        let awayRecord = try #require(second.sessions.first { $0.id == away.id })
        #expect(awayRecord.state == .failed && awayRecord.exitCode == 3)
        #expect(second.runtimes.endedOutput[away.id]?.contains("fatal: lost the account") == true)
        #expect(awayRecord.agentSessionID == codexID)
        #expect(second.sessions.first { $0.id == ended.id }?.state == .exited)

        for session in second.sessions { await second.closeSession(session.id) }
    }
}
