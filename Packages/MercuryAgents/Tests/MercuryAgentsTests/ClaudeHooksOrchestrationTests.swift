import Foundation
import Testing
@testable import MercuryAgents

/// The hook hands each event to the orchestration broker through `$MERCURY_CLI hook claude`, only in a terminal with a
/// session token, and never prints or fails.
@Suite struct ClaudeHooksOrchestrationTests {
    private func makeFakeCLI() throws -> (directory: URL, cli: URL, log: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hook-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("calls.log")
        let cli = directory.appendingPathComponent("mercury")
        // Records its arguments and stdin, and prints (the hook must swallow that).
        try "#!/bin/sh\nprintf '%s|' \"$@\" >> \"\(log.path)\"; cat >> \"\(log.path)\"; echo noise; echo err >&2; exit 7\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (directory, cli, log)
    }

    @Test func forwardsEventsWhenTheTerminalHasAToken() throws {
        let fake = try makeFakeCLI()
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let events = fake.directory.appendingPathComponent("events.jsonl")
        let env = ["PATH": "/usr/bin:/bin", "MERCURY_HOOK_EVENTS": events.path, "MERCURY_SESSION_TOKEN": "tok", "MERCURY_CLI": fake.cli.path]
        #expect(try runHookCommand(stdin: "{\"hook_event_name\":\"Stop\"}\n", environment: env) == 0)
        #expect(try String(contentsOf: fake.log, encoding: .utf8) == "hook|claude|{\"hook_event_name\":\"Stop\"}")
        #expect(try String(contentsOf: events, encoding: .utf8) == "{\"hook_event_name\":\"Stop\"}\n", "the app's events file still gets the line")
    }

    @Test func staysOutOfTheBrokerWithoutAToken() throws {
        let fake = try makeFakeCLI()
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let env = ["PATH": "/usr/bin:/bin", "MERCURY_CLI": fake.cli.path]
        #expect(try runHookCommand(stdin: "{\"hook_event_name\":\"Stop\"}", environment: env) == 0)
        #expect(!FileManager.default.fileExists(atPath: fake.log.path))
        let missingCLI = ["PATH": "/usr/bin:/bin", "MERCURY_SESSION_TOKEN": "tok", "MERCURY_CLI": "/nonexistent/mercury"]
        #expect(try runHookCommand(stdin: "{\"hook_event_name\":\"Stop\"}", environment: missingCLI) == 0)
    }

    @Test func settingsAllowTheMercuryCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try ClaudeHooks.install(dataRoot: root)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: installation.settingsFile)) as? [String: Any]
        let allow = (object?["permissions"] as? [String: Any])?["allow"] as? [String]
        #expect(allow == ["Bash(mercury:*)"])
    }
}
