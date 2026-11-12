import Foundation
import Testing
@testable import SevindaAccounts

@Suite struct ClaudeProfilePathTests {
    let id = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!

    @Test func acceptsHomeBelowTheDataRoot() throws {
        let box = try Sandbox()
        let store = ClaudeProfileStore(dataRoot: box.dataRoot, realHome: box.realHome)
        let home = store.home(for: id)
        #expect(home.path == box.dataRoot.path + "/claude-profiles/0f8fad5b-d9cb-469f-a165-70867728950e/home")
        try store.validate(home: home)
        #expect(store.accountID(forHome: home) == id)
    }

    @Test func rejectsPathsOutsideTheNamespace() throws {
        let box = try Sandbox()
        let store = ClaudeProfileStore(dataRoot: box.dataRoot, realHome: box.realHome)
        for path in ["/tmp/x/home", store.root.path + "/not-a-uuid/home", store.root.path + "/\(id.uuidString.lowercased())",
                     store.root.path + "/\(id.uuidString.lowercased())/home/../../x/home"] {
            #expect(throws: AccountsError.self) { try store.validate(home: URL(fileURLWithPath: path)) }
        }
    }

    @Test func rejectsProfilesNestedInDefaultClaudeHomes() throws {
        let box = try Sandbox()
        for dataRoot in [box.claudeHome.appendingPathComponent("mercury"),
                         box.realHome.appendingPathComponent(".config/claude/mercury")] {
            let store = ClaudeProfileStore(dataRoot: dataRoot, realHome: box.realHome)
            #expect(throws: AccountsError.self) { try store.validate(home: store.home(for: id)) }
        }
    }

    @Test func rejectsProfileEqualToOrContainingTheUserConfigDir() throws {
        let box = try Sandbox()
        let probe = ClaudeProfileStore(dataRoot: box.dataRoot, realHome: box.realHome)
        let home = probe.home(for: id)
        for userConfigDir in [home, home.appendingPathComponent("nested")] {
            let store = ClaudeProfileStore(dataRoot: box.dataRoot, realHome: box.realHome, userConfigDir: userConfigDir)
            #expect(throws: AccountsError.self) { try store.validate(home: home) }
        }
    }

    @Test func rejectsADataRootThatResolvesIntoDotClaude() throws {
        let box = try Sandbox()
        try box.mkdir(box.claudeHome)
        let link = box.base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: box.claudeHome)
        let store = ClaudeProfileStore(dataRoot: link, realHome: box.realHome)
        #expect(throws: AccountsError.self) { try store.validate(home: store.home(for: id)) }
    }

    @Test func rejectsSymlinkedComponentsBelowTheRoot() throws {
        let box = try Sandbox()
        let store = ClaudeProfileStore(dataRoot: box.dataRoot, realHome: box.realHome)
        let elsewhere = box.base.appendingPathComponent("elsewhere")
        try box.mkdir(elsewhere.appendingPathComponent("home"))
        try box.mkdir(store.root)
        try FileManager.default.createSymbolicLink(
            at: store.root.appendingPathComponent(id.uuidString.lowercased()), withDestinationURL: elsewhere)
        #expect(throws: AccountsError.self) { try store.validate(home: store.home(for: id)) }
        #expect(throws: AccountsError.self) { try store.prepareDirectory(accountID: id) }
    }

    @Test func markerIsWrittenOnlyAfterSetupAndChecksOwnership() throws {
        let box = try Sandbox()
        let store = ClaudeProfileStore(dataRoot: box.dataRoot, realHome: box.realHome)
        let (home, markSetUp) = try store.prepareDirectory(accountID: id)
        #expect(try posixMode(home) == 0o700)
        #expect(!store.isSetUp(home: home))
        try markSetUp()
        #expect(store.isSetUp(home: home))
        let marker = store.markerFile(forHome: home)
        #expect(try posixMode(marker) == 0o600)
        #expect(try readJSON(marker)["accountId"] as? String == id.uuidString.lowercased())

        try box.writeJSON(["version": 1, "accountId": "someone-else", "runtime": "host"], to: marker)
        #expect(throws: AccountsError.self) { try store.prepareDirectory(accountID: id) }
    }
}

@Suite struct ClaudeProvisioningTests {
    let id = UUID()

