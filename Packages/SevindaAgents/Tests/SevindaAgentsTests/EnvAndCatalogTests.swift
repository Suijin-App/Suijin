import Foundation
import SevindaCore
import Testing
@testable import SevindaAgents

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sevinda-agents-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeExecutable(at url: URL, script: String = "#!/bin/sh\nexit 0\n") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@Suite struct EnvPatchTests {
    @Test func appliesSetsAndRemovals() {
        let patch = EnvPatch(set: ["A": "1", "B": "2"], unset: ["C"])
        #expect(patch.applied(to: ["A": "0", "C": "3", "D": "4"]) == ["A": "1", "B": "2", "D": "4"])
    }

    @Test func setWinsOverUnsetOfSameKey() {
        let patch = EnvPatch(set: ["A": "1"], unset: ["A"])
        #expect(patch.applied(to: ["A": "0"]) == ["A": "1"])
    }

    @Test func emptyPatchIsIdentity() {
        #expect(EnvPatch.empty.applied(to: ["X": "y"]) == ["X": "y"])
    }

    @Test func mergingLetsOtherWin() {
        let base = EnvPatch(set: ["A": "1", "B": "2"], unset: ["C"])
        let other = EnvPatch(set: ["C": "3"], unset: ["A"])
        let merged = base.merging(other)
        #expect(merged.set == ["B": "2", "C": "3"])
        #expect(merged.unset == ["A"])
        #expect(merged.applied(to: ["A": "x", "C": "y"]) == ["B": "2", "C": "3"])
    }

    @Test func mergingMatchesSequentialApplication() {
        let first = EnvPatch(set: ["A": "1", "K": "k"], unset: ["B"])
        let second = EnvPatch(set: ["B": "2"], unset: ["K", "Z"])
        let base = ["A": "0", "B": "0", "K": "0", "Z": "0"]
        #expect(first.merging(second).applied(to: base) == second.applied(to: first.applied(to: base)))
    }
}

@Suite struct AgentCatalogTests {
    @Test func definitions() {
        #expect(AgentCatalog.all.map(\.kind) == [.claude, .codex])
        #expect(AgentCatalog.claude.binaryName == "claude")
        #expect(AgentCatalog.codex.binaryName == "codex")
        #expect(AgentCatalog.definition(for: .shell) == nil)
    }

