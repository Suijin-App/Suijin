import Foundation
import Testing
@testable import SuijinTerminal

@Suite("Shell agent markers")
@MainActor
struct ShellAgentMarkerTests {
    @Test("payloads parse into starts and ends; anything else is ignored")
    func parsing() {
        #expect(ShellAgentMarker.parse(Array("start;claude".utf8)) == .started(agent: "claude"))
        #expect(ShellAgentMarker.parse(Array("end;codex;0".utf8)) == .ended(agent: "codex", status: 0))
        #expect(ShellAgentMarker.parse(Array("end;claude;130".utf8)) == .ended(agent: "claude", status: 130))
        #expect(ShellAgentMarker.parse(Array("end;claude;".utf8)) == .ended(agent: "claude", status: nil))
        #expect(ShellAgentMarker.parse(Array("end;claude".utf8)) == .ended(agent: "claude", status: nil))
        for bad in ["", "start", "start;", "start;Claude", "start;claude;extra", "stop;claude", "end;claude;1;2",
                    "start;\(String(repeating: "a", count: 40))", "start;cl aude", "start;../x"] {
            #expect(ShellAgentMarker.parse(Array(bad.utf8)) == nil, "\(bad)")
        }
        #expect(ShellAgentMarker.parse([0xff, 0xfe]) == nil)
    }

    @Test("the view reports markers in its output, in order, and shows none of them")
    func viewReportsMarkers() {
        let view = SuijinTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        var markers: [ShellAgentMarker] = []
        view.onShellAgentMarker { markers.append($0) }
        view.feed(text: "before\u{1b}]6973;start;claude\u{07}during\u{1b}]6973;bogus\u{07}\u{1b}]6973;end;claude;3\u{1b}\\after")
        #expect(markers == [.started(agent: "claude"), .ended(agent: "claude", status: 3)])
        #expect(view.visibleText().contains("beforeduringafter"))
    }

    // MARK: Shell functions

    /// A fake `claude` (and `codex`) that prints its arguments and the hook variables, then exits with `$FAKE_EXIT`, or
    /// waits to be interrupted when it is `wait`.
    private func installFakeAgents(in fixture: ShellFixture) throws {
        for name in ["claude", "codex"] {
            let url = fixture.fakeBin.appending(path: name)
            try Data("""
                #!/bin/sh
                printf '\(name)-args=%s\\n' "$*"
                printf '\(name)-events=%s\\n' "${SUIJIN_HOOK_EVENTS-<unset>}"
                if [ "${FAKE_EXIT:-0}" = wait ]; then printf 'FAKE READY\\n'; while :; do sleep 0.1; done; fi
                exit "${FAKE_EXIT:-0}"

                """.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// An interactive Suijin shell in a real PTY; returns its engine and the recorder of everything it wrote.
    private func startShell(_ shell: String, fixture: ShellFixture, environment: [String: String] = [:]) async throws
        -> (SwiftTermEngine, EngineRecorder) {
        try installFakeAgents(in: fixture)
        let rcFile = shell.hasSuffix("zsh") ? ".zshrc" : ".bash_profile"
        try fixture.write(fixture.pathLine + "PS1='PROMPT> '\n", to: rcFile)
        let launch = ShellLaunch.interactiveShell(shell, cwd: fixture.home, environment: fixture.environment(environment))
        let engine = SwiftTermEngine()
        let recorder = EngineRecorder()
        recorder.attach(to: engine)
        try await engine.start(launch, size: TerminalSize(cols: 200, rows: 40))
        #expect(await waitUntil(timeout: .seconds(15)) { recorder.text.contains("PROMPT> ") }, "\(recorder.text.debugDescription)")
        return (engine, recorder)
    }

    private func markers(in text: String) -> [ShellAgentMarker] {
        text.components(separatedBy: "\u{1b}]6973;").dropFirst().compactMap { part in
            part.split(separator: "\u{07}", maxSplits: 1, omittingEmptySubsequences: false).first
                .flatMap { ShellAgentMarker.parse(Array($0.utf8)) }
        }
    }

    private func finish(_ engine: SwiftTermEngine, _ recorder: EngineRecorder) async {
        engine.write(ArraySlice("exit\n".utf8))
        _ = await waitUntil(timeout: .seconds(10)) { !recorder.exits.isEmpty }
        await engine.terminate()
    }

    @Test("claude and codex announce their start and end with the exit status", arguments: ["/bin/zsh", "/bin/bash"])
    func announcesRuns(shell: String) async throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let (engine, recorder) = try await startShell(shell, fixture: fixture)
        engine.write(ArraySlice("claude --version; FAKE_EXIT=7 codex; echo DONE-$?\n".utf8))
        #expect(await waitUntil(timeout: .seconds(10)) { recorder.text.contains("DONE-7") }, "\(recorder.text.debugDescription)")
        #expect(await waitUntil { markers(in: recorder.text).count == 4 })
        #expect(markers(in: recorder.text) == [.started(agent: "claude"), .ended(agent: "claude", status: 0),
                                               .started(agent: "codex"), .ended(agent: "codex", status: 7)])
        #expect(recorder.text.contains("claude-args=--version\r\n"))
        await finish(engine, recorder)
    }

