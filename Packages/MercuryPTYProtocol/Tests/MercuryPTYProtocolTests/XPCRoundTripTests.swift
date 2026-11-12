import Foundation
import MercuryPTYHostKit
import MercuryPTYProtocol
import Synchronization
import Testing

/// The app side of the connection in tests: one collector per session, plus the reply/output order. Acknowledges
/// every chunk as consumed while `acknowledging` is on; otherwise holds the credit (an app that stopped draining).
final class TestClientReceiver: NSObject, PTYClientXPC, Sendable {
    private struct Flow {
        var acknowledger: (@Sendable (String, Int) -> Void)?
        var acknowledging = true
        var held: [String: Int] = [:]
    }

    private let collectors = Mutex<[String: OutputCollector]>([:])
    private let flow = Mutex(Flow())

    func setAcknowledger(_ acknowledger: @escaping @Sendable (String, Int) -> Void) {
        flow.withLock { $0.acknowledger = acknowledger }
    }

    func setAcknowledging(_ on: Bool) {
        let (acknowledger, held) = flow.withLock { flow -> ((@Sendable (String, Int) -> Void)?, [String: Int]) in
            flow.acknowledging = on
            guard on else { return (nil, [:]) }
            defer { flow.held = [:] }
            return (flow.acknowledger, flow.held)
        }
        for (sessionID, bytes) in held { acknowledger?(sessionID, bytes) }
    }

    func collector(for sessionID: String) -> OutputCollector {
        collectors.withLock { map in
            if let existing = map[sessionID] { return existing }
            let created = OutputCollector()
            map[sessionID] = created
            return created
        }
    }

    func output(_ sessionID: String, data: Data) {
        if data.isEmpty {
            collector(for: sessionID).record(event: "stream-start")
            return
        }
        collector(for: sessionID).append(data)
        let acknowledger = flow.withLock { flow -> (@Sendable (String, Int) -> Void)? in
            guard flow.acknowledging else {
                flow.held[sessionID, default: 0] += data.count
                return nil
            }
            return flow.acknowledger
        }
        acknowledger?(sessionID, data.count)
    }

    func exited(_ sessionID: String, status: Int32) {
        collector(for: sessionID).setExit(status)
    }
}

/// A connected anonymous-listener pair: the real `PTYHostServer` on one end, a raw `NSXPCConnection` on the other.
final class XPCHarness: Sendable {
    let directory: URL
    let manager: SessionManager
    let server: PTYHostServer
    nonisolated(unsafe) let listener: NSXPCListener // immutable reference; NSXPCListener is thread-safe
    nonisolated(unsafe) let connection: NSXPCConnection
    let receiver = TestClientReceiver()
    private let connectionErrors = Mutex<[String]>([])

    init() throws {
        directory = try makeTemporaryDirectory()
        var configuration = SessionManager.Configuration(metadataDirectory: directory)
        configuration.idleGrace = 60
        manager = SessionManager(configuration: configuration)
        manager.start()
        server = PTYHostServer(manager: manager, build: "test-build")
        listener = NSXPCListener.anonymous()
        listener.delegate = server
        listener.resume()

        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = PTYXPCInterfaces.host()
        connection.exportedInterface = PTYXPCInterfaces.client()
        connection.exportedObject = receiver
        connection.resume()
        receiver.setAcknowledger { [weak self] sessionID, bytes in self?.host.ack(sessionID, bytes: bytes) }
    }

    var errors: [String] { connectionErrors.withLock { $0 } }

    var host: any PTYHostXPC {
        connection.remoteObjectProxyWithErrorHandler { [self] error in
            self.connectionErrors.withLock { $0.append(error.localizedDescription) }
        } as! any PTYHostXPC
    }

    func handshake() async -> (Int, String) {
        await withCheckedContinuation { continuation in
            host.handshake(clientProtocolVersion: PTYHostConstants.protocolVersion) { version, build in
                continuation.resume(returning: (version, build))
            }
        }
    }

    func spawn(_ request: PTYSpawnRequest) async throws -> (String?, String?) {
        let data = try PTYCoding.encode(request)
        return await withCheckedContinuation { continuation in
            host.spawn(data) { id, error in continuation.resume(returning: (id, error)) }
        }
    }

    /// Attaches and records the reply into the session's collector, in connection order with the output stream.
    func attach(_ sessionID: String) async throws -> (Data, PTYSessionInfo)? {
        let collector = receiver.collector(for: sessionID)
        let reply: (Data?, Data?) = await withCheckedContinuation { continuation in
            host.attach(sessionID) { scrollback, info in
                collector.record(event: "attach-reply")
                continuation.resume(returning: (scrollback, info))
            }
        }
        guard let scrollback = reply.0, let infoData = reply.1 else { return nil }
        return (scrollback, try PTYCoding.decode(PTYSessionInfo.self, from: infoData))
    }