    /// A default home with every kind of entry provisioning distinguishes.
    func seedDefaultHome(_ box: Sandbox) throws {
        try box.mkdir(box.claudeHome.appendingPathComponent("skills/review"))
        try box.write("skill", to: box.claudeHome.appendingPathComponent("skills/review/SKILL.md"))
        try box.mkdir(box.claudeHome.appendingPathComponent("agents"))
        try box.write("# memory", to: box.claudeHome.appendingPathComponent("CLAUDE.md"))
        try box.write("#!/bin/sh\necho status", to: box.claudeHome.appendingPathComponent("statusline.sh"), mode: 0o755)
        try box.write("secret", to: box.claudeHome.appendingPathComponent(".credentials.json"), mode: 0o600)
        try box.write("{}", to: box.claudeHome.appendingPathComponent("history.jsonl"))
        try box.mkdir(box.claudeHome.appendingPathComponent("projects/-tmp-x"))
        try box.mkdir(box.claudeHome.appendingPathComponent("todos"))
        try box.mkdir(box.claudeHome.appendingPathComponent("statsig"))
        try box.mkdir(box.claudeHome.appendingPathComponent("agent-memory-x"))
        try box.write("log", to: box.claudeHome.appendingPathComponent("daemon.log"))
        try box.writeJSON(["theme": "dark", "model": "opus"], to: box.claudeHome.appendingPathComponent("settings.json"))
        try box.writeJSON([
            "oauthAccount": ["emailAddress": "me@example.com"], "userID": "u1", "machineID": "m1",
            "primaryApiKey": "sk-ant-x", "groveConfigCache": [:], "cachedChangelog": "c", "passesEligibility": true,
            "claudeCodeFirstTokenDate": "2025", "numStartups": 3, "theme": "dark",
            "projects": ["/repo/a": ["allowedTools": ["Bash"], "hasTrustDialogAccepted": false]],
            "mcpServers": ["shared": ["command": "x"]],
        ], to: box.realHome.appendingPathComponent(".claude.json"))
    }

    @Test func sharesFoldersCopiesFilesAndKeepsRuntimeStatePrivate() throws {
        let box = try Sandbox()
        try seedDefaultHome(box)
        let before = treeSnapshot(box.realHome)
        let provider = ClaudeAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/claude"),
            environment: [:], runner: FakeCommandRunner())
        let (home, report) = try provider.setUpProfile(accountID: id)

