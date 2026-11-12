import Foundation
import Testing
@testable import MercuryAccounts

@Suite struct ClaudeUsageTests {
    let now = Date(timeIntervalSince1970: 1_762_800_000)

    @Test func parsesPercentUtilizationAndResetFormats() throws {
        let json = """
        {"five_hour": {"utilization": 52.0, "resets_at": "2025-11-11T05:00:00.123456+00:00"},
         "seven_day": {"used_percentage": 7, "resets_at": 1762840000},
         "seven_day_opus": null, "limits": []}
        """
        let snapshot = try ClaudeUsageClient.parse(Data(json.utf8), fetchedAt: now)
        let five = try #require(snapshot.fiveHour)
        #expect(abs(five.usedFraction - 0.52) < 1e-9)
        #expect(five.resetsAt.map { abs($0.timeIntervalSince1970 - 1_762_837_200.123) < 0.01 } == true)
        let week = try #require(snapshot.sevenDay)
        #expect(abs(week.usedFraction - 0.07) < 1e-9)
        #expect(week.resetsAt == Date(timeIntervalSince1970: 1_762_840_000))
        #expect(snapshot.fetchedAt == now)
    }

    @Test func clampsAndToleratesMissingWindows() throws {
        let snapshot = try ClaudeUsageClient.parse(
            Data(#"{"five_hour": {"utilization": 140, "resets_at": 1762840000000}}"#.utf8), fetchedAt: now)
        #expect(snapshot.fiveHour?.usedFraction == 1)
        #expect(snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_762_840_000))
        #expect(snapshot.sevenDay == nil)
        #expect(throws: UsageError.invalidResponse) { try ClaudeUsageClient.parse(Data("[]".utf8), fetchedAt: now) }
    }

    @Test func providerSendsTheProfilesTokenWithClaudeHeaders() async throws {
        let box = try Sandbox()
        let transport = FakeTransport(json: #"{"five_hour": {"utilization": 10}}"#)
        let runner = FakeCommandRunner { call in
            call.arguments.first == "find-generic-password"
                ? CommandResult(exitCode: 0, stdout: Data(#"{"claudeAiOauth":{"accessToken":"tok-abc"}}"#.utf8), stderr: Data())
                : CommandResult(exitCode: 44, stdout: Data(), stderr: Data())
        }
        let provider = ClaudeAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/claude"),
            environment: ["USER": "tester"], runner: runner, transport: transport)
        let home = try provider.createHome(accountID: UUID())
        let snapshot = try await provider.usage(home: home)
        #expect(snapshot.fiveHour?.usedFraction == 0.1)
        let request = try #require(transport.recorded.first)
        #expect(request.url == ClaudeUsageClient.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-abc")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.timeoutInterval == 10)
        #expect(runner.recorded.allSatisfy { !$0.arguments.contains(ClaudeKeychainReader.defaultService) })
    }

    @Test func failuresAreTypedErrorsWithoutTokens() async throws {
        let client = ClaudeUsageClient(transport: FakeTransport(status: 401, json: "{}"))
        await #expect(throws: UsageError.unauthorized(status: 401)) { try await client.fetch(accessToken: "secret-token") }
        let server = ClaudeUsageClient(transport: FakeTransport(status: 500, json: "{}"))
        do {
            _ = try await server.fetch(accessToken: "secret-token")
            Issue.record("expected a failure")
        } catch {
            #expect(!error.localizedDescription.contains("secret-token"))
        }
    }

    @Test func signedOutProfileThrowsNotSignedIn() async throws {
        let box = try Sandbox()
        let provider = ClaudeAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/claude"),
            environment: ["USER": "tester"], runner: FakeCommandRunner(), transport: FakeTransport(json: "{}"))
        let home = try provider.createHome(accountID: UUID())
        await #expect(throws: UsageError.notSignedIn) { try await provider.usage(home: home) }
    }
}

@Suite struct CodexUsageTests {
    let now = Date(timeIntervalSince1970: 1_762_800_000)

    @Test func classifiesWindowsByLength() throws {
        let json = """
        {"plan_type": "plus", "rate_limit": {
          "primary_window": {"used_percent": 80, "limit_window_seconds": 604800, "reset_at": 1763400000},
          "secondary_window": {"used_percent": 12.5, "limit_window_seconds": 18000, "reset_at": 1762810000}}}
        """
        let snapshot = try CodexUsageClient.parse(Data(json.utf8), fetchedAt: now)
        #expect(snapshot.fiveHour == UsageWindow(usedFraction: 0.125, resetsAt: Date(timeIntervalSince1970: 1_762_810_000)))
        #expect(snapshot.sevenDay == UsageWindow(usedFraction: 0.8, resetsAt: Date(timeIntervalSince1970: 1_763_400_000)))
    }

    @Test func unknownLengthsKeepPrimaryAsSessionAndSecondaryAsWeekly() throws {
        let json = #"{"plan_type": "pro", "rate_limit": {"primary_window": {"used_percent": 3}, "secondary_window": {"used_percent": 4, "limit_window_seconds": 1}}}"#
        let snapshot = try CodexUsageClient.parse(Data(json.utf8), fetchedAt: now)
        #expect(snapshot.fiveHour?.usedFraction == 0.03)
        #expect(snapshot.sevenDay?.usedFraction == 0.04)
        #expect(snapshot.fiveHour?.resetsAt == nil)
    }

    @Test func rejectsResponsesWithoutAPlan() {
        #expect(throws: UsageError.invalidResponse) {
            try CodexUsageClient.parse(Data(#"{"rate_limit": {}}"#.utf8), fetchedAt: now)
        }
    }

    @Test func providerSendsBackendHeaders() async throws {
        let box = try Sandbox()
        let transport = FakeTransport(json: #"{"plan_type": "plus", "rate_limit": null}"#)
        let codex = CodexAccountProvider(
            dataRoot: box.dataRoot, realHome: box.realHome, executable: URL(fileURLWithPath: "/nonexistent/codex"),
            environment: [:], shareSessions: false, runner: FakeCommandRunner(), transport: transport)
        let home = try codex.createHome(accountID: UUID())
        await #expect(throws: UsageError.notSignedIn) { try await codex.usage(home: home) }
        try Data(#"{"tokens": {"access_token": "at-7", "account_id": "acct-7"}}"#.utf8)
            .write(to: home.appendingPathComponent("auth.json"))
        let snapshot = try await codex.usage(home: home)
        #expect(snapshot.fiveHour == nil && snapshot.sevenDay == nil)
        let request = try #require(transport.recorded.first)
        #expect(request.url == CodexUsageClient.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at-7")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-7")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1")
        #expect(request.value(forHTTPHeaderField: "originator") == "Codex Desktop")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "codex-cli")
    }
}
