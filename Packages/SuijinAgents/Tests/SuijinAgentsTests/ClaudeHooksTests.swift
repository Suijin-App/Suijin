import Foundation
import Synchronization
import Testing
@testable import SuijinAgents

/// Runs the hook command exactly as Claude would: through a shell, with the hook JSON on stdin.
func runHookCommand(stdin: String, environment: [String: String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", ClaudeHooks.hookCommand]
    process.environment = environment
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    let printed = output.fileHandleForReading.readDataToEndOfFile()
    #expect(printed.isEmpty, "hook must print nothing")
    return process.terminationStatus
}

@Suite struct ClaudeHooksTests {
    @Test func installWritesValidSettings() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try ClaudeHooks.install(dataRoot: root)
        #expect(installation.settingsFile.path == root.appendingPathComponent("hooks/claude-settings.json").path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: installation.eventsDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue)

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: installation.settingsFile))
        let hooks = try #require((object as? [String: Any])?["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["Notification", "Stop", "UserPromptSubmit", "SessionStart"])
        for (_, value) in hooks {
            let groups = try #require(value as? [[String: Any]])
            #expect(groups.count == 1)
            let handlers = try #require(groups[0]["hooks"] as? [[String: Any]])
            #expect(handlers.count == 1)
            #expect(handlers[0]["type"] as? String == "command")
            #expect(handlers[0]["command"] as? String == ClaudeHooks.hookCommand)
            #expect(handlers[0]["timeout"] as? Int == 10)
        }
    }

    func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    @Test func eventStorageIsPrivate() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hooksDirectory = root.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let installation = try ClaudeHooks.install(dataRoot: root)
        #expect(try permissions(hooksDirectory) == 0o700, "an existing directory is tightened")
        #expect(try permissions(installation.eventsDirectory) == 0o700)

        let prepared = UUID()
        let url = try installation.prepareEventsFile(sessionID: prepared)
        #expect(url == installation.eventsFile(sessionID: prepared))
        #expect(try permissions(url) == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try installation.prepareEventsFile(sessionID: prepared)
        #expect(try permissions(url) == 0o600, "an existing file is tightened")

        // A file the hook creates itself (no pre-creation) is 0600 even under a permissive umask.
        let hookCreated = installation.eventsFile(sessionID: UUID())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "umask 000; printf '%s' '{\"hook_event_name\":\"Stop\"}' | \(ClaudeHooks.hookCommand)"]
        process.environment = ["SUIJIN_HOOK_EVENTS": hookCreated.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try permissions(hookCreated) == 0o600)
        #expect(ClaudeHooks.parseEvents(try Data(contentsOf: hookCreated)).map(\.name) == ["Stop"])
    }

    @Test func installIsIdempotent() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ClaudeHooks.install(dataRoot: root)
        let before = try Data(contentsOf: first.settingsFile)
        let modified = try FileManager.default.attributesOfItem(atPath: first.settingsFile.path)[.modificationDate] as? Date
        let second = try ClaudeHooks.install(dataRoot: root)
        #expect(first == second)
        #expect(try Data(contentsOf: second.settingsFile) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: second.settingsFile.path)[.modificationDate] as? Date == modified)

        try Data("{}".utf8).write(to: first.settingsFile)
        try ClaudeHooks.install(dataRoot: root)
        #expect(try Data(contentsOf: first.settingsFile) == before)
    }

    @Test func installationPathsAndEnv() throws {
        let installation = ClaudeHooks.Installation(
            settingsFile: URL(fileURLWithPath: "/d/hooks/claude-settings.json"),
            eventsDirectory: URL(fileURLWithPath: "/d/hooks/events", isDirectory: true))
        let id = UUID()
        #expect(installation.eventsFile(sessionID: id).path == "/d/hooks/events/\(id.uuidString).jsonl")
        let env = installation.env(sessionID: id)
        #expect(env.set["SUIJIN_HOOK_EVENTS"] == installation.eventsFile(sessionID: id).path)
        #expect(env.set["SUIJIN_SESSION_ID"] == id.uuidString)
        #expect(env.unset.isEmpty)
        // A shell also gets the settings file its `claude` function passes with `--settings`.
        let shell = installation.shellEnv(sessionID: id)
        #expect(shell.set["SUIJIN_CLAUDE_SETTINGS"] == "/d/hooks/claude-settings.json")
        #expect(shell.set["SUIJIN_HOOK_EVENTS"] == env.set["SUIJIN_HOOK_EVENTS"])
        #expect(shell.unset.isEmpty)
    }

    @Test func hookCommandAppendsOneLinePerEvent() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = root.appendingPathComponent("events/session.jsonl")
        try FileManager.default.createDirectory(at: events.deletingLastPathComponent(), withIntermediateDirectories: true)
        let env = ["SUIJIN_HOOK_EVENTS": events.path, "PATH": "/usr/bin:/bin"]

        let pretty = "{\n  \"hook_event_name\": \"Notification\",\n  \"message\": \"Claude needs your permission to use Bash\",\n  \"notification_type\": \"permission_prompt\"\n}\n"
        #expect(try runHookCommand(stdin: pretty, environment: env) == 0)
        #expect(try runHookCommand(stdin: #"{"hook_event_name":"Stop","session_id":"x's \"quoted\""}"#, environment: env) == 0)
        #expect(try runHookCommand(stdin: "", environment: env) == 0)

        let content = try String(contentsOf: events, encoding: .utf8)
        #expect(content.split(separator: "\n").count == 2)
        #expect(content.hasSuffix("\n"))
        #expect(ClaudeHooks.parseEvents(Data(content.utf8)) == [
            ClaudeHookEvent(name: "Notification", message: "Claude needs your permission to use Bash", notificationType: "permission_prompt"),
            ClaudeHookEvent(name: "Stop"),
        ])
    }

    @Test func hookCommandIsInertWithoutEnvironment() throws {
        #expect(try runHookCommand(stdin: #"{"hook_event_name":"Stop"}"#, environment: ["PATH": "/usr/bin:/bin"]) == 0)
        #expect(try runHookCommand(stdin: #"{"hook_event_name":"Stop"}"#, environment: ["PATH": "/usr/bin:/bin", "SUIJIN_HOOK_EVENTS": ""]) == 0)
    }

    @Test func hookCommandNeverFails() throws {
        let env = ["SUIJIN_HOOK_EVENTS": "/nonexistent-dir-\(UUID().uuidString)/x.jsonl", "PATH": "/usr/bin:/bin"]
        #expect(try runHookCommand(stdin: #"{"hook_event_name":"Stop"}"#, environment: env) == 0)
    }

    @Test func parseEventsToleratesGarbageAndPartialLines() {
        let data = Data("""
        {"hook_event_name":"SessionStart","source":"startup"}

        not json
        {"no_name":true}
        ["array"]
        {"hook_event_name":"UserPromptSubmit","prompt":"hi"}
        {"hook_event_name":"Stop","sess
        """.utf8)
        #expect(ClaudeHooks.parseEvents(data).map(\.name) == ["SessionStart", "UserPromptSubmit"])
        #expect(ClaudeHooks.parseEvents(Data()).isEmpty)
    }
}

