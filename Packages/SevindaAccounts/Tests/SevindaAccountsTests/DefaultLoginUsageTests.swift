import Foundation
import SevindaCore
import Testing
@testable import SevindaAccounts

/// The user's own default login is only read: from a fake Keychain runner and files inside a sandbox home.
@Suite struct DefaultLoginUsageTests {
    static let claudeUsage = #"{"five_hour": {"utilization": 20}, "seven_day": {"utilization": 87}}"#
    static let codexUsage = #"{"plan_type": "plus", "rate_limit": {"primary_window": {"used_percent": 30, "limit_window_seconds": 18000}}}"#

    static func keychain(_ items: [String: String]) -> FakeCommandRunner {
        FakeCommandRunner { call in
            guard call.arguments.first == "find-generic-password",
                  let index = call.arguments.firstIndex(of: "-s"), let value = items[call.arguments[index + 1]]
            else { return CommandResult(exitCode: 44, stdout: Data(), stderr: Data()) }
            return CommandResult(exitCode: 0, stdout: Data(value.utf8), stderr: Data())
        }
    }

    static func oauth(_ token: String) -> String { #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"r"}}"# }

    @Test func claudeReadsTheUnsuffixedDefaultItem() async throws {
        let box = try Sandbox()
        let transport = FakeTransport(json: Self.claudeUsage)
        let runner = Self.keychain([ClaudeKeychainReader.defaultService: Self.oauth("default-tok")])
        let reader = DefaultLoginUsageReader(realHome: box.realHome, environment: ["USER": "tester"], runner: runner, transport: transport)
        let snapshot = try #require(try await reader.usage(.claude))
        #expect(snapshot.sevenDay?.usedFraction == 0.87)
        #expect(transport.recorded.first?.value(forHTTPHeaderField: "Authorization") == "Bearer default-tok")
        let call = try #require(runner.recorded.first)
        #expect(call.executable == "/usr/bin/security")
        #expect(call.arguments == ["find-generic-password", "-s", "Claude Code-credentials", "-a", "tester", "-w"])
        // Only reads: no delete or add command was ever issued.
        #expect(runner.recorded.allSatisfy { $0.arguments.first == "find-generic-password" })
    }

    @Test func claudeFallsBackToCredentialsFile() async throws {
        let box = try Sandbox()
        try box.write(Self.oauth("file-tok"), to: box.claudeHome.appendingPathComponent(".credentials.json"), mode: 0o600)
        let before = treeSnapshot(box.realHome)
        let transport = FakeTransport(json: Self.claudeUsage)
        let reader = DefaultLoginUsageReader(
            realHome: box.realHome, environment: ["USER": "tester"], runner: Self.keychain([:]), transport: transport)
        #expect(try await reader.usage(.claude) != nil)
        #expect(transport.recorded.first?.value(forHTTPHeaderField: "Authorization") == "Bearer file-tok")
        #expect(treeSnapshot(box.realHome) == before)
    }

    @Test func claudeWithoutLoginIsNilAndSendsNothing() async throws {
        let box = try Sandbox()
        // A JSON without an access token (API-key users) counts as no login.
        try box.write(#"{"claudeAiOauth":{}}"#, to: box.claudeHome.appendingPathComponent(".credentials.json"))
        let transport = FakeTransport(json: Self.claudeUsage)
        let reader = DefaultLoginUsageReader(
            realHome: box.realHome, environment: ["USER": "tester"], runner: Self.keychain([:]), transport: transport)
        #expect(try await reader.usage(.claude) == nil)
        #expect(transport.recorded.isEmpty)
    }

    @Test func claudeRespectsUserConfigDir() async throws {
        let box = try Sandbox()
        let configDir = box.base.appendingPathComponent("my-claude", isDirectory: true)
        try box.mkdir(configDir)
        let scoped = ClaudeKeychainReader.serviceName(configDir: configDir.path)
        let runner = Self.keychain([scoped: Self.oauth("scoped-tok"), ClaudeKeychainReader.defaultService: Self.oauth("default-tok")])
        let transport = FakeTransport(json: Self.claudeUsage)
        let reader = DefaultLoginUsageReader(
            realHome: box.realHome, environment: ["USER": "tester", "CLAUDE_CONFIG_DIR": configDir.path],
            runner: runner, transport: transport)
        _ = try await reader.usage(.claude)
        #expect(transport.recorded.first?.value(forHTTPHeaderField: "Authorization") == "Bearer scoped-tok")

        // Without a scoped item the unsuffixed item still belongs to the default login, then the folder's file.
        let fileOnly = DefaultLoginUsageReader(
            realHome: box.realHome, environment: ["USER": "tester", "CLAUDE_CONFIG_DIR": configDir.path],
            runner: Self.keychain([:]), transport: transport)
        try box.write(Self.oauth("dir-file-tok"), to: configDir.appendingPathComponent(".credentials.json"))
        try box.write(Self.oauth("home-file-tok"), to: box.claudeHome.appendingPathComponent(".credentials.json"))
        _ = try await fileOnly.usage(.claude)
        #expect(transport.recorded.last?.value(forHTTPHeaderField: "Authorization") == "Bearer dir-file-tok")
    }

    @Test func configDirResolution() {
        let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        #expect(ClaudeKeychainReader.defaultLoginConfigDir(environment: [:], realHome: home) == nil)
        #expect(ClaudeKeychainReader.defaultLoginConfigDir(environment: ["CLAUDE_CONFIG_DIR": "  "], realHome: home) == nil)
        #expect(ClaudeKeychainReader.defaultLoginConfigDir(environment: ["CLAUDE_CONFIG_DIR": "~/alt"], realHome: home)?.path == "/Users/x/alt")
        // A folder Mercury injected for a profile is not the user's own.
        let injected = ["CLAUDE_CONFIG_DIR": "/p/home", ClaudeLaunchEnv.injectedConfigDirEnv: "/p/home"]
        #expect(ClaudeKeychainReader.defaultLoginConfigDir(environment: injected, realHome: home) == nil)

        #expect(CodexIdentity.defaultLoginHome(environment: [:], realHome: home).path == "/Users/x/.codex")
        #expect(CodexIdentity.defaultLoginHome(environment: ["CODEX_HOME": "~/cx"], realHome: home).path == "/Users/x/cx")
        #expect(CodexIdentity.defaultLoginHome(environment: ["CODEX_HOME": "/opt/cx"], realHome: home).path == "/opt/cx")
        let injectedCodex = ["CODEX_HOME": "/a/home", CodexLaunchEnv.injectedHomeEnv: "/a/home"]
        #expect(CodexIdentity.defaultLoginHome(environment: injectedCodex, realHome: home).path == "/Users/x/.codex")
    }

    @Test func keychainFailureWithoutFileThrows() async throws {
        let box = try Sandbox()
        let locked = FakeCommandRunner { _ in CommandResult(exitCode: 36, stdout: Data(), stderr: Data("locked".utf8)) }
        let reader = DefaultLoginUsageReader(
            realHome: box.realHome, environment: ["USER": "tester"], runner: locked, transport: FakeTransport(json: "{}"))
        await #expect(throws: UsageError.keychainUnavailable) { try await reader.usage(.claude) }
    }

    @Test func codexReadsAuthJSONFromCodexHome() async throws {
        let box = try Sandbox()
        let codexHome = box.base.appendingPathComponent("cx", isDirectory: true)
        let idToken = "h.\(try base64URL(["email": "me@example.com"])).s"
        try box.writeJSON(["tokens": ["access_token": "codex-tok", "account_id": "acct-1", "id_token": idToken]],
                          to: codexHome.appendingPathComponent("auth.json"))
        let before = treeSnapshot(codexHome)
        let transport = FakeTransport(json: Self.codexUsage)
        let reader = DefaultLoginUsageReader(
            realHome: box.realHome, environment: ["CODEX_HOME": codexHome.path], runner: Self.keychain([:]), transport: transport)
        let snapshot = try #require(try await reader.usage(.codex))
        #expect(snapshot.fiveHour?.usedFraction == 0.3)
        let request = try #require(transport.recorded.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer codex-tok")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
        #expect(reader.identity(.codex)?.email == "me@example.com")
        #expect(treeSnapshot(codexHome) == before)
    }

    @Test func codexSignedOutOrAPIKeyIsNil() async throws {
        let box = try Sandbox()
        let transport = FakeTransport(json: Self.codexUsage)
        let reader = DefaultLoginUsageReader(realHome: box.realHome, environment: [:], runner: Self.keychain([:]), transport: transport)
        #expect(try await reader.usage(.codex) == nil)
        try box.writeJSON(["OPENAI_API_KEY": "sk-test"], to: box.codexHome.appendingPathComponent("auth.json"))
        #expect(try await reader.usage(.codex) == nil)
        #expect(reader.identity(.codex) == nil)
        #expect(transport.recorded.isEmpty)
    }

    @Test func profilesStillNeverReadTheDefaultItem() async throws {
        let box = try Sandbox()
        let runner = Self.keychain([ClaudeKeychainReader.defaultService: Self.oauth("default-tok")])
        let reader = ClaudeKeychainReader(runner: runner, environment: ["USER": "tester"])
        let profile = box.base.appendingPathComponent("profile", isDirectory: true)
        try box.mkdir(profile)
        #expect(try await reader.accessToken(configDir: profile) == nil)
        #expect(runner.recorded.allSatisfy { !$0.arguments.contains(ClaudeKeychainReader.defaultService) })
    }
}

@Suite struct UsageWindowExtrasTests {
    let now = Date(timeIntervalSince1970: 1_762_800_000)

    @Test func parsesTheModelScopedWeeklyLimit() throws {
        let json = """
        {"five_hour": null, "seven_day": {"utilization": 87, "resets_at": "2026-11-17T00:00:00.9+00:00"},
         "limits": [
          {"kind": "weekly_all", "percent": 87, "scope": null},
          {"kind": "weekly_scoped", "percent": 3, "scope": {"model": {"display_name": "Opus"}}},
          {"kind": "weekly_scoped", "percent": 14, "resets_at": "2026-11-16T23:59:59+00:00",
           "scope": {"model": {"id": null, "display_name": "Fable"}}}]}
        """
        let snapshot = try ClaudeUsageClient.parse(Data(json.utf8), fetchedAt: now)
        #expect(snapshot.fiveHour == nil)
        let model = try #require(snapshot.modelWeekly)
        #expect(model.model == "Fable")
        #expect(abs(model.window.usedFraction - 0.14) < 1e-9)
        #expect(model.window.resetsAt != nil)
    }

    @Test func modelWindowFallsBackToLegacyKeysOrNothing() throws {
        let legacy = try ClaudeUsageClient.parse(Data(#"{"seven_day_fable": {"utilization": 5}}"#.utf8), fetchedAt: now)
        #expect(legacy.modelWeekly?.model == "Fable")
        let none = try ClaudeUsageClient.parse(Data(#"{"seven_day": {"utilization": 5}, "limits": null}"#.utf8), fetchedAt: now)
        #expect(none.modelWeekly == nil)
    }

    @Test func rateLimitedCarriesRetryAfter() async throws {
        let transport = HeaderTransport(status: 429, headers: ["Retry-After": "120"])
        await #expect(throws: UsageError.rateLimited(retryAfter: 120)) {
            try await ClaudeUsageClient(transport: transport).fetch(accessToken: "t")
        }
        #expect(UsageHTTP.retryAfter("999999999") == UsageHTTP.maxRetryAfter)
        #expect(UsageHTTP.retryAfter("soon") == nil)
        #expect(UsageHTTP.retryAfter("Wed, 11 Nov 2026 00:02:00 GMT", now: Date(timeIntervalSince1970: 1_794_355_200)) == 120)
    }
}

/// Answers with a status and headers and an empty JSON body.
final class HeaderTransport: HTTPTransport {
    let status: Int
    let headers: [String: String]

    init(status: Int, headers: [String: String]) {
        self.status = status
        self.headers = headers
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}