    @Test func resolvesFirstExecutableOnPath() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a"), second = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try makeExecutable(at: second.appendingPathComponent("claude"))
        try makeExecutable(at: root.appendingPathComponent("c/claude"))
        let path = "::\(first.path):\(second.path):\(root.appendingPathComponent("c").path)"
        #expect(AgentCatalog.resolveBinary(.claude, path: path)?.path == second.appendingPathComponent("claude").path)
        #expect(AgentCatalog.resolveBinary(.codex, path: path) == nil)
        #expect(AgentCatalog.resolveBinary(.shell, path: path) == nil)
    }

    @Test func skipsNonExecutablesAndDirectories() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("plain"), dir = root.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try "not executable".write(to: plain.appendingPathComponent("codex"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("codex"), withIntermediateDirectories: true)
        let good = root.appendingPathComponent("good")
        try makeExecutable(at: good.appendingPathComponent("codex"))
        #expect(AgentCatalog.resolveBinary(.codex, path: "\(plain.path):\(dir.path)") == nil)
        #expect(AgentCatalog.resolveBinary(.codex, path: "\(plain.path):\(dir.path):\(good.path)")?.lastPathComponent == "codex")
    }

    @Test func extractsPATHBetweenMarkers() {
        let marker = AgentCatalog.pathMarker
        let noisy = Data("Welcome!\n\(marker)/usr/bin:/bin\(marker)\n".utf8)
        #expect(AgentCatalog.extractPATH(from: noisy) == "/usr/bin:/bin")
        #expect(AgentCatalog.extractPATH(from: Data("\(marker)/usr/bin".utf8)) == nil)
        #expect(AgentCatalog.extractPATH(from: Data("\(marker)\(marker)".utf8)) == nil)
    }

    /// A fake shell: prints `prelude`, then evaluates the script that follows `-c`.
    func makeFakeShell(in root: URL, prelude: String) throws -> URL {
        let shell = root.appendingPathComponent("fake-shell-\(UUID().uuidString)")
        try makeExecutable(at: shell, script: """
        #!/bin/sh
        \(prelude)
        while [ "$#" -gt 0 ] && [ "$1" != "-c" ]; do shift; done
        eval "$2"
        """)
        return shell
    }

    @Test func queriesShellThroughNoise() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = try makeFakeShell(in: root, prelude: """
        printf 'banner\\033[?25l __SEVINDA_ half marker\\n'
        PATH=/fake/bin:/usr/bin:/bin; export PATH
        """)
        let path = await AgentCatalog.queryShellPATH(shell: shell.path, arguments: ["-l", "-i"], timeout: .seconds(5))
        #expect(path == "/fake/bin:/usr/bin:/bin")
    }

    @Test func shellRunsDetachedWithDumbTerminal() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Reports through PATH: own process group (new session), stdin not a tty, TERM.
        let shell = try makeFakeShell(in: root, prelude: """
        pgid=$(ps -o pgid= -p $$ | tr -d ' ')
        if [ -t 0 ]; then tty=yes; else tty=no; fi
        PATH="leader=$([ "$pgid" = "$$" ] && echo yes || echo no),tty=$tty,term=$TERM"
        """)
        let path = await AgentCatalog.queryShellPATH(
            shell: shell.path, arguments: ["-l", "-i"], timeout: .seconds(5), environment: ["TERM": "xterm-256color"])
        #expect(path == "leader=yes,tty=no,term=dumb")
    }

    @Test func zshInteractiveProbeReadsZshrc() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rcBin = root.appendingPathComponent("rc-bin").path
        // Interactive-only noise: banner, a prompt question reading stdin, terminal escapes.
        try """
        echo "Welcome to a noisy shell"
        printf '\\033[?2004h'
        read -q "REPLY?Update plugins? [y/N] "
        export PATH="\(rcBin):$PATH"
        """.write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["ZDOTDIR"] = root.path
        let interactive = await AgentCatalog.queryShellPATH(
            shell: "/bin/zsh", arguments: ["-l", "-i"], timeout: .seconds(10), environment: environment)
        #expect(interactive?.split(separator: ":").first.map(String.init) == rcBin)
        let loginOnly = await AgentCatalog.queryShellPATH(
            shell: "/bin/zsh", arguments: ["-l"], timeout: .seconds(10), environment: environment)
        #expect(loginOnly != nil)
        #expect(loginOnly?.contains(rcBin) == false, "a non-interactive login zsh skips .zshrc")
    }

    @Test func finishesEarlyAndKillsTheProcessGroup() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("sleep.pid")
        // Starts a background child holding stdout open, prints the markers, then lingers.
        let shell = root.appendingPathComponent("lingering-shell")
        try makeExecutable(at: shell, script: """
        #!/bin/sh
        sleep 30 &
        echo $! > '\(pidFile.path)'
        printf '__SEVINDA_PATH__/early/bin__SEVINDA_PATH__'
        wait
        """)
        let start = Date()
        let path = await AgentCatalog.queryShellPATH(shell: shell.path, arguments: ["-l"], timeout: .seconds(10))
        #expect(path == "/early/bin")
        #expect(Date().timeIntervalSince(start) < 5)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let sleepPID = try #require(pid_t(pidText))
        var alive = true
        for _ in 0..<50 where alive {
            alive = kill(sleepPID, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!alive, "the lingering background child is terminated with its group")
    }

    @Test func killsChildrenLeftByAnExitedShell() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("orphan.pid")
        // The shell exits right away, leaving a child that ignores SIGTERM and holds stdout open.
        let shell = root.appendingPathComponent("leaving-shell")
        try makeExecutable(at: shell, script: """
        #!/bin/sh
        (trap '' TERM; sleep 30) &
        echo $! > '\(pidFile.path)'
        exit 0
        """)
        let path = await AgentCatalog.queryShellPATH(shell: shell.path, arguments: ["-l"], timeout: .milliseconds(300))
        #expect(path == nil)
        let orphan = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<60 where alive {
            alive = kill(orphan, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!alive, "SIGKILL reaches a group member that ignores SIGTERM")
    }

    @Test func shellTimeoutReturnsNil() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("slow-shell")
        try makeExecutable(at: shell, script: "#!/bin/sh\nexec sleep 30\n")
        let start = Date()
        let path = await AgentCatalog.queryShellPATH(shell: shell.path, arguments: ["-l", "-i"], timeout: .milliseconds(300))
        #expect(path == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func resolveFallsBackToLoginThenDefault() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Fails when interactive, answers as a plain login shell.
        let shell = try makeFakeShell(in: root, prelude: """
        for arg in "$@"; do [ "$arg" = "-i" ] && exit 1; done
        PATH=/login/bin:/usr/bin:/bin; export PATH
        """)
        #expect(await AgentCatalog.resolveShellPATH(shell: shell.path, timeout: .seconds(5)) == "/login/bin:/usr/bin:/bin")
        #expect(await AgentCatalog.resolveShellPATH(shell: "/nonexistent/shell", timeout: .seconds(1)) == AgentCatalog.fallbackPATH)
    }

    @Test func missingShellReturnsNil() async {
        #expect(await AgentCatalog.queryShellPATH(shell: "/nonexistent/shell", arguments: ["-l"], timeout: .seconds(1)) == nil)
    }

    @Test func fallbackPATHIncludesCommonDirectories() {
        let entries = AgentCatalog.fallbackPATH.split(separator: ":").map(String.init)
        #expect(entries.contains("/opt/homebrew/bin"))
        #expect(entries.contains("/usr/local/bin"))
        #expect(entries.contains { $0.hasSuffix("/.local/bin") })
    }
}

