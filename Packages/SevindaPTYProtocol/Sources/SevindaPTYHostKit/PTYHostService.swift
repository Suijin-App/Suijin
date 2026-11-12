import Foundation
import SevindaPTYProtocol
import os

/// The `PTYHostXPC` implementation exported to one client connection.
///
/// One instance per connection; it holds the connection weakly (the connection retains its exported object) and the
/// client's identity inside the `SessionManager`.
public final class PTYHostService: NSObject, PTYHostXPC, @unchecked Sendable {
    // Immutable after init; the weak reference is only read. Hence `@unchecked Sendable`.
    private let manager: SessionManager
    private let clientID: UUID
    private let build: String
    private weak var connection: NSXPCConnection?
    private let sink: XPCClientSink
    private let orchestration: OrchestrationHub?

    public init(manager: SessionManager, connection: NSXPCConnection, clientID: UUID = UUID(), build: String,
                orchestration: OrchestrationHub? = nil) {
        self.manager = manager
        self.clientID = clientID
        self.build = build
        self.connection = connection
        self.sink = XPCClientSink(connection: connection)
        self.orchestration = orchestration
    }

    public func handshake(clientProtocolVersion: Int, reply: @escaping @Sendable (Int, String) -> Void) {
        reply(PTYHostConstants.negotiatedVersion(clientVersion: clientProtocolVersion), build)
    }

    public func listSessions(reply: @escaping @Sendable (Data) -> Void) {
        let data = (try? PTYCoding.encode(manager.listSessions())) ?? Data("[]".utf8)
        reply(data)
    }

    public func spawn(_ request: Data, reply: @escaping @Sendable (String?, String?) -> Void) {
        let decoded: PTYSpawnRequest
        do {
            decoded = try PTYCoding.decode(PTYSpawnRequest.self, from: request)
        } catch {
            reply(nil, "Invalid spawn request: \(error.localizedDescription)")
            return
        }
        guard !decoded.executable.isEmpty else {
            reply(nil, "Invalid spawn request: missing executable")
            return
        }
        do {
            let info = try manager.spawn(decoded)
            reply(info.id, nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    public func attach(_ sessionID: String, reply: @escaping @Sendable (Data?, Data?) -> Void) {
        let attached = manager.attach(sessionID: sessionID, clientID: clientID, sink: sink, flowControlled: true) {
            scrollback, info in
            // Runs before any live output is handed to the sink, so the reply precedes the stream on the connection.
            reply(scrollback, try? PTYCoding.encode(info))
        }
        if !attached { reply(nil, nil) }
    }

    public func detach(_ sessionID: String) {
        manager.detach(sessionID: sessionID, clientID: clientID)
    }

    public func write(_ sessionID: String, data: Data) {
        manager.write(sessionID: sessionID, data: data)
    }

    public func resize(_ sessionID: String, cols: Int, rows: Int) {
        manager.resize(sessionID: sessionID, cols: cols, rows: rows)
    }

    public func terminate(_ sessionID: String) {
        manager.terminate(sessionID: sessionID)
    }

    public func shutdownIfIdle() {
        manager.shutdownIfIdle()
    }

    public func ack(_ sessionID: String, bytes: Int) {
        manager.acknowledge(sessionID: sessionID, clientID: clientID, bytes: bytes)
    }

    public func orchestrationEndpoint(dataRoot: String, reply: @escaping @Sendable (NSXPCListenerEndpoint?, String?) -> Void) {
        guard let orchestration else {
            reply(nil, "This terminal host has no orchestration broker.")
            return
        }
        guard dataRoot.hasPrefix("/") else {
            reply(nil, "The data root must be an absolute path.")
            return
        }
        reply(orchestration.endpoint(dataRoot: URL(fileURLWithPath: dataRoot, isDirectory: true)), nil)
    }
}

/// Streams session output to the app through the connection's `PTYClientXPC` proxy. The window is refilled by the
/// app's `ack` calls, not by XPC accepting the message, so app memory stays bounded.
final class XPCClientSink: PTYOutputSink, @unchecked Sendable {
    // Immutable after init; NSXPCConnection proxies are thread-safe.
    private let proxy: (any PTYClientXPC)?

    init(connection: NSXPCConnection) {
        self.proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            // Delivery failures surface as connection invalidation, which detaches the client.
        } as? any PTYClientXPC
    }

    func deliver(output: Data, sessionID: String) {
        proxy?.output(sessionID, data: output)
    }

    func deliver(exitStatus: Int32, sessionID: String) {
        proxy?.exited(sessionID, status: exitStatus)
    }
}

/// `NSXPCListenerDelegate` that wires each accepted connection to a fresh `PTYHostService`. Works with the helper's
/// Mach service listener and with `NSXPCListener.anonymous()` in tests.
public final class PTYHostServer: NSObject, NSXPCListenerDelegate, Sendable {
    private static let logger = Logger(subsystem: "com.tekmium.sevinda.ptyhost", category: "xpc")

    public let manager: SessionManager
    public let orchestration: OrchestrationHub?
    private let build: String
    private let acceptsConnection: @Sendable (NSXPCConnection) -> Bool

    /// `acceptsConnection` is an extra gate on top of any code-signing requirement set on the listener.
    public init(
        manager: SessionManager,
        build: String,
        orchestration: OrchestrationHub? = nil,
        acceptsConnection: @escaping @Sendable (NSXPCConnection) -> Bool = { _ in true }
    ) {
        self.manager = manager
        self.orchestration = orchestration
        self.build = build
        self.acceptsConnection = acceptsConnection
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard acceptsConnection(connection) else {
            Self.logger.error("rejected connection from pid \(connection.processIdentifier)")
            return false
        }
        let clientID = UUID()
        let manager = self.manager
        connection.exportedInterface = PTYXPCInterfaces.host()
        connection.remoteObjectInterface = PTYXPCInterfaces.client()
        connection.exportedObject = PTYHostService(manager: manager, connection: connection, clientID: clientID, build: build,
                                                   orchestration: orchestration)
        // Interruption cannot happen for an incoming connection in practice, but treat it like invalidation.
        connection.invalidationHandler = { manager.clientDisconnected(clientID) }
        connection.interruptionHandler = { manager.clientDisconnected(clientID) }
        manager.clientConnected(clientID)
        connection.resume()
        return true
    }
}
