import Foundation
import Testing
@testable import SuijinAccounts

/// Login runners against fake CLI scripts; no real `claude` or `codex` is ever started.
@Suite struct ClaudeLoginRunnerTests {
    let baseEnv = ["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "sk-leak", "CLAUDECODE": "1", "HOME": "/nowhere"]

    @Test func streamsLinesAndSucceedsOnExitZero() async throws {
        let box = try Sandbox()
        let cli = try box.script("claude", """
        echo "args: $*"
        echo "config: $CLAUDE_CONFIG_DIR"
        echo "key: ${ANTHROPIC_API_KEY:-unset} stamp: ${CLAUDECODE:-unset}"
        printf '\\033[1mOpening browser\\033[0m\\nhttps://claude.ai/oauth/authorize?code=true&state=abc\\n'
        """)
        let home = box.base.appendingPathComponent("profile/home")
        try box.mkdir(home)
        let session = try ClaudeLoginRunner(executable: cli, baseEnvironment: baseEnv).start(home: home)
        async let lines = collect(session)
        try await session.wait()
        let output = await lines
        #expect(output.contains("args: auth login --claudeai"))
        #expect(output.contains("config: \(home.path)"))
        #expect(output.contains("key: unset stamp: unset"))
        #expect(output.contains("Opening browser"))
        #expect(output.contains("https://claude.ai/oauth/authorize?code=true&state=abc"))
    }

    @Test func nonZeroExitFailsWithTheOutputTail() async throws {
        let box = try Sandbox()
        let cli = try box.script("claude", "echo 'network unreachable' >&2; exit 3")
        let session = try ClaudeLoginRunner(executable: cli, baseEnvironment: baseEnv).start(home: box.base)
        await #expect(throws: LoginError.failed(exitCode: 3, output: "network unreachable")) { try await session.wait() }
    }

    @Test func deniedSignInFailsImmediately() async throws {
        let box = try Sandbox()
        let cli = try box.script("claude", "echo 'Error: access_denied'; sleep 30")
        let start = Date()
        let session = try ClaudeLoginRunner(executable: cli, baseEnvironment: baseEnv).start(home: box.base)
        await #expect(throws: LoginError.denied) { try await session.wait() }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func cancelStopsTheProcess() async throws {
        let box = try Sandbox()
        let cli = try box.script("claude", "echo waiting; exec sleep 30")
        let session = try ClaudeLoginRunner(executable: cli, baseEnvironment: baseEnv).start(home: box.base)
        try await Task.sleep(for: .milliseconds(200))
        session.cancel()
        await #expect(throws: LoginError.cancelled) { try await session.wait() }
    }

    @Test func timesOut() async throws {
        let box = try Sandbox()
        let cli = try box.script("claude", "exec sleep 30")
        let session = try ClaudeLoginRunner(executable: cli, baseEnvironment: baseEnv, timeout: .milliseconds(300))
            .start(home: box.base)
        await #expect(throws: LoginError.timedOut) { try await session.wait() }
    }

    @Test func pastedCodeReachesStdin() async throws {
        let box = try Sandbox()
        let cli = try box.script("claude", "read code; echo \"got $code\"")
        let session = try ClaudeLoginRunner(executable: cli, baseEnvironment: baseEnv).start(home: box.base)
        let interactive = try #require(session as? InteractiveLoginSession)
        async let lines = collect(session)
        interactive.send("ABC123\n")
        try await session.wait()
        #expect(await lines.contains("got ABC123"))
    }

    @Test func missingExecutableIsALaunchFailure() throws {
        let box = try Sandbox()
        #expect(throws: LoginError.self) {
            try ClaudeLoginRunner(executable: URL(fileURLWithPath: "/nonexistent/claude"), baseEnvironment: [:])
                .start(home: box.base)
        }
    }
}