@Suite struct HookEventWatcherTests {
    final class Collector: Sendable {
        let events = Mutex<[ClaudeHookEvent]>([])
        func append(_ new: [ClaudeHookEvent]) { events.withLock { $0 += new } }
        var names: [String] { events.withLock { $0.map(\.name) } }

        func wait(forCount count: Int, timeout: TimeInterval = 5) async -> [String] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if names.count >= count { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return names
        }
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func picksUpAppendedLinesAndWaitsForPartialOnes() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("s.jsonl")
        try Data(#"{"hook_event_name":"SessionStart"}"#.utf8 + [0x0A]).write(to: file)
        let collector = Collector()
        let watcher = HookEventWatcher(fileURL: file) { collector.append($0) }
        watcher.start()
        defer { watcher.stop() }

        #expect(await collector.wait(forCount: 1) == ["SessionStart"])
        try append(#"{"hook_event_name":"UserPromptSubmit"}"# + "\n" + #"{"hook_event_name":"No"#, to: file)
        #expect(await collector.wait(forCount: 2) == ["SessionStart", "UserPromptSubmit"])
        try append(#"tification","message":"waiting"}"# + "\n", to: file)
        #expect(await collector.wait(forCount: 3) == ["SessionStart", "UserPromptSubmit", "Notification"])
        #expect(collector.events.withLock { $0.last?.message } == "waiting")
    }

    @Test func handlesFileCreatedLater() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events/later.jsonl")
        let collector = Collector()
        let watcher = HookEventWatcher(fileURL: file) { collector.append($0) }
        watcher.start()
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(100))
        #expect(try runHookCommand(stdin: #"{"hook_event_name":"Stop"}"#, environment: ["SUIJIN_HOOK_EVENTS": file.path, "PATH": "/usr/bin:/bin"]) == 0)
        #expect(await collector.wait(forCount: 1) == ["Stop"])
        try append(#"{"hook_event_name":"Notification"}"# + "\n", to: file)
        #expect(await collector.wait(forCount: 2) == ["Stop", "Notification"])
    }

    @Test func handlesTruncationAndRecreation() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("t.jsonl")
        try Data((#"{"hook_event_name":"SessionStart","padding":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}"# + "\n").utf8).write(to: file)
        let collector = Collector()
        let watcher = HookEventWatcher(fileURL: file) { collector.append($0) }
        watcher.start()
        defer { watcher.stop() }
        #expect(await collector.wait(forCount: 1) == ["SessionStart"])

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.close()
        try await Task.sleep(for: .milliseconds(100))
        try append(#"{"hook_event_name":"Stop"}"# + "\n", to: file)
        #expect(await collector.wait(forCount: 2) == ["SessionStart", "Stop"])

        try FileManager.default.removeItem(at: file)
        try await Task.sleep(for: .milliseconds(100))
        try Data((#"{"hook_event_name":"UserPromptSubmit"}"# + "\n").utf8).write(to: file)
        #expect(await collector.wait(forCount: 3) == ["SessionStart", "Stop", "UserPromptSubmit"])
    }

    @Test func readExistingFalseSkipsHistory() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("h.jsonl")
        try Data((#"{"hook_event_name":"SessionStart"}"# + "\n").utf8).write(to: file)
        let collector = Collector()
        let watcher = HookEventWatcher(fileURL: file, readExisting: false) { collector.append($0) }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(100))
        try append(#"{"hook_event_name":"Stop"}"# + "\n", to: file)
        #expect(await collector.wait(forCount: 1) == ["Stop"])
    }

    @Test func stopEndsDelivery() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("x.jsonl")
        try Data().write(to: file)
        let collector = Collector()
        let watcher = HookEventWatcher(fileURL: file) { collector.append($0) }
        watcher.start()
        try await Task.sleep(for: .milliseconds(100))
        watcher.stop()
        try append(#"{"hook_event_name":"Stop"}"# + "\n", to: file)
        try await Task.sleep(for: .milliseconds(200))
        #expect(collector.names.isEmpty)
    }
}
