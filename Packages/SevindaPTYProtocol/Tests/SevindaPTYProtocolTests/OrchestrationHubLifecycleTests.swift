import Darwin
import Foundation
import SevindaCLIKit
@testable import SevindaPTYHostKit
import SevindaPTYProtocol
import Testing

/// The helper is shared by every data root (the app, probes, test runs), so a data root's broker, socket, spool
/// watcher and endpoint must close once nothing uses it, or the helper runs out of descriptors.
@Suite("Orchestration data root lifecycle", .serialized)
struct OrchestrationHubLifecycleTests {
    /// A hub over a real session manager; sweeps run only when the test calls them unless `sweepInterval` is set.
    private struct Fixture {
        let directory: URL
        let manager: SessionManager
        let hub: OrchestrationHub

        init(idleGrace: TimeInterval = 60, sweepInterval: TimeInterval = 0) throws {
            directory = OrchestrationPaths.userTemporaryDirectory()
                .appendingPathComponent("mo-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            manager = SessionManager(configuration: SessionManager.Configuration(metadataDirectory: nil))
            var configuration = OrchestrationHub.Configuration()
            configuration.idleGrace = idleGrace
            configuration.sweepInterval = sweepInterval
            configuration.tuning.startReplyTimeout = 1
            hub = OrchestrationHub(manager: manager, configuration: configuration)
            manager.setObserver(hub)
            manager.start()
        }

        func dataRoot(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// A `/bin/cat` session registered with the broker of `dataRoot`; returns its host id and token.
        func spawnSession(dataRoot: URL, session: String) throws -> (id: String, token: String) {
            let token = OrchestrationToken.make()
            let info = try manager.spawn(PTYSpawnRequest(
                executable: "/bin/cat", environment: [OrchestrationEnvironment.sessionToken: token, "PATH": "/usr/bin:/bin"],
                cwd: "/tmp", metadata: [OrchestrationMetadata.session: session, OrchestrationMetadata.dataRoot: dataRoot.path,
                                        OrchestrationMetadata.agent: "claude"]))
            return (info.id, token)
        }

        func terminate(_ id: String) async {
            await withCheckedContinuation { continuation in
                manager.terminate(sessionID: id) { _ in continuation.resume() }
            }
        }

        /// Descriptors of this process that point into this fixture's data roots or their runtime directories.
        func ownedDescriptors(_ roots: [URL]) -> Int {
            let markers = [directory.lastPathComponent] + roots.map { OrchestrationPaths.runtimeDirectory(dataRoot: $0).lastPathComponent }
            return openDescriptorPaths().filter { path in markers.contains { path.contains($0) } }.count
        }

        func cleanUp() {
            hub.shutdown()
            for session in manager.listSessions() where session.isRunning { manager.terminate(sessionID: session.id) }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func unusedDataRootsCloseAndReleaseTheirDescriptors() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let count = 6
        let roots = try (0..<count).map { try fixture.dataRoot("d\($0)") }
        var sessions: [String] = []
        var connections: [NSXPCConnection] = []
        for (index, root) in roots.enumerated() {
            sessions.append(try fixture.spawnSession(dataRoot: root, session: "S-\(index)").id)
            if index.isMultiple(of: 2) { connections.append(try await connectApp(fixture.hub.endpoint(dataRoot: root))) }
        }
        #expect(fixture.hub.openDataRootCount == count)
        // Each open data root holds at least its socket and its spool watcher.
        #expect(fixture.ownedDescriptors(roots) >= 2 * count)

        // Still in use: nothing closes, however long it has been.
        fixture.hub.sweep(now: Date().addingTimeInterval(3600))
        #expect(fixture.hub.openDataRootCount == count)

        // Sessions gone but apps still connected: only the roots without an app close.
        for id in sessions { await fixture.terminate(id) }
        #expect(await eventually { fixture.hub.sweep(now: Date().addingTimeInterval(3600)); return fixture.hub.openDataRootCount == connections.count })

        for connection in connections { connection.invalidate() }
        #expect(await eventually { fixture.hub.sweep(now: Date().addingTimeInterval(3600)); return fixture.hub.openDataRootCount == 0 })
        #expect(await eventually { fixture.ownedDescriptors(roots) == 0 }, "every socket and spool descriptor is closed")
        for root in roots {
            let socket = OrchestrationPaths.socketPath(dataRoot: root)
            #expect(!FileManager.default.fileExists(atPath: socket), "the socket file is removed")
        }

        // A later session of the same data root reopens it and the CLI reaches it again.
        let reopened = try fixture.spawnSession(dataRoot: roots[0], session: "S-again")
        #expect(fixture.hub.openDataRootCount == 1)
        let cli = SevindaCLI(environment: [OrchestrationEnvironment.sessionToken: reopened.token,
                                           OrchestrationEnvironment.dataRoot: roots[0].path],
                             skillsDirectory: nil, version: "test")
        let whoami = cli.run(["whoami", "--json"])
        #expect(whoami.exitCode == 0, "\(whoami.stderr)")
        #expect(whoami.stdout.contains(#""sessionID" : "S-again""#))
        await fixture.terminate(reopened.id)
        #expect(await eventually { fixture.hub.sweep(now: Date().addingTimeInterval(3600)); return fixture.hub.openDataRootCount == 0 })
        #expect(await eventually { fixture.ownedDescriptors(roots) == 0 })
    }

    @Test func savedStateSurvivesClosingAndReopening() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let root = try fixture.dataRoot("d")
        let session = try fixture.spawnSession(dataRoot: root, session: "S-1")
        let connection = try await connectApp(fixture.hub.endpoint(dataRoot: root))
        let cli = SevindaCLI(environment: [OrchestrationEnvironment.sessionToken: session.token,
                                           OrchestrationEnvironment.dataRoot: root.path],
                             skillsDirectory: nil, version: "test")
        // The silent app never answers, so the start is left "starting" and then failed when the app goes away.
        _ = cli.run(["worker", "start", "--agent", "codex", "--spec", "Say hi", "--json"])
        connection.invalidate()
        await fixture.terminate(session.id)
        #expect(await eventually { fixture.hub.sweep(now: Date().addingTimeInterval(3600)); return fixture.hub.openDataRootCount == 0 })

        let snapshot = fixture.hub.broker(dataRoot: root).snapshot()
        #expect(snapshot.dispatches.count == 1)
        #expect(snapshot.dispatches.first?.coordinatorSessionID == "S-1")
    }

    @Test func deletedDataRootClosesEvenWithRunningSessions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let root = try fixture.dataRoot("gone")
        let session = try fixture.spawnSession(dataRoot: root, session: "S-1")
        #expect(fixture.ownedDescriptors([root]) >= 2)
        try FileManager.default.removeItem(at: root)

        fixture.hub.sweep()
        #expect(fixture.hub.openDataRootCount == 0)
        #expect(await eventually { fixture.ownedDescriptors([root]) == 0 })
        #expect(!FileManager.default.fileExists(atPath: OrchestrationPaths.runtimeDirectory(dataRoot: root).path))

        // The session ending afterwards neither reopens the data root nor recreates its directory.
        await fixture.terminate(session.id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.hub.openDataRootCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func endpointHandOffGetsAGracePeriod() async throws {
        let fixture = try Fixture(idleGrace: 30)
        defer { fixture.cleanUp() }
        let root = try fixture.dataRoot("d")
        // The app fetches the endpoint over a short-lived connection and only then connects to it.
        let endpoint = fixture.hub.endpoint(dataRoot: root)
        fixture.hub.sweep(now: Date().addingTimeInterval(5))
        #expect(fixture.hub.openDataRootCount == 1, "the root stays open while the app connects")
        let connection = try await connectApp(endpoint)
        fixture.hub.sweep(now: Date().addingTimeInterval(3600))
        #expect(fixture.hub.openDataRootCount == 1)
        connection.invalidate()
        #expect(await eventually { fixture.hub.sweep(now: Date().addingTimeInterval(3600)); return fixture.hub.openDataRootCount == 0 })
    }

    @Test func theSweepTimerClosesIdleDataRoots() async throws {
        let fixture = try Fixture(idleGrace: 0.1, sweepInterval: 0.05)
        defer { fixture.cleanUp() }
        let root = try fixture.dataRoot("d")
        let session = try fixture.spawnSession(dataRoot: root, session: "S-1")
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.hub.openDataRootCount == 1, "a running session keeps its data root open")
        await fixture.terminate(session.id)
        #expect(await eventually(timeout: 5) { fixture.hub.openDataRootCount == 0 })
        #expect(await eventually { fixture.ownedDescriptors([root]) == 0 })
    }

    @Test func socketStopLeavesANewerServersSocketInPlace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let path = fixture.directory.appendingPathComponent("b.sock").path
        let old = BrokerSocketServer(path: path) { _, reply in reply(.success([String](), text: "old")) }
        try old.start()
        let new = BrokerSocketServer(path: path) { _, reply in reply(.success([String](), text: "new")) }
        try new.start()
        defer { new.stop() }
        old.stop()
        let response = try BrokerClient(socketPath: path, spoolDirectory: nil).send(BrokerRequest(token: "t", command: "x"), timeout: 5)
        #expect(response.text == "new")
    }
}

/// Connects to a broker endpoint as the app does and waits for `hello`.
private func connectApp(_ endpoint: NSXPCListenerEndpoint) async throws -> NSXPCConnection {
    let connection = NSXPCConnection(listenerEndpoint: endpoint)
    connection.remoteObjectInterface = OrchestrationXPCInterfaces.host()
    connection.exportedInterface = OrchestrationXPCInterfaces.client()
    connection.exportedObject = IgnoringClient()
    connection.resume()
    let proxy = try #require(connection.remoteObjectProxy as? any OrchestrationHostXPC)
    let accepted = await withCheckedContinuation { continuation in proxy.hello(appBuild: "test") { continuation.resume(returning: $0) } }
    #expect(accepted)
    return connection
}

/// Polls `condition` until it holds or `timeout` passes.
private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// What every open descriptor of this process refers to: a path for files and directories, the bound path for Unix
/// sockets. Listed from `/dev/fd`, so suites running in parallel can be told apart by path.
private func openDescriptorPaths() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
    return names.compactMap(Int32.init).compactMap { fd -> String? in
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(fd, F_GETPATH, &buffer) == 0 {
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0, address.sun_family == sa_family_t(AF_UNIX) else { return nil }
        return withUnsafeBytes(of: &address.sun_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// An app that ignores everything the broker sends.
private final class IgnoringClient: NSObject, OrchestrationClientXPC, Sendable {
    func startWorker(_ request: Data) {}
    func stateChanged() {}
    func attention(_ event: Data) {}
}
