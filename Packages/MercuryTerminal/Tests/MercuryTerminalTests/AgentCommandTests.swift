import Darwin
import Foundation
import Testing
@testable import MercuryTerminal

/// `ShellLaunch.command` must see the PATH users set in .zshrc / .bashrc-style files (nvm and friends): an
/// npm-installed agent is a `#!/usr/bin/env node` script, so both the agent and `node` come from that PATH.
@Suite("Agent command launch")
@MainActor
struct AgentCommandTests {
    /// A fake `node` and an agent script using it, in a directory only the user's rc file puts on PATH.
    private func installFakeNode(in fixture: ShellFixture) throws -> URL {
        let directory = fixture.base.appending(path: "nvm bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let node = directory.appending(path: "fakenode")
        try Data("""
            #!/bin/sh
            printf 'node-ok pid=%s script=%s arg=%s mode=%s secret=%s\\n' "$$" "${1##*/}" "$2" "${AGENT_MODE-<unset>}" "${AGENT_SECRET-<unset>}"

            """.utf8).write(to: node)
        let agent = directory.appending(path: "fakeagent")
        try Data("#!/usr/bin/env fakenode\n".utf8).write(to: agent)
        for url in [node, agent] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return directory
    }

    private func run(shell: String, fixture: ShellFixture) async throws -> (String, pid_t?) {
        // As the app launches an agent: an env patch through /usr/bin/env, the binary by name.
        let launch = ShellLaunch.command("/usr/bin/env", ["-u", "AGENT_SECRET", "AGENT_MODE=patched", "fakeagent", "one arg"],
                                         shell: shell, cwd: fixture.home,
                                         environment: fixture.environment(["AGENT_SECRET": "leak", "AGENT_MODE": "inherited"]))
        let engine = SwiftTermEngine()
        let recorder = EngineRecorder()
        recorder.attach(to: engine)
        try await engine.start(launch, size: TerminalSize(cols: 200, rows: 24))
        let exited = await waitUntil(timeout: .seconds(15)) { !recorder.exits.isEmpty }
        #expect(exited)
        #expect(recorder.exits == [0], "\(recorder.text.debugDescription)")
        return (recorder.text, engine.processID)
    }

    @Test("zsh: PATH from .zshrc reaches the agent, the env patch wins, exec keeps the PTY's process")
    func zsh() async throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let nvm = try installFakeNode(in: fixture)
        try fixture.write("export PATH=\"\(nvm.path):$PATH\"\nexport AGENT_MODE=fromrc\n", to: ".zshrc")
        let (text, pid) = try await run(shell: "/bin/zsh", fixture: fixture)
        let line = try #require(text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("node-ok") }, "\(text.debugDescription)")
        #expect(line.contains("script=fakeagent arg=one arg mode=patched secret=<unset>"))
        #expect(line.contains("pid=\(try #require(pid))"))
    }

    @Test("bash: PATH from .bash_profile reaches the agent")
    func bash() async throws {
        let fixture = try ShellFixture()
        defer { fixture.remove() }
        let nvm = try installFakeNode(in: fixture)
        try fixture.write("export PATH=\"\(nvm.path):$PATH\"\n", to: ".bash_profile")
        let (text, pid) = try await run(shell: "/bin/bash", fixture: fixture)
        let line = try #require(text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("node-ok") }, "\(text.debugDescription)")
        #expect(line.contains("script=fakeagent arg=one arg mode=patched secret=<unset>"))
        #expect(line.contains("pid=\(try #require(pid))"))
    }

    @Test("argument shape per shell")
    func arguments() {
        let env = ["MERCURY_DATA_ROOT": FileManager.default.temporaryDirectory.appending(path: "mercury-args-\(UUID())").path]
        let cwd = URL(fileURLWithPath: "/tmp")
        let zsh = ShellLaunch.command("/bin/echo", ["x"], shell: "/bin/zsh", cwd: cwd, environment: env)
        #expect(zsh.arguments == ["-l", "-i", "-c", #"exec "$0" "$@""#, "/bin/echo", "x"])
        let bash = ShellLaunch.command("/bin/echo", ["x"], shell: "/bin/bash", cwd: cwd, environment: env)
        #expect(bash.arguments.first == "--rcfile")
        #expect(bash.arguments.suffix(5) == ["-i", "-c", #"exec "$0" "$@""#, "/bin/echo", "x"])
        let noRoot = ShellLaunch.command("/bin/echo", ["x"], shell: "/bin/bash", cwd: cwd, environment: [:])
        #expect(noRoot.arguments.prefix(3) == ["-l", "-i", "-c"])
        let tcsh = ShellLaunch.command("/bin/echo", ["x"], shell: "/bin/tcsh", cwd: cwd, environment: env)
        #expect(tcsh.executable == ShellLaunch.fallbackShell)
        #expect(tcsh.environment["SHELL"] == "/bin/tcsh")
        let fish = ShellLaunch.command("/bin/echo", ["x"], shell: "/opt/homebrew/bin/fish", cwd: cwd, environment: env)
        #expect(fish.arguments == ["-l", "-c", "exec $argv", "/bin/echo", "x"])
    }
}
