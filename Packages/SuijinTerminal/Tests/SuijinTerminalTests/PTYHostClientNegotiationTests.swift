import Foundation
@testable import SuijinTerminal
import SuijinPTYProtocol
import Synchronization
import Testing

/// A helper that answers the handshake with a fixed protocol version and records what the client asks for.
private final class FakeHost: NSObject, PTYHostXPC, @unchecked Sendable {
    let version: Int
    private let calls = Mutex<[String]>([])

    init(version: Int) { self.version = version }

    var recorded: [String] { calls.withLock { $0 } }
    private func note(_ call: String) { calls.withLock { $0.append(call) } }

    func handshake(clientProtocolVersion: Int, reply: @escaping @Sendable (Int, String) -> Void) {
        note("handshake(\(clientProtocolVersion))")
        reply(version, "0.1.0 (1)")
    }
    func listSessions(reply: @escaping @Sendable (Data) -> Void) {
        note("listSessions")
        reply(Data("[]".utf8))
    }
    func spawn(_ request: Data, reply: @escaping @Sendable (String?, String?) -> Void) { reply(nil, "fake") }
    func attach(_ sessionID: String, reply: @escaping @Sendable (Data?, Data?) -> Void) { reply(nil, nil) }
    func detach(_ sessionID: String) {}
    func write(_ sessionID: String, data: Data) {}
    func resize(_ sessionID: String, cols: Int, rows: Int) {}
    func terminate(_ sessionID: String) { note("terminate") }
    func shutdownIfIdle() { note("shutdownIfIdle") }
    func ack(_ sessionID: String, bytes: Int) {}
    func orchestrationEndpoint(dataRoot: String, reply: @escaping @Sendable (NSXPCListenerEndpoint?, String?) -> Void) {
        reply(nil, "fake")
    }
}

private final class FakeListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let host: FakeHost
    let listener = NSXPCListener.anonymous()

    init(version: Int) {
        host = FakeHost(version: version)
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = PTYXPCInterfaces.host()
        connection.remoteObjectInterface = PTYXPCInterfaces.client()
        connection.exportedObject = host
        connection.resume()
        return true
    }
}

@MainActor
@Suite("PTY host protocol negotiation")
struct PTYHostClientNegotiationTests {
    private func client(for fake: FakeListener) -> PTYHostClient {
        let endpoint = fake.listener.endpoint
        let client = PTYHostClient(connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint) })
        client.requestTimeout = 5
        return client
    }

    @Test func olderCompatibleHelperIsUsedAsIs() async throws {
        // The helper of an earlier release keeps the user's sessions; the updated app must still attach to them.
        let fake = FakeListener(version: 2)
        let client = client(for: fake)
        _ = try await client.handshake()
        #expect(client.hostProtocolVersion == 2)
        #expect(try await client.listSessions().isEmpty)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!fake.host.recorded.contains("shutdownIfIdle"), "a compatible helper is never asked to exit by the handshake")
        #expect(fake.host.recorded.first == "handshake(\(PTYHostConstants.protocolVersion))")
        client.disconnect()
    }

    @Test func currentHelperIsAccepted() async throws {
        let fake = FakeListener(version: PTYHostConstants.protocolVersion)
        let client = client(for: fake)
        _ = try await client.handshake()
        #expect(client.hostProtocolVersion == PTYHostConstants.protocolVersion)
        client.disconnect()
    }

    @Test func incompatibleHelperIsRefused() async throws {
        for version in [1, PTYHostConstants.protocolVersion + 1] {
            let fake = FakeListener(version: version)
            let client = client(for: fake)
            await #expect(throws: PTYHostClientError.protocolMismatch(host: version, client: PTYHostConstants.protocolVersion)) {
                _ = try await client.handshake()
            }
            #expect(client.hostProtocolVersion == nil)
        }
    }

    @Test func compatibilityRange() {
        #expect(PTYHostConstants.isCompatible(hostVersion: 2))
        #expect(PTYHostConstants.isCompatible(hostVersion: 3))
        #expect(!PTYHostConstants.isCompatible(hostVersion: 1))
        #expect(!PTYHostConstants.isCompatible(hostVersion: 4))
    }
}
