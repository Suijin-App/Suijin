import Foundation
import Testing
@testable import SuijinAccounts

private func makeCodex(_ box: Sandbox, shareSessions: Bool = false) -> CodexAccountProvider {
    CodexAccountProvider(
        dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/codex"),
        environment: [:], shareSessions: shareSessions, runner: FakeCommandRunner())
}

@Suite struct CodexHomeStoreTests {
    @Test func createsAnOwnedPrivateHome() throws {
        let box = try Sandbox()
        let codex = makeCodex(box)
        let id = UUID()
        let home = try codex.createHome(accountID: id)
        #expect(home == codex.store.home(for: id))
        #expect(try posixMode(home) == 0o700)
        let marker = home.appendingPathComponent(".suijin-managed-home")
        #expect(try readText(marker) == id.uuidString.lowercased() + "\n")
        #expect(try posixMode(marker) == 0o600)
        try codex.store.verify(home: home)
    }

    @Test func refusesForeignOrMarkerlessHomes() throws {
        let box = try Sandbox()
        let codex = makeCodex(box)
        let id = UUID()
        let home = try codex.createHome(accountID: id)
        try box.write("someone-else\n", to: home.appendingPathComponent(".suijin-managed-home"))
        #expect(throws: AccountsError.self) { try codex.store.verify(home: home) }
        #expect(throws: AccountsError.self) { try codex.store.create(accountID: id) }
        #expect(throws: AccountsError.self) { try codex.store.verify(home: box.codexHome) }
        let bare = codex.store.home(for: UUID())
        try box.mkdir(bare)
        #expect(throws: AccountsError.self) { try codex.store.verify(home: bare) }
    }

    @Test func refusesAStorageRootInsideDotCodex() throws {
        let box = try Sandbox()
        try box.mkdir(box.codexHome)
        let codex = CodexAccountProvider(
            dataRoot: box.codexHome.appendingPathComponent("suijin"), realHome: box.realHome,
            executable: URL(fileURLWithPath: "/nonexistent/codex"), environment: [:], shareSessions: false,
            runner: FakeCommandRunner())
        #expect(throws: AccountsError.self) { try codex.createHome(accountID: UUID()) }
    }

    @Test func refusesAddingWhileTheUserPinsACustomProvider() throws {
        let box = try Sandbox()
        try box.write("model_provider = \"azure\"\n[model_providers.azure]\nname = \"Azure\"\n",
                      to: box.codexHome.appendingPathComponent("config.toml"))
        #expect(throws: AccountsError.self) { try makeCodex(box).createHome(accountID: UUID()) }
        try box.write("model_provider = \"openai\"\n", to: box.codexHome.appendingPathComponent("config.toml"))
        _ = try makeCodex(box).createHome(accountID: UUID())
    }

    @Test func removeHomeLogsOutThenDeletes() async throws {
        let box = try Sandbox()
        let runner = FakeCommandRunner { _ in CommandResult(exitCode: 0, stdout: Data(), stderr: Data()) }
        let script = try box.script("codex", "exit 0")
        let codex = CodexAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: script, environment: [:],
            shareSessions: false, runner: runner)
        let home = try codex.createHome(accountID: UUID())
        try box.write("{}", to: home.appendingPathComponent("auth.json"), mode: 0o600)
        try await codex.removeHome(home)
        #expect(!FileManager.default.fileExists(atPath: home.deletingLastPathComponent().path))
        #expect(runner.recorded.map(\.arguments) == [["logout"]])
        #expect(runner.recorded.first?.environment?["CODEX_HOME"] == home.path)
    }
}

