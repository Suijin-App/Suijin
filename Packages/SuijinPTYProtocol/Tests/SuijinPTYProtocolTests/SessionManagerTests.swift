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

    @Test func terminatedSessionIsForgottenOnceItsClientHasTheExit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = SessionManager.Configuration(metadataDirectory: directory)
        configuration.sessionTuning.killGrace = 0.2
        let manager = SessionManager(configuration: configuration)
        manager.start()
        let client = UUID()
        manager.clientConnected(client)

        let info = try manager.spawn(PTYSpawnRequest(executable: "/bin/cat", cwd: "/"))
        let file = directory.appendingPathComponent("\(info.id).json")
        let sink = CollectingSink()
        #expect(manager.attach(sessionID: info.id, clientID: client, sink: sink) { _, _ in })

        manager.terminate(sessionID: info.id)
        #expect(await sink.collector.waitForExit() == 128 + SIGHUP)
        try await waitUntil { manager.session(info.id) == nil }
        #expect(manager.listSessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func terminatingAnEndedSessionForgetsIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager(configuration: .init(metadataDirectory: directory))
        manager.start()

        let info = try manager.spawn(shellRequest("echo bye"))
        #expect(await manager.session(info.id)?.waitForExit() == 0)
        try await waitUntil { manager.session(info.id)?.isSettled == true }
        #expect(manager.listSessions().map(\.id) == [info.id], "a session that ended on its own is kept")

        manager.terminate(sessionID: info.id)
        try await waitUntil { manager.session(info.id) == nil }
        #expect(manager.listSessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(info.id).json").path))
    }

    @Test func endingWithoutForgettingKeepsTheSessionForTheApp() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = SessionManager.Configuration(metadataDirectory: directory)
        configuration.sessionTuning.killGrace = 0.2
        let manager = SessionManager(configuration: configuration)
        manager.start()
        let client = UUID()
        manager.clientConnected(client)

        let info = try manager.spawn(shellRequest("echo last words; sleep 100"))
        let session = try #require(manager.session(info.id))
        try await waitUntil { session.scrollbackSnapshot().contains(text: "last words") }
        let status = await withCheckedContinuation { continuation in
            manager.terminate(sessionID: info.id, forget: false) { continuation.resume(returning: $0) }
        }
        #expect(status == 128 + SIGHUP)
        try await waitUntil { session.isSettled }
        #expect(manager.listSessions().first { $0.id == info.id }?.exitStatus == 128 + SIGHUP)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(info.id).json").path))

        // The app, back later, reads the end of the output and the status, then lets the session go.
        let sink = CollectingSink()
        let attached = manager.attach(sessionID: info.id, clientID: client, sink: sink) { scrollback, _ in
            sink.collector.append(scrollback)
        }
        #expect(attached)
        #expect(await sink.collector.waitForExit() == 128 + SIGHUP)
        #expect(sink.collector.text.contains("last words"))
        manager.terminate(sessionID: info.id)
        try await waitUntil { manager.session(info.id) == nil }
    }

    @Test func terminatingARecordOfAPreviousHelperDeletesIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        let record = """
        {"info":{"id":"\(id)","pid":99999,"executable":"/bin/zsh","cwd":"/","startedAt":"2026-01-01T00:00:00Z",
        "isRunning":false,"metadata":{}},"endedAt":"\(ISO8601DateFormatter().string(from: Date()))"}
        """
        let file = directory.appendingPathComponent("\(id).json")
        try Data(record.utf8).write(to: file)
        let manager = SessionManager(configuration: .init(metadataDirectory: directory))
        manager.start()
        #expect(manager.listSessions().map(\.id) == [id])

        let status = await withCheckedContinuation { continuation in
            manager.terminate(sessionID: id) { continuation.resume(returning: $0) }
        }
        #expect(status == -1)
        #expect(manager.listSessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func terminatedSessionIsKeptUntilASlowClientHasEverything() async throws {
        var configuration = SessionManager.Configuration(metadataDirectory: nil)
        // A one-byte window: the client gets the first byte and, holding its credit, nothing more. The output is
        // small enough to be read in full, so the process can exit while the client is still behind.
        configuration.sessionTuning.attachmentWindowBytes = 1
        let manager = SessionManager(configuration: configuration)
        manager.start()

        let info = try manager.spawn(shellRequest("sleep 0.3; printf hello"))
        let session = try #require(manager.session(info.id))
        let sink = AcknowledgingSink(acknowledging: false)
        let token = session.attach(sink, flowControlled: true) { _, _ in }
        sink.bind(session, token: token)
        #expect(await session.waitForExit() == 0)
        #expect(session.isSettled == false)

        manager.terminate(sessionID: info.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(manager.session(info.id) != nil, "the client has not received the exit yet")
        #expect(sink.collector.exitStatus == nil)
        #expect(sink.collector.text == "h")

        sink.release()
        #expect(await sink.collector.waitForExit() == 0)
        #expect(sink.collector.text == "hello")
        try await waitUntil { manager.session(info.id) == nil }
    }

    @Test func sessionThatEndedOnItsOwnKeepsOnlyItsTail() async throws {
        var configuration = SessionManager.Configuration(metadataDirectory: nil)
        configuration.exitedTailBytes = 1024
        let manager = SessionManager(configuration: configuration)
        manager.start()
        let client = UUID()
        manager.clientConnected(client)

        let info = try manager.spawn(shellRequest(rawSeqScript(20_000)))
        let session = try #require(manager.session(info.id))
        #expect(await session.waitForExit() == 0)
        try await waitUntil { session.scrollbackByteCount <= 1024 }
        #expect(session.bytesRead == UInt64(expectedSeqOutput(20_000).count), "offsets still count every byte")

        // The app's one read of a session that ended while it was away: the tail, then the exit.
        let sink = CollectingSink()
        let attached = manager.attach(sessionID: info.id, clientID: client, sink: sink) { scrollback, snapshotInfo in
            sink.collector.append(scrollback)
            #expect(snapshotInfo.isRunning == false)
        }
        #expect(attached)
        #expect(await sink.collector.waitForExit() == 0)
        #expect(sink.collector.text.hasSuffix("19999\n20000\n"))
        #expect(sink.collector.data.count <= 1024)
        #expect(sink.collector.text.first?.isNumber == true, "the tail starts at a line")
        #expect(manager.session(info.id) != nil, "kept until someone terminates it or the retention is over")
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