@Suite struct AgentLaunchSpecTests {
    let binary = URL(fileURLWithPath: "/usr/local/bin/agent")
    let cwd = URL(fileURLWithPath: "/tmp/work", isDirectory: true)
    let hooks = ClaudeHooks.Installation(
        settingsFile: URL(fileURLWithPath: "/data/hooks/claude-settings.json"),
        eventsDirectory: URL(fileURLWithPath: "/data/hooks/events", isDirectory: true))

    @Test func claudeWithHooksAndPrompt() throws {
        let session = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let spec = AgentLaunchSpecBuilder.make(
            kind: .claude, binary: binary, cwd: cwd, env: EnvPatch(set: ["CLAUDE_CONFIG_DIR": "/acct"], unset: ["ANTHROPIC_API_KEY"]),
            initialPrompt: "fix the tests", hooks: hooks, sessionID: session)
        #expect(spec.arguments == ["--settings", "/data/hooks/claude-settings.json", "fix the tests"])
        #expect(spec.env.set == [
            "CLAUDE_CONFIG_DIR": "/acct",
            "SEVINDA_HOOK_EVENTS": "/data/hooks/events/11111111-2222-3333-4444-555555555555.jsonl",
            "SEVINDA_SESSION_ID": "11111111-2222-3333-4444-555555555555",
        ])
        #expect(spec.env.unset == ["ANTHROPIC_API_KEY"])
        #expect(spec.initialPrompt == "fix the tests")
        #expect(spec.cwd == cwd)
        #expect(spec.binary == binary)
    }

    @Test func claudeWithoutHooksOrPrompt() {
        let spec = AgentLaunchSpecBuilder.make(kind: .claude, binary: binary, cwd: cwd, env: .empty, initialPrompt: "   ", hooks: nil)
        #expect(spec.arguments.isEmpty)
        #expect(spec.env == .empty)
        #expect(spec.initialPrompt == nil)
    }

    @Test func codexIgnoresHooks() {
        let spec = AgentLaunchSpecBuilder.make(
            kind: .codex, binary: binary, cwd: cwd, env: .empty, initialPrompt: "explain this repo", hooks: hooks, sessionID: UUID())
        #expect(spec.arguments == ["explain this repo"])
        #expect(spec.env == .empty)
    }

    @Test func dashPromptIsSeparated() {
        for kind in [AgentKind.claude, .codex] {
            let spec = AgentLaunchSpecBuilder.make(kind: kind, binary: binary, cwd: cwd, env: .empty, initialPrompt: "--help me", hooks: nil)
            #expect(spec.arguments == ["--", "--help me"])
        }
    }

    @Test func shellHasNoArguments() {
        let spec = AgentLaunchSpecBuilder.make(kind: .shell, binary: binary, cwd: cwd, env: .empty, initialPrompt: "ls", hooks: hooks)
        #expect(spec.arguments.isEmpty)
        #expect(spec.initialPrompt == nil)
    }
}