        #expect(symlinkTarget(home.appendingPathComponent("skills")) == box.claudeHome.appendingPathComponent("skills").path)
        #expect(symlinkTarget(home.appendingPathComponent("agents")) == box.claudeHome.appendingPathComponent("agents").path)
        #expect(try readText(home.appendingPathComponent("CLAUDE.md")) == "@~/.claude/CLAUDE.md\n")
        #expect(try readText(home.appendingPathComponent("statusline.sh")) == "#!/bin/sh\necho status")
        #expect(try posixMode(home.appendingPathComponent("statusline.sh")) == 0o700)
        for privateEntry in [".credentials.json", "history.jsonl", "projects", "todos", "statsig", "agent-memory-x",
                             "daemon.log"] {
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(privateEntry).path), "\(privateEntry)")
        }
        #expect(report.surfaces["settings.json"] == .synced)
        #expect(try readJSON(home.appendingPathComponent("settings.json"))["model"] as? String == "opus")
        #expect(try posixMode(home.appendingPathComponent("settings.json")) == 0o600)

        let state = try readJSON(home.appendingPathComponent(".claude.json"))
        for key in ["oauthAccount", "userID", "machineID", "primaryApiKey", "groveConfigCache", "cachedChangelog",
                    "passesEligibility", "claudeCodeFirstTokenDate"] {
            #expect(state[key] == nil, "\(key) must not be shared")
        }
        #expect(state["numStartups"] as? Int == 3)
        #expect(try posixMode(home.appendingPathComponent(".claude.json")) == 0o600)
        #expect(provider.store.isSetUp(home: home))
        // The default home is only read.
        #expect(treeSnapshot(box.realHome) == before)
    }

    @Test func customConfigDirCopiesClaudeMdInsteadOfImporting() throws {
        let box = try Sandbox()
        let custom = box.base.appendingPathComponent("custom-claude")
        try box.write("# custom memory", to: custom.appendingPathComponent("CLAUDE.md"))
        let provider = ClaudeAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, userConfigDir: custom,
            executable: URL(fileURLWithPath: "/nonexistent/claude"), environment: [:], runner: FakeCommandRunner())
        let home = try provider.createHome(accountID: id)
        #expect(try readText(home.appendingPathComponent("CLAUDE.md")) == "# custom memory")
    }

    @Test func mergesProjectsAndServersKeepingTheProfilesOwn() async throws {
        let box = try Sandbox()
        try seedDefaultHome(box)
        let provider = ClaudeAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/claude"),
            environment: [:], runner: FakeCommandRunner())
        let home = try provider.createHome(accountID: id)
        let stateURL = home.appendingPathComponent(".claude.json")

        // Claude, running in the profile, trusted a folder, added a server and signed in.
        var state = try readJSON(stateURL)
        state["projects"] = ["/repo/a": ["hasTrustDialogAccepted": true], "/repo/own": ["allowedTools": []]]
        state["mcpServers"] = ["mine": ["command": "y"]]
        state["oauthAccount"] = ["emailAddress": "profile@example.com"]
        state["groveChoiceSeenAt"] = ["acct": 200]
        try box.writeJSON(state, to: stateURL)

        // The user changed their own state meanwhile.
        var source = try readJSON(box.realHome.appendingPathComponent(".claude.json"))
        source["projects"] = ["/repo/a": ["allowedTools": ["Edit"], "hasTrustDialogAccepted": false],
                              "/repo/b": ["allowedTools": []]]
        source["groveChoiceSeenAt"] = ["acct": 100, "other": 5]
        source["numStartups"] = 9
        try box.writeJSON(source, to: box.realHome.appendingPathComponent(".claude.json"))

        try await provider.prepareForLaunch(home: home)
        let merged = try readJSON(stateURL)
        let projects = try #require(merged["projects"] as? [String: [String: Any]])
        #expect(projects["/repo/a"]?["hasTrustDialogAccepted"] as? Bool == true)
        #expect(projects["/repo/a"]?["allowedTools"] as? [String] == ["Edit"])
        #expect(projects["/repo/b"] != nil)
        #expect(projects["/repo/own"] != nil)
        let servers = try #require(merged["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["mine", "shared"])
        #expect((merged["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "profile@example.com")
        let grove = try #require(merged["groveChoiceSeenAt"] as? [String: Int])
        #expect(grove == ["acct": 200, "other": 5])
        #expect(merged["numStartups"] as? Int == 9)
    }

    @Test func identityComesFromTheProfilesOwnState() async throws {
        let box = try Sandbox()
        let provider = ClaudeAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/claude"),
            environment: [:], runner: FakeCommandRunner())
        let home = try provider.createHome(accountID: id)
        #expect(await provider.identity(home: home) == nil)
        try box.writeJSON(["oauthAccount": [
            "emailAddress": " a@b.co ", "organizationName": "Acme", "organizationUuid": "org-1", "accountUuid": "acc-1",
        ]], to: home.appendingPathComponent(".claude.json"))
        #expect(await provider.identity(home: home) == AccountIdentity(email: "a@b.co", organization: "Acme", accountID: "acc-1"))
    }

    @Test func userOwnedEntriesInTheProfileAreLeftAlone() throws {
        let box = try Sandbox()
        try seedDefaultHome(box)
        let provider = ClaudeAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/claude"),
            environment: [:], runner: FakeCommandRunner())
        let home = provider.store.home(for: id)
        try box.write("mine", to: home.appendingPathComponent("agents/own.md"))
        let (_, report) = try provider.setUpProfile(accountID: id)
        #expect(report.surfaces["agents"] == .userOwned)
        #expect(try readText(home.appendingPathComponent("agents/own.md")) == "mine")
    }

    @Test func removeHomeSignsOutDeletesProfileKeychainItemsAndKeepsSharedTargets() async throws {
        let box = try Sandbox()
        try seedDefaultHome(box)
        let runner = FakeCommandRunner { _ in CommandResult(exitCode: 44, stdout: Data(), stderr: Data()) }
        let claude = try box.script("claude", "exit 0")
        let provider = ClaudeAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: claude, environment: ["USER": "tester"],
            runner: runner)
        let home = try provider.createHome(accountID: id)
        try provider.writePointer(home: home)
        try await provider.removeHome(home)

        #expect(!FileManager.default.fileExists(atPath: home.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: box.claudeHome.appendingPathComponent("skills/review/SKILL.md").path))
        #expect(!FileManager.default.fileExists(atPath: provider.store.pointerFile.path))
        let calls = runner.recorded
        #expect(calls.first?.arguments == ["auth", "logout"])
        #expect(calls.first?.environment?["CLAUDE_CONFIG_DIR"] == home.path)
        let deletes = calls.filter { $0.arguments.first == "delete-generic-password" }
        #expect(!deletes.isEmpty)
        #expect(deletes.allSatisfy { $0.arguments[2] != ClaudeKeychainReader.defaultService })
        #expect(deletes.contains { $0.arguments[2] == ClaudeKeychainReader.serviceName(configDir: home.path) })
    }
}