@Suite struct CodexConfigMirrorTests {
    @Test func mirrorsAFreshHomeAndUpdatesWhenTheSourceChanges() async throws {
        let box = try Sandbox()
        let source = box.codexHome.appendingPathComponent("config.toml")
        try box.write("model = \"gpt-5\"\n\n[mcp_servers.docs]\ncommand = \"docs\"\n", to: source)
        let codex = makeCodex(box)
        let home = try codex.createHome(accountID: UUID())
        let config = home.appendingPathComponent("config.toml")
        #expect(try readText(config).contains("model = \"gpt-5\""))
        #expect(try posixMode(config) == 0o600)

        try box.write("model = \"gpt-5-codex\"\n\n[mcp_servers.docs]\ncommand = \"docs\"\n", to: source)
        try await codex.prepareForLaunch(home: home)
        let text = try readText(config)
        #expect(text.contains("model = \"gpt-5-codex\""))
        #expect(!text.contains("model = \"gpt-5\"\n"))
        #expect(treeSnapshot(box.codexHome)["config.toml"] == Data("model = \"gpt-5-codex\"\n\n[mcp_servers.docs]\ncommand = \"docs\"\n".utf8))
    }

    @Test func keepsHomeEditsUntilTheSourceChanges() async throws {
        let box = try Sandbox()
        let source = box.codexHome.appendingPathComponent("config.toml")
        try box.write("model = \"gpt-5\"\n", to: source)
        let codex = makeCodex(box)
        let home = try codex.createHome(accountID: UUID())
        let config = home.appendingPathComponent("config.toml")
        let edited = try readText(config).replacingOccurrences(of: "gpt-5", with: "o3")
        try box.write(edited, to: config)
        try await codex.prepareForLaunch(home: home)
        #expect(try readText(config).contains("model = \"o3\""))
    }

    @Test func preservesHomeOwnedTrustAndServers() {
        let runtime = """
        model = "old"

        [projects."/repo/a"]
        trust_level = "trusted"

        [projects."/repo/b"]
        trust_level = "trusted"

        [hooks.state."/x/hooks.json:stop:0:0"]
        trusted_hash = "abc"

        [mcp_servers.mine]
        command = "mine"

        [mcp_servers.gone]
        command = "gone"
        """
        let system = """
        model = "new"

        [projects."/repo/b"]
        trust_level = "untrusted"

        [projects."/repo/c"]
        trust_level = "trusted"

        [mcp_servers.docs]
        command = "docs"
        """
        let merged = CodexConfigMirror.merge(
            runtime: runtime, system: system, systemHome: "/Users/x/.codex", mirroredServers: ["gone"], mirroredRoot: false)
        #expect(merged.contains("model = \"new\""))
        #expect(!merged.contains("model = \"old\""))
        #expect(merged.contains("[projects.\"/repo/a\"]\ntrust_level = \"trusted\""))
        // A system revocation wins over the home's grant.
        #expect(merged.contains("[projects.\"/repo/b\"]\ntrust_level = \"untrusted\""))
        #expect(!merged.contains("[projects.\"/repo/b\"]\ntrust_level = \"trusted\""))
        #expect(merged.contains("[projects.\"/repo/c\"]"))
        #expect(merged.contains("[hooks.state.\"/x/hooks.json:stop:0:0\"]"))
        #expect(merged.contains("[mcp_servers.mine]"))
        #expect(merged.contains("[mcp_servers.docs]"))
        // Mirrored earlier and since removed from the system config.
        #expect(!merged.contains("[mcp_servers.gone]"))
    }

    @Test func homeScopedHookTrustIsNotShared() {
        let system = "[hooks.state.\"/Users/x/.codex/hooks.json:stop:0:0\"]\ntrusted_hash = \"a\"\n\n[hooks.state.\"/repo/.codex/hooks.json:stop:0:0\"]\ntrusted_hash = \"b\"\n"
        let fresh = CodexConfigMirror.fresh(system: system, systemHome: "/Users/x/.codex")
        #expect(!fresh.contains("/Users/x/.codex/hooks.json"))
        #expect(fresh.contains("/repo/.codex/hooks.json"))
    }

