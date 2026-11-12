import Foundation
import Testing
@testable import SevindaAccounts

/// Managed accounts must neither write runtime state into the user's own homes nor inherit their credentials.
@Suite struct ProfileIsolationTests {
    func makeClaude(_ box: Sandbox) -> ClaudeAccountProvider {
        ClaudeAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/claude"),
            environment: [:], runner: FakeCommandRunner())
    }

    @Test func onlyAllowListedFoldersAreLinked() throws {
        let box = try Sandbox()
        for name in ClaudeProfileProvisioner.sharedDirectories.sorted() + ["session-states", "some-future-runtime-dir"] {
            try box.mkdir(box.claudeHome.appendingPathComponent(name))
        }
        let before = treeSnapshot(box.realHome)
        let (home, report) = try makeClaude(box).setUpProfile(accountID: UUID())
        for name in ClaudeProfileProvisioner.sharedDirectories {
            #expect(symlinkTarget(home.appendingPathComponent(name)) == box.claudeHome.appendingPathComponent(name).path, "\(name)")
        }
        for name in ["session-states", "some-future-runtime-dir"] {
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(name).path), "\(name)")
            #expect(report.surfaces[name] == .absent)
        }
        #expect(treeSnapshot(box.realHome) == before)
    }

    @Test func authSettingsAreNeverSyncedIntoAProfile() throws {
        let box = try Sandbox()
        try box.writeJSON([
            "model": "opus",
            "apiKeyHelper": "/usr/local/bin/key-helper",
            "awsAuthRefresh": "aws sso login",
            "awsCredentialExport": "/bin/export-creds",
            "forceLoginMethod": "console",
            "forceLoginOrgUUID": "org-1",
            "env": [
                "ANTHROPIC_API_KEY": "sk-ant-secret", "ANTHROPIC_AUTH_TOKEN": "t", "CLAUDE_CODE_OAUTH_TOKEN": "o",
                "AWS_BEARER_TOKEN_BEDROCK": "b", "ANTHROPIC_CUSTOM_HEADERS": "x-api-key: k", "DISABLE_TELEMETRY": "1",
            ],
        ], to: box.claudeHome.appendingPathComponent("settings.json"))
        let (home, report) = try makeClaude(box).setUpProfile(accountID: UUID())
        let settings = try readJSON(home.appendingPathComponent("settings.json"))
        #expect(settings["model"] as? String == "opus")
        for key in ClaudeSettingsSync.authKeys {
            #expect(settings[key] == nil, "\(key)")
        }
        #expect(settings["env"] as? [String: String] == ["DISABLE_TELEMETRY": "1"])
        let raw = try readText(home.appendingPathComponent("settings.json"))
        #expect(!raw.contains("sk-ant-secret"))
        let warning = try #require(report.warnings.first { $0.surface == "settings.json" })
        #expect(warning.detail.contains("apiKeyHelper") && warning.detail.contains("env.ANTHROPIC_API_KEY"))
        #expect(!warning.detail.contains("sk-ant-secret"))
    }

    @Test func authSettingsCopiedBeforeTheFilterAreRemovedOnTheNextSync() throws {
        let box = try Sandbox()
        let source = box.claudeHome.appendingPathComponent("settings.json")
        let target = box.base.appendingPathComponent("profile/settings.json")
        let record = box.base.appendingPathComponent("settings-sync.json")
        let defaults: [String: Any] = ["model": "opus", "apiKeyHelper": "helper", "env": ["ANTHROPIC_API_KEY": "k", "A": "1"]]
        try box.writeJSON(defaults, to: source)
        // An earlier, unfiltered sync: the profile holds the keys and the record their raw digests.
        try box.writeJSON(defaults, to: target)
        var data = FileOps.canonicalJSON(ClaudeSettingsSync.digest(defaults))
        data.append(0x0A)
        try data.write(to: record)

        _ = try ClaudeSettingsSync.sync(source: source, target: target, record: record)
        let synced = try readJSON(target)
        #expect(synced["apiKeyHelper"] == nil)
        #expect(synced["env"] as? [String: String] == ["A": "1"])
        #expect(synced["model"] as? String == "opus")
    }

    @Test func codexMirrorDropsAPIKeyLoginModes() async throws {
        let box = try Sandbox()
        try box.write("""
        model = "gpt-5"
        forced_login_method = "api"
        preferred_auth_method = "apikey"
        forced_chatgpt_workspace_id = "ws-1"
        cli_auth_credentials_store = "file"

        [profiles.work]
        preferred_auth_method = "apikey"
        model = "o3"
        """, to: box.codexHome.appendingPathComponent("config.toml"))
        let codex = CodexAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/codex"),
            environment: [:], shareSessions: false, runner: FakeCommandRunner())
        let home = try codex.createHome(accountID: UUID())
        let config = try readText(home.appendingPathComponent("config.toml"))
        #expect(!config.contains("forced_login_method"))
        #expect(!config.contains("preferred_auth_method"))
        #expect(config.contains("forced_chatgpt_workspace_id = \"ws-1\""))
        #expect(config.contains("cli_auth_credentials_store = \"file\""))
        #expect(config.contains("[profiles.work]\nmodel = \"o3\""))
        // A ChatGPT pin is not an API-key login and is kept.
        #expect(CodexConfigMirror.withoutAPIKeyLogin("forced_login_method = \"chatgpt\"\n") == "forced_login_method = \"chatgpt\"\n")
    }

    @Test func homesMirroredBeforeTheFilterAreMirroredAgain() async throws {
        let box = try Sandbox()
        let source = box.codexHome.appendingPathComponent("config.toml")
        try box.write("model = \"gpt-5\"\nforced_login_method = \"api\"\n", to: source)
        let codex = CodexAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/codex"),
            environment: [:], shareSessions: false, runner: FakeCommandRunner())
        let home = try codex.createHome(accountID: UUID())
        // Simulate an older Sevinda: unfiltered config and a record without a filter version.
        try box.write("model = \"gpt-5\"\nforced_login_method = \"api\"\n", to: home.appendingPathComponent("config.toml"))
        let record = home.deletingLastPathComponent().appendingPathComponent("config-mirror.json")
        var old = try readJSON(record)
        old.removeValue(forKey: "filterVersion")
        try box.writeJSON(old, to: record)
        try await codex.prepareForLaunch(home: home)
        #expect(!(try readText(home.appendingPathComponent("config.toml"))).contains("forced_login_method"))
    }
}