    func listSessions() async throws -> [PTYSessionInfo] {
        let data: Data = await withCheckedContinuation { continuation in
            host.listSessions { continuation.resume(returning: $0) }
        }
        return try PTYCoding.decode([PTYSessionInfo].self, from: data)
    }

    func tearDown() {
        connection.invalidate()
        listener.invalidate()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("XPC round trip", .serialized)
struct XPCRoundTripTests {
    @Test func fullSessionLifecycleOverXPC() async throws {
        let harness = try XPCHarness()
        defer { harness.tearDown() }

        // Handshake.
        let (version, build) = await harness.handshake()
        #expect(version == PTYHostConstants.protocolVersion)
        #expect(build == "test-build")
        try await waitUntil { harness.manager.connectedClientCount == 1 }

        // Spawn + attach.
        let (spawnedID, spawnError) = try await harness.spawn(
            PTYSpawnRequest(executable: "/bin/cat", cwd: "/", cols: 100, rows: 30, metadata: ["tab": "1"])
        )
        #expect(spawnError == nil)
        let sessionID = try #require(spawnedID)
        let (initialScrollback, info) = try #require(try await harness.attach(sessionID))
        #expect(initialScrollback.isEmpty)
        #expect(info.isRunning)
        #expect(info.executable == "/bin/cat")
        #expect(info.metadata == ["tab": "1"])
        let live = harness.receiver.collector(for: sessionID)

        // Write -> echo round trips, measured: keystrokes 30 ms apart (fast typing) and back to back (worst case,
        // where the flush pacing kicks in).
        let typing = try await measureEchoRoundTrips(harness, sessionID, live, prefix: "type", count: 40, spacing: .milliseconds(30))
        let burst = try await measureEchoRoundTrips(harness, sessionID, live, prefix: "ping", count: 50, spacing: nil)
        print("XPC write->echo round trip, typing (30 ms apart): \(typing)")
        print("XPC write->echo round trip, back to back: \(burst)")
        #expect(typing.median < 5)
        #expect(burst.median < 30)

        // Resize goes through (cat ignores it, but the call must not break the session).
        harness.host.resize(sessionID, cols: 120, rows: 40)

        // Detach: nothing streams to this client any more, the session keeps running and recording.
        harness.host.detach(sessionID)
        harness.host.write(sessionID, data: Data("while-detached\n".utf8))
        try await waitUntil {
            harness.manager.session(sessionID)?.scrollbackSnapshot().occurrences(of: Data("while-detached".utf8)) == 2
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!live.text.contains("while-detached"))

        // Re-attach: the scrollback holds everything, including what was produced while detached.
        live.reset()
        let (scrollback, reattachedInfo) = try #require(try await harness.attach(sessionID))
        #expect(reattachedInfo.isRunning)
        #expect(scrollback.contains(text: "type-0-"))
        #expect(scrollback.contains(text: "ping-49-"))
        #expect(scrollback.occurrences(of: Data("while-detached".utf8)) == 2)

        harness.host.write(sessionID, data: Data("after-reattach\n".utf8))
        #expect(await live.wait(forText: "after-reattach", occurrences: 2))

        // Terminate: exited arrives after the last output, with the SIGHUP status.
        harness.host.terminate(sessionID)
        #expect(await live.waitForExit() == 128 + SIGHUP)
        #expect(live.events.first { $0 != "attach-reply" } == "stream-start")
        #expect(live.events.last == "exit")

        let sessions = try await harness.listSessions()
        let ended = try #require(sessions.first { $0.id == sessionID })
        #expect(ended.isRunning == false)
        #expect(ended.exitStatus == 128 + SIGHUP)
        #expect(FileManager.default.fileExists(atPath: harness.directory.appendingPathComponent("\(sessionID).json").path))

        // Re-attaching to an exited session still returns its scrollback, followed by the exit.
        let exitedCollector = harness.receiver.collector(for: sessionID)
        exitedCollector.reset()
        let (finalScrollback, finalInfo) = try #require(try await harness.attach(sessionID))
        #expect(finalInfo.isRunning == false)
        #expect(finalScrollback.contains(text: "after-reattach"))
        #expect(harness.errors.isEmpty)

        // Invalidation detaches the client on the host side.
        harness.connection.invalidate()
        try await waitUntil { harness.manager.connectedClientCount == 0 }
    }

    struct LatencyStats: CustomStringConvertible {
        let samples: [Double] // milliseconds, sorted
        var median: Double { samples[samples.count / 2] }
        var p95: Double { samples[samples.count * 95 / 100] }
        var max: Double { samples[samples.count - 1] }
        var description: String {
            String(format: "n=%d median %.3f ms, p95 %.3f ms, max %.3f ms", samples.count, median, p95, max)
        }
    }

    private func measureEchoRoundTrips(
        _ harness: XPCHarness, _ sessionID: String, _ live: OutputCollector,
        prefix: String, count: Int, spacing: Duration?
    ) async throws -> LatencyStats {
        let clock = ContinuousClock()
        var samples: [Double] = []
        for index in 0..<count {
            if let spacing { try await Task.sleep(for: spacing) }
            let token = "\(prefix)-\(index)-"
            let started = clock.now
            harness.host.write(sessionID, data: Data("\(token)\n".utf8))
            #expect(await live.wait(timeout: 5, forText: token, occurrences: 1)) // the terminal's echo
            let elapsed = clock.now - started
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            #expect(await live.wait(timeout: 5, forText: token, occurrences: 2)) // cat's copy
        }
        return LatencyStats(samples: samples.sorted())
    }

    @Test func attachDuringHeavyOutputHasNoGapOrDuplicate() async throws {
        let harness = try XPCHarness()
        defer { harness.tearDown() }
        _ = await harness.handshake()

        let (spawnedID, _) = try await harness.spawn(shellRequest("/usr/bin/seq 1 300000; read line"))
        let sessionID = try #require(spawnedID)
        try await Task.sleep(for: .milliseconds(20)) // attach while seq is still writing
        let (scrollback, _) = try #require(try await harness.attach(sessionID))
        let live = harness.receiver.collector(for: sessionID)
        #expect(await live.wait(timeout: 30) { data, _ in data.suffix(16).contains(text: "300000\r\n") })
        try await Task.sleep(for: .milliseconds(100))

        let full = try #require(harness.manager.session(sessionID)?.scrollbackSnapshot())
        let reassembled = scrollback + live.data
        #expect(reassembled.count == full.count)
        #expect(reassembled == full)
        #expect(live.events.first { $0 != "attach-reply" } == "stream-start", "the marker precedes every streamed byte")
        #expect(live.events.contains("attach-reply"))
        print("XPC heavy output: \(live.data.count) bytes streamed in \(live.events.count - 1) messages")

        harness.host.terminate(sessionID)
        #expect(await live.waitForExit() != nil)
    }

    @Test func appThatStopsAcknowledgingStallsTheChild() async throws {
        let harness = try XPCHarness()
        defer { harness.tearDown() }
        _ = await harness.handshake()
        harness.receiver.setAcknowledging(false)

        let lines = 2_000_000 // ~16 MB: more than the scrollback, so any skipped byte would show
        let (spawnedID, _) = try await harness.spawn(shellRequest(rawSeqScript(lines)))
        let sessionID = try #require(spawnedID)
        let session = try #require(harness.manager.session(sessionID))
        _ = try #require(try await harness.attach(sessionID))
        let live = harness.receiver.collector(for: sessionID)

        try await waitUntil { session.isReadPaused }
        let stalledAt = session.bytesRead
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.bytesRead == stalledAt)
        #expect(session.isRunning)
        let window = PTYSessionTuning().attachmentWindowBytes
        #expect(live.data.count <= window, "the app never holds more than one window of unconsumed output")
        print("XPC flow control: stalled after reading \(stalledAt) bytes, app holds \(live.data.count) unacknowledged")

        harness.receiver.setAcknowledging(true)
        #expect(await live.waitForExit(timeout: 60) == 0)
        #expect(live.data == expectedSeqOutput(lines), "every byte arrives exactly once")
    }

    @Test func reportsErrorsForBadRequests() async throws {
        let harness = try XPCHarness()
        defer { harness.tearDown() }

        let (id, error) = try await harness.spawn(PTYSpawnRequest(executable: "/no/such/tool", cwd: "/"))
        #expect(id == nil)
        #expect(error?.contains("not found") == true)

        let garbage: (String?, String?) = await withCheckedContinuation { continuation in
            harness.host.spawn(Data("not json".utf8)) { continuation.resume(returning: ($0, $1)) }
        }
        #expect(garbage.0 == nil)
        #expect(garbage.1?.hasPrefix("Invalid spawn request") == true)

        #expect(try await harness.attach("unknown-session") == nil)
        // Calls for unknown sessions are ignored without tearing the connection down.
        harness.host.write("unknown-session", data: Data("x".utf8))
        harness.host.resize("unknown-session", cols: 10, rows: 10)
        harness.host.terminate("unknown-session")
        harness.host.detach("unknown-session")
        let (version, _) = await harness.handshake()
        #expect(version == PTYHostConstants.protocolVersion)
        #expect(harness.errors.isEmpty)
    }
}