@Suite struct CodexLoginRunnerTests {
    @Test func completesWhenAuthJsonAppearsEvenIfTheCliLingers() async throws {
        let box = try Sandbox()
        let cli = try box.script("codex", """
        echo "Starting local login server on http://localhost:1455."
        echo "If your browser did not open, navigate to this URL to authenticate:"
        echo ""
        echo "https://auth.openai.com/oauth/authorize?client_id=app&state=xyz"
        echo '{"tokens":{"access_token":"a"}}' > "$CODEX_HOME/auth.json"
        exec sleep 30
        """)
        let home = box.base.appendingPathComponent("acct/home")
        try box.mkdir(home)
        let start = Date()
        let session = try CodexLoginRunner(
            executable: cli, baseEnvironment: ["PATH": "/usr/bin:/bin", "OPENAI_API_KEY": "sk"],
            postAuthGrace: .milliseconds(300)
        ).start(home: home)
        async let lines = collect(session)
        try await session.wait()
        #expect(Date().timeIntervalSince(start) < 10)
        let output = await lines
        let link = CodexLoginRunner.authURL(in: output.joined(separator: "\n") + "\n")
        #expect(link?.absoluteString == "https://auth.openai.com/oauth/authorize?client_id=app&state=xyz")
        #expect(try posixMode(home.appendingPathComponent("auth.json")) == 0o600)
        // Once credentials changed, cancelling must not roll the login back.
        session.cancel()
        try await session.wait()
    }

    @Test func reauthenticationGoesThroughAStagingHome() async throws {
        let box = try Sandbox()
        let home = box.base.appendingPathComponent("acct/home")
        try box.write("{\"old\":true}", to: home.appendingPathComponent("auth.json"), mode: 0o600)
        try box.write("model = \"x\"\n", to: home.appendingPathComponent("config.toml"))
        let cli = try box.script("codex", """
        test -f "$CODEX_HOME/config.toml" || exit 9
        echo '{"new":true}' > "$CODEX_HOME/auth.json"
        exit 0
        """)
        let session = try CodexLoginRunner(executable: cli, baseEnvironment: ["PATH": "/usr/bin:/bin"]).start(home: home)
        try await session.wait()
        #expect(try readText(home.appendingPathComponent("auth.json")) == "{\"new\":true}\n")
        #expect(try posixMode(home.appendingPathComponent("auth.json")) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".suijin-login-staging").path))
    }

    @Test func failedReauthenticationKeepsTheOldCredentials() async throws {
        let box = try Sandbox()
        let home = box.base.appendingPathComponent("acct/home")
        try box.write("{\"old\":true}", to: home.appendingPathComponent("auth.json"), mode: 0o600)
        let cli = try box.script("codex", "echo 'Login cancelled' >&2; exit 1")
        let session = try CodexLoginRunner(executable: cli, baseEnvironment: ["PATH": "/usr/bin:/bin"]).start(home: home)
        await #expect(throws: LoginError.self) { try await session.wait() }
        #expect(try readText(home.appendingPathComponent("auth.json")) == "{\"old\":true}")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".suijin-login-staging").path))
    }

    @Test func deviceAuthArguments() async throws {
        let box = try Sandbox()
        let cli = try box.script("codex", "echo \"args: $*\"")
        let session = try CodexLoginRunner(executable: cli, baseEnvironment: [:], deviceAuth: true).start(home: box.base)
        async let lines = collect(session)
        try await session.wait()
        #expect(await lines.contains("args: login --device-auth"))
    }

    @Test func authURLNeedsTheMarkerAndACompleteLink() {
        #expect(CodexLoginRunner.authURL(in: "see https://github.com/openai/codex/releases\n") == nil)
        #expect(CodexLoginRunner.authURL(in: "navigate to this URL to authenticate:\nhttps://auth.openai.com/x?y=1") == nil)
        #expect(CodexLoginRunner.authURL(in: "\u{1B}[1mNavigate to this URL to authenticate:\u{1B}[0m https://auth.openai.com/x?y=1.\n")?
            .absoluteString == "https://auth.openai.com/x?y=1")
    }
}
