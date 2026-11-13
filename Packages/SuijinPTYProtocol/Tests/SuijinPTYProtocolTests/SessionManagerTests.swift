import Foundation
import SuijinPTYHostKit
import SuijinPTYProtocol
import Synchronization
import Testing

@Suite("SessionManager")
struct SessionManagerTests {
    @Test func defaultMetadataDirectoryHonoursDataRootOverride() {
        let custom = SessionManager.defaultMetadataDirectory(environment: ["SUIJIN_DATA_ROOT": "/tmp/suijin-root"])
        #expect(custom.path == "/tmp/suijin-root/pty-host/sessions")
        let standard = SessionManager.defaultMetadataDirectory(environment: [:])
        #expect(standard.path.hasSuffix("Library/Application Support/Suijin/pty-host/sessions"))
    }

    @Test func persistsMetadataAndFlagsLeftoversAsNotRunning() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager(configuration: .init(metadataDirectory: directory))
        manager.start()

        var request = shellRequest("echo done")
        request.metadata = ["agentSession": "abc"]
        let info = try manager.spawn(request)
        let file = directory.appendingPathComponent("\(info.id).json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await manager.session(info.id)?.waitForExit() == 0)
        try await waitUntil {
            (try? String(contentsOf: file, encoding: .utf8))?.contains(#""isRunning":false"#) == true
        }

        // A record claiming to be running, left by a crashed helper.
        let orphanID = UUID().uuidString
        let orphan = """
        {"info":{"id":"\(orphanID)","pid":99999,"executable":"/bin/zsh","cwd":"/","startedAt":"2026-01-01T00:00:00Z",
        "isRunning":true,"metadata":{}}}
        """
        try Data(orphan.utf8).write(to: directory.appendingPathComponent("\(orphanID).json"))

        let restarted = SessionManager(configuration: .init(metadataDirectory: directory))
        restarted.start()
        let listed = restarted.listSessions()
        #expect(listed.count == 2)
        let previous = try #require(listed.first { $0.id == info.id })
        #expect(previous.isRunning == false)
        #expect(previous.exitStatus == 0)
        #expect(previous.metadata == ["agentSession": "abc"])
        let leftover = try #require(listed.first { $0.id == orphanID })
        #expect(leftover.isRunning == false)
        #expect(leftover.exitStatus == nil)
        #expect(restarted.session(orphanID) == nil, "leftovers are informative only")
    }

    @Test func reapsExitedUnattachedSessions() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = SessionManager.Configuration(metadataDirectory: directory)
        configuration.exitedRetention = 3600
        let manager = SessionManager(configuration: configuration)
        manager.start()
        let client = UUID()
        manager.clientConnected(client)

        let info = try manager.spawn(shellRequest("true"))
        let sink = CollectingSink()
        #expect(manager.attach(sessionID: info.id, clientID: client, sink: sink) { _, _ in })
        #expect(await sink.collector.waitForExit() == 0)

        manager.reap(now: Date().addingTimeInterval(7200))
        #expect(manager.session(info.id) != nil, "an attached session is kept")

        manager.detach(sessionID: info.id, clientID: client)
        manager.reap(now: Date())
        #expect(manager.session(info.id) != nil, "retention window not over yet")
        manager.reap(now: Date().addingTimeInterval(7200))
        #expect(manager.session(info.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(info.id).json").path))
    }

    @Test func firesIdleOnlyWithoutRunningSessionsAndClients() async throws {
        let idleCount = Mutex(0)
        var configuration = SessionManager.Configuration(metadataDirectory: nil)
        configuration.idleGrace = 0.1
        let manager = SessionManager(configuration: configuration) { idleCount.withLock { $0 += 1 } }
        let client = UUID()
        manager.clientConnected(client)
        manager.start()

        let info = try manager.spawn(PTYSpawnRequest(executable: "/bin/sleep", arguments: ["100"], cwd: "/"))
        manager.clientDisconnected(client)
        try await Task.sleep(for: .milliseconds(300))
        #expect(idleCount.withLock { $0 } == 0, "a running session keeps the helper alive")

        let status = await withCheckedContinuation { continuation in
            manager.terminate(sessionID: info.id) { continuation.resume(returning: $0) }
        }
        #expect(status == 128 + SIGHUP)
        try await waitUntil { idleCount.withLock { $0 } == 1 }

        manager.shutdownIfIdle()
        try await waitUntil { idleCount.withLock { $0 } == 2 }
    }

    @Test func shutdownIfIdleIsIgnoredWhileSessionsRun() async throws {
        let idleCount = Mutex(0)
        let manager = SessionManager(configuration: .init(metadataDirectory: nil)) { idleCount.withLock { $0 += 1 } }
        manager.start()
        let info = try manager.spawn(PTYSpawnRequest(executable: "/bin/sleep", arguments: ["100"], cwd: "/"))
        manager.shutdownIfIdle()
        try await Task.sleep(for: .milliseconds(200))
        #expect(idleCount.withLock { $0 } == 0)
        manager.terminate(sessionID: info.id)
        _ = await manager.session(info.id)?.waitForExit()
    }
}

func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("condition not met within \(timeout)s")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