    @Test func rewritesRelativePathSettings() {
        let config = "model_instructions_file = \"prompts/base.md\"\nlog_dir = \"/abs/logs\"\nmodel = \"x\"\n\n[skills.config]\npath = \"skills\"\n"
        let rewritten = CodexConfigMirror.rewriteRelativePaths(config, sourceDir: "/Users/x/.codex")
        #expect(rewritten.contains("model_instructions_file = \"/Users/x/.codex/prompts/base.md\""))
        #expect(rewritten.contains("log_dir = \"/abs/logs\""))
        #expect(rewritten.contains("path = \"/Users/x/.codex/skills\""))
        #expect(rewritten.contains("model = \"x\""))
    }

    @Test func blankSourceNeverClearsAHomeConfig() async throws {
        let box = try Sandbox()
        let source = box.codexHome.appendingPathComponent("config.toml")
        try box.write("model = \"gpt-5\"\n", to: source)
        let codex = makeCodex(box)
        let home = try codex.createHome(accountID: UUID())
        try box.write("", to: source)
        try await codex.prepareForLaunch(home: home)
        #expect(try readText(home.appendingPathComponent("config.toml")).contains("model = \"gpt-5\""))
    }

    @Test func daemonGuardTracksTheSocketPathLength() {
        let long = "/Users/someone/Library/Application Support/Suijin/codex-homes/0f8fad5b-d9cb-469f-a165-70867728950e/home"
        #expect(CodexConfigMirror.socketPathExceedsLimit(homePath: long))
        #expect(!CodexConfigMirror.socketPathExceedsLimit(homePath: "/tmp/h"))

        let guarded = CodexConfigMirror.applyDaemonGuard("model = \"x\"\n", homePath: long)
        #expect(guarded.contains("[features]\ndaemon_auto_start = false # suijin: CODEX_HOME too long for the daemon socket"))
        #expect(CodexConfigMirror.applyDaemonGuard(guarded, homePath: long) == guarded)
        #expect(CodexConfigMirror.applyDaemonGuard(guarded, homePath: "/tmp/h") == "model = \"x\"\n")

        let existing = CodexConfigMirror.applyDaemonGuard("[features]\nweb_search = true\n", homePath: long)
        #expect(existing == "[features]\nweb_search = true\ndaemon_auto_start = false \(CodexConfigMirror.daemonMarker)\n")
        let userChoice = "[features]\ndaemon_auto_start = true\n"
        #expect(CodexConfigMirror.applyDaemonGuard(userChoice, homePath: long) == userChoice)
    }

    @Test func linksResourcesAndCopiesRules() async throws {
        let box = try Sandbox()
        try box.mkdir(box.codexHome.appendingPathComponent("skills/a"))
        try box.write("# agents", to: box.codexHome.appendingPathComponent("AGENTS.md"))
        try box.write("prefix_rule()", to: box.codexHome.appendingPathComponent("rules/default.rules"))
        let codex = makeCodex(box)
        let home = try codex.createHome(accountID: UUID())
        try await codex.prepareForLaunch(home: home)
        #expect(symlinkTarget(home.appendingPathComponent("skills")) == box.codexHome.appendingPathComponent("skills").path)
        #expect(symlinkTarget(home.appendingPathComponent("AGENTS.md")) == box.codexHome.appendingPathComponent("AGENTS.md").path)
        #expect(try readText(home.appendingPathComponent("rules/_suijin-global-default.rules")) == "prefix_rule()")

        try FileManager.default.removeItem(at: box.codexHome.appendingPathComponent("AGENTS.md"))
        try FileManager.default.removeItem(at: box.codexHome.appendingPathComponent("rules/default.rules"))
        try await codex.prepareForLaunch(home: home)
        #expect(symlinkTarget(home.appendingPathComponent("AGENTS.md")) == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("rules/_suijin-global-default.rules").path))
    }
}