@Suite struct ClaudeSettingsSyncTests {
    @Test func appliesOnlyKeysTheDefaultHomeChangedSinceTheLastSync() throws {
        let box = try Sandbox()
        let source = box.claudeHome.appendingPathComponent("settings.json")
        let target = box.base.appendingPathComponent("profile/settings.json")
        let record = box.base.appendingPathComponent("settings-sync.json")
        try box.mkdir(target.deletingLastPathComponent())

        try box.writeJSON(["theme": "dark", "model": "opus", "env": ["A": "1"], "old": true], to: source)
        #expect(try ClaudeSettingsSync.sync(source: source, target: target, record: record).outcome == .synced)
        #expect(try readJSON(target)["model"] as? String == "opus")
        // Digests only: no setting value lands in the record.
        #expect(!(try readText(record)).contains("opus"))

        // Claude saved `/model` inside the profile; an unchanged default must not revert it.
        var profile = try readJSON(target)
        profile["model"] = "sonnet"
        profile["profileOnly"] = 1
        try box.writeJSON(profile, to: target)
        #expect(try ClaudeSettingsSync.sync(source: source, target: target, record: record).outcome == .unchanged)
        #expect(try readJSON(target)["model"] as? String == "sonnet")

        // The user changes theme and drops a key: both apply; the profile's own choices stay.
        try box.writeJSON(["theme": "light", "model": "opus", "env": ["A": "1"]], to: source)
        #expect(try ClaudeSettingsSync.sync(source: source, target: target, record: record).outcome == .synced)
        var synced = try readJSON(target)
        #expect(synced["theme"] as? String == "light")
        #expect(synced["model"] as? String == "sonnet")
        #expect(synced["old"] == nil)
        #expect(synced["profileOnly"] as? Int == 1)

        // Changing the same key in the default home wins.
        try box.writeJSON(["theme": "light", "model": "haiku", "env": ["A": "1"]], to: source)
        _ = try ClaudeSettingsSync.sync(source: source, target: target, record: record)
        synced = try readJSON(target)
        #expect(synced["model"] as? String == "haiku")
    }

    @Test func withoutARecordTheDefaultHomeWinsAndBrokenCopiesAreReplaced() throws {
        let box = try Sandbox()
        let source = box.claudeHome.appendingPathComponent("settings.json")
        let target = box.base.appendingPathComponent("profile/settings.json")
        let record = box.base.appendingPathComponent("settings-sync.json")
        try box.writeJSON(["theme": "dark"], to: source)
        try box.write("{ not json", to: target)
        #expect(try ClaudeSettingsSync.sync(source: source, target: target, record: record).outcome == .synced)
        #expect(try readJSON(target) as NSDictionary == ["theme": "dark"] as NSDictionary)
    }

    @Test func symlinkedProfileSettingsAreUserOwned() throws {
        let box = try Sandbox()
        let source = box.claudeHome.appendingPathComponent("settings.json")
        try box.writeJSON(["theme": "dark"], to: source)
        let target = box.base.appendingPathComponent("profile/settings.json")
        try box.mkdir(target.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
        #expect(try ClaudeSettingsSync.sync(source: source, target: target, record: box.base.appendingPathComponent("r.json")).outcome
            == .userOwned)
    }
}