    @Test("Ctrl-C still ends the run", arguments: ["/bin/zsh", "/bin/bash"])
    func interruptedRunEnds(shell: String) async throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let (engine, recorder) = try await startShell(shell, fixture: fixture, environment: ["FAKE_EXIT": "wait"])
        engine.write(ArraySlice("claude\n".utf8))
        #expect(await waitUntil(timeout: .seconds(10)) { recorder.text.contains("FAKE READY") })
        #expect(markers(in: recorder.text) == [.started(agent: "claude")])
        engine.write([0x03])
        #expect(await waitUntil(timeout: .seconds(10)) { markers(in: recorder.text).count == 2 }, "\(recorder.text.debugDescription)")
        guard case .ended(let agent, let status) = markers(in: recorder.text).last else {
            Issue.record("no end marker")
            return
        }
        #expect(agent == "claude")
        #expect(status != 0)
        // The next prompt does not report the same end again.
        engine.write(ArraySlice("echo again\n".utf8))
        #expect(await waitUntil { recorder.text.components(separatedBy: "PROMPT> ").count >= 4 })
        #expect(markers(in: recorder.text).count == 2)
        await finish(engine, recorder)
    }

    @Test("claude gets Suijin's hooks settings; a redirected stdout carries no marker", arguments: ["/bin/zsh", "/bin/bash"])
    func hooksAndRedirection(shell: String) async throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let settings = fixture.dataRoot.appending(path: "hooks/claude-settings.json")
        try fixture.write("{}", to: "hooks/claude-settings.json", in: fixture.dataRoot)
        let events = fixture.dataRoot.appending(path: "hooks/events/x.jsonl").path
        let (engine, recorder) = try await startShell(shell, fixture: fixture, environment: [
            "SUIJIN_CLAUDE_SETTINGS": settings.path, "SUIJIN_HOOK_EVENTS": events,
        ])
        let output = fixture.base.appending(path: "out.txt")
        engine.write(ArraySlice("claude -p hi > '\(output.path)'; cat '\(output.path)'; echo DONE\n".utf8))
        #expect(await waitUntil(timeout: .seconds(10)) { recorder.text.contains("DONE\r\n") }, "\(recorder.text.debugDescription)")
        let file = try String(contentsOf: output, encoding: .utf8)
        #expect(!file.contains("\u{1b}"))
        #expect(file.value(of: "claude-args") == "--settings \(settings.path) -p hi")
        #expect(file.value(of: "claude-events") == events)
        #expect(markers(in: recorder.text) == [.started(agent: "claude"), .ended(agent: "claude", status: 0)])
        await finish(engine, recorder)
    }
}
