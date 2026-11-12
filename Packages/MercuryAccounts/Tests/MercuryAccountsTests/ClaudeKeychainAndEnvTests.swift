import Foundation
import MercuryAgents
import Testing
@testable import MercuryAccounts

@Suite struct ClaudeKeychainTests {
    @Test func serviceNamesMatchClaudesConfigScopedNaming() {
        // Vectors computed independently with `printf %s <dir> | shasum -a 256 | cut -c1-8`.
        #expect(ClaudeKeychainReader.serviceName(configDir: nil) == "Claude Code-credentials")
        #expect(ClaudeKeychainReader.serviceName(configDir: "/Users/test/.claude-profile") == "Claude Code-credentials-66d7367b")
        #expect(ClaudeKeychainReader.serviceName(
            configDir: "/Users/test/Library/Application Support/Mercury/claude-profiles/0f8fad5b-d9cb-469f-a165-70867728950e/home")
            == "Claude Code-credentials-45b65bd9")
        // NFC normalization: composed and decomposed spellings name the same item.
        #expect(ClaudeKeychainReader.serviceName(configDir: "/Users/caf\u{E9}/.claude") == "Claude Code-credentials-da474c2a")
        #expect(ClaudeKeychainReader.serviceName(configDir: "/Users/cafe\u{301}/.claude") == "Claude Code-credentials-da474c2a")
    }

    @Test func keychainUserFallsBackForUnsafeNames() {
        #expect(ClaudeKeychainReader.keychainUser(environment: ["USER": "vu.dev-1"]) == "vu.dev-1")
        #expect(ClaudeKeychainReader.keychainUser(environment: ["USER": "me@corp.com"]) == "claude-code-user")
    }

    @Test func aliasesResolveSymlinkedAncestorsWithoutCreatingAnything() throws {
        let box = try Sandbox()
        let canonical = box.base.appendingPathComponent("canonical")
        let linked = box.base.appendingPathComponent("linked")
        try box.mkdir(canonical)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: canonical)
        for segments in [[".claude"], ["removed", ".claude"]] {
            let configDir = segments.reduce(linked.path) { $0 + "/" + $1 }
            let expected = segments.reduce(canonical.path) { $0 + "/" + $1 }
            #expect(ClaudeKeychainReader.aliases(configDir: configDir) == [configDir, expected])
            #expect(!FileManager.default.fileExists(atPath: configDir))
        }
    }

    @Test func aliasesDoNotGuessThroughParentTraversalOrBrokenLinks() throws {
        let box = try Sandbox()
        let child = box.base.appendingPathComponent("canonical/child")
        try box.mkdir(child)
        let childLink = box.base.appendingPathComponent("child-link")
        try FileManager.default.createSymbolicLink(at: childLink, withDestinationURL: child)
        let traversal = childLink.path + "/../.claude"
        #expect(ClaudeKeychainReader.aliases(configDir: traversal) == [traversal])

        let broken = box.base.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: box.base.appendingPathComponent("missing"))
        #expect(ClaudeKeychainReader.aliases(configDir: broken.path) == [broken.path])
    }

    @Test func spellingsIncludeHomeRelativeForms() {
        let spellings = ClaudeKeychainReader.spellings(configDir: "/Users/x/.p/home", userHome: "/Users/x")
        for expected in ["/Users/x/.p/home", "/Users/x/.p/home/", "~/.p/home", "$HOME/.p/home/"] {
            #expect(spellings.contains(expected))
        }
    }

    @Test func readsOnlyTheProfilesItemAndNeverTheDefault() async throws {
        let box = try Sandbox()
        let home = box.base.appendingPathComponent("profile/home")
        try box.mkdir(home)
        let service = ClaudeKeychainReader.serviceName(configDir: home.path)
        let runner = FakeCommandRunner { call in
            guard call.arguments.contains(service) else {
                return CommandResult(exitCode: 44, stdout: Data(), stderr: Data("could not be found".utf8))
            }
            return CommandResult(exitCode: 0, stdout: Data(#"{"claudeAiOauth":{"accessToken":"tok-123"}}"#.utf8), stderr: Data())
        }
        let reader = ClaudeKeychainReader(runner: runner, environment: ["USER": "tester"])
        #expect(try await reader.accessToken(configDir: home) == "tok-123")
        let call = try #require(runner.recorded.first)
        #expect(call.executable == "/usr/bin/security")
        #expect(call.arguments == ["find-generic-password", "-s", service, "-a", "tester", "-w"])
        #expect(!runner.recorded.contains { $0.arguments.contains(ClaudeKeychainReader.defaultService) })
    }

    @Test func missingItemFallsBackToTheProfilesCredentialsFileOnly() async throws {
        let box = try Sandbox()
        let home = box.base.appendingPathComponent("profile/home")
        let runner = FakeCommandRunner()
        let reader = ClaudeKeychainReader(runner: runner, environment: ["USER": "tester"])
        try box.mkdir(home)
        #expect(try await reader.accessToken(configDir: home) == nil)
        try box.write(#"{"claudeAiOauth":{"accessToken":"file-tok"}}"#, to: home.appendingPathComponent(".credentials.json"))
        #expect(try await reader.accessToken(configDir: home) == "file-tok")
        #expect(!runner.recorded.contains { $0.arguments.contains(ClaudeKeychainReader.defaultService) })
    }

    @Test func aBrokenKeychainIsAnErrorNotADefaultFallback() async throws {
        let box = try Sandbox()
        let home = box.base.appendingPathComponent("profile/home")
        try box.mkdir(home)
        let runner = FakeCommandRunner { _ in CommandResult(exitCode: 51, stdout: Data(), stderr: Data("denied".utf8)) }
        let reader = ClaudeKeychainReader(runner: runner, environment: ["USER": "tester"])
        await #expect(throws: UsageError.keychainUnavailable) { try await reader.accessToken(configDir: home) }
    }
}

@Suite struct LaunchEnvTests {
    let inherited = [
        "ANTHROPIC_API_KEY": "sk", "ANTHROPIC_AUTH_TOKEN": "t", "CLAUDE_CODE_OAUTH_TOKEN": "o",
        "AWS_BEARER_TOKEN_BEDROCK": "b", "ANTHROPIC_CUSTOM_HEADERS": "Authorization: Bearer x", "CLAUDECODE": "1",
        "PATH": "/usr/bin",
    ]

    @Test func claudeProfileSetsConfigDirAndStripsCredentials() {
        let home = URL(fileURLWithPath: "/data/claude-profiles/abc/home")
        let patch = ClaudeLaunchEnv.patch(home: home, inheritedEnv: inherited)
        #expect(patch.set == ["CLAUDE_CONFIG_DIR": home.path, "MERCURY_CLAUDE_INJECTED_CONFIG_DIR": home.path])
        for key in ClaudeLaunchEnv.authEnvVars + ["ANTHROPIC_CUSTOM_HEADERS", "CLAUDECODE"] {
            #expect(patch.unset.contains(key), "\(key)")
        }
        let env = patch.applied(to: inherited)
        #expect(env["CLAUDE_CONFIG_DIR"] == home.path)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["PATH"] == "/usr/bin")
    }

    @Test func benignCustomHeadersSurvive() {
        let patch = ClaudeLaunchEnv.patch(
            home: URL(fileURLWithPath: "/p/home"), inheritedEnv: ["ANTHROPIC_CUSTOM_HEADERS": "X-Team: core"])
        #expect(!patch.unset.contains("ANTHROPIC_CUSTOM_HEADERS"))
    }

    @Test func claudeDefaultLoginKeepsTheUsersOwnConfigAndAuth() {
        let own = ClaudeLaunchEnv.patch(home: nil, inheritedEnv: inherited.merging(["CLAUDE_CONFIG_DIR": "/mine"]) { $1 })
        #expect(own.set.isEmpty)
        #expect(!own.unset.contains("CLAUDE_CONFIG_DIR"))
        #expect(!own.unset.contains("ANTHROPIC_API_KEY"))
        #expect(own.unset.contains("CLAUDECODE"))

        let injected = ClaudeLaunchEnv.patch(
            home: nil, inheritedEnv: ["CLAUDE_CONFIG_DIR": "/p/home", "MERCURY_CLAUDE_INJECTED_CONFIG_DIR": "/p/home"])
        #expect(injected.unset.isSuperset(of: ["CLAUDE_CONFIG_DIR", "MERCURY_CLAUDE_INJECTED_CONFIG_DIR"]))
    }

    @Test func codexHomeAndDefault() {
        let home = URL(fileURLWithPath: "/data/codex-homes/abc/home")
        #expect(CodexLaunchEnv.patch(home: home, inheritedEnv: [:])
            == EnvPatch(set: ["CODEX_HOME": home.path, "MERCURY_CODEX_INJECTED_HOME": home.path]))
        #expect(CodexLaunchEnv.patch(home: nil, inheritedEnv: ["CODEX_HOME": "/mine"]) == .empty)
        #expect(CodexLaunchEnv.patch(
            home: nil, inheritedEnv: ["CODEX_HOME": home.path, "MERCURY_CODEX_INJECTED_HOME": home.path])
            == EnvPatch(unset: ["CODEX_HOME", "MERCURY_CODEX_INJECTED_HOME"]))
    }

    @Test func pointerFilesAreWrittenAndCleared() async throws {
        let box = try Sandbox()
        let claude = ClaudeAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/claude"),
            environment: [:], runner: FakeCommandRunner())
        let home = try claude.createHome(accountID: UUID())
        try claude.writePointer(home: home)
        let pointer = box.dataRoot.appendingPathComponent("claude-profiles/selected-host")
        #expect(try readText(pointer) == home.path)
        #expect(try posixMode(pointer) == 0o600)
        try claude.writePointer(home: nil)
        #expect(!FileManager.default.fileExists(atPath: pointer.path))
        try claude.writePointer(home: nil)
        #expect(throws: AccountsError.self) { try claude.writePointer(home: box.claudeHome) }

        let codex = CodexAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/codex"),
            environment: [:], shareSessions: false, runner: FakeCommandRunner())
        let codexHome = try codex.createHome(accountID: UUID())
        try codex.writePointer(home: codexHome)
        #expect(try readText(box.dataRoot.appendingPathComponent("codex-homes/selected-host")) == codexHome.path)
        try codex.writePointer(home: nil)
        #expect(!FileManager.default.fileExists(atPath: box.dataRoot.appendingPathComponent("codex-homes/selected-host").path))
    }
}