@Suite struct CodexSessionSharingTests {
    @Test func hardlinksMissingRolloutsOnceTheHomeHasHistory() throws {
        let box = try Sandbox()
        let codex = makeCodex(box, shareSessions: true)
        let home = try codex.createHome(accountID: UUID())
        let rollout = box.codexHome.appendingPathComponent("sessions/2025/11/11/rollout-2025-11-11T10-00-00-aaa.jsonl")
        try box.write("{\"a\":1}\n", to: rollout)

        // A home Codex has not indexed yet gets nothing.
        #expect(try codex.shareSessionsNow(into: home).linked == 0)

        try box.write("{}\n", to: home.appendingPathComponent("sessions/2025/11/10/rollout-own.jsonl"))
        let pass = try codex.shareSessionsNow(into: home)
        #expect(pass.linked == 1)
        let linked = home.appendingPathComponent("sessions/2025/11/11/rollout-2025-11-11T10-00-00-aaa.jsonl")
        let sourceInode = try FileManager.default.attributesOfItem(atPath: rollout.path)[.systemFileNumber] as? Int
        let linkedInode = try FileManager.default.attributesOfItem(atPath: linked.path)[.systemFileNumber] as? Int
        #expect(sourceInode == linkedInode)
        // Idempotent, and existing names are never replaced.
        #expect(try codex.shareSessionsNow(into: home).linked == 0)
    }
}

@Suite struct CodexIdentityTests {
    func authJSON(_ payload: [String: Any], tokens extra: [String: Any] = [:]) throws -> Data {
        let jwt = "eyJhbGciOiJSUzI1NiJ9.\(try base64URL(payload)).signature"
        var tokens: [String: Any] = ["id_token": jwt, "access_token": "at-1", "refresh_token": "rt-1"]
        tokens.merge(extra) { $1 }
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": tokens])
    }

    @Test func readsEmailAccountAndPlanFromTheIdToken() throws {
        let data = try authJSON([
            "email": "dev@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-9", "chatgpt_plan_type": "pro"],
        ])
        let identity = try #require(CodexIdentity.parse(data))
        #expect(identity.email == "dev@example.com")
        #expect(identity.providerAccountID == "acct-9")
        #expect(identity.workspaceLabel == "Personal (Pro)")
        // Orca reads the workspace id from `workspace_account_id`, the token, or the top-level claim only.
        #expect(identity.workspaceAccountID == nil)
    }

    @Test func tokenAccountIdAndWorkspaceNameWin() throws {
        let data = try authJSON([
            "https://api.openai.com/profile": ["email": "p@example.com"],
            "https://api.openai.com/auth": ["chatgpt_account_id": "claim", "workspace_name": "Acme", "chatgpt_plan_type": "team"],
        ], tokens: ["account_id": "tok-acct"])
        let identity = try #require(CodexIdentity.parse(data))
        #expect(identity.email == "p@example.com")
        #expect(identity.providerAccountID == "tok-acct")
        #expect(identity.workspaceLabel == "Acme")
    }

    @Test func apiKeyAndGarbage() {
        #expect(CodexIdentity.parse(Data(#"{"OPENAI_API_KEY":"sk-x"}"#.utf8))?.isAPIKey == true)
        #expect(CodexIdentity.parse(Data("not json".utf8)) == nil)
        #expect(CodexIdentity.parse(Data(#"{"tokens":{"id_token":"bad"}}"#.utf8)) == CodexAuthIdentity())
    }

    @Test func providerIdentityMapsTheClaims() async throws {
        let box = try Sandbox()
        let codex = makeCodex(box)
        let home = try codex.createHome(accountID: UUID())
        #expect(await codex.identity(home: home) == nil)
        let data = try authJSON(["email": "dev@example.com", "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]],
                                tokens: ["account_id": "a1"])
        try data.write(to: home.appendingPathComponent("auth.json"))
        #expect(await codex.identity(home: home)
            == AccountIdentity(email: "dev@example.com", organization: "Personal (Plus)", accountID: "a1"))
    }
}
