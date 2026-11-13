import Darwin
import Foundation
import SuijinPTYProtocol

/// Why the CLI could not get an answer from the broker.
public enum BrokerClientError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Nothing listens: the terminal host is not running for this data root.
    case unreachable(String)
    case timedOut
    case invalidResponse

    public var description: String {
        switch self {
        case .unreachable(let reason): "Cannot reach Suijin's terminal host (\(reason))."
        case .timedOut: "Suijin's terminal host did not answer in time."
        case .invalidResponse: "Suijin's terminal host sent an invalid answer."
        }
    }
}

/// Sends one request to the broker: over the Unix socket, or through the spool when a sandbox refuses the socket
/// (Codex's `workspace-write` may write to the temporary directory but not connect to sockets).
public struct BrokerClient: Sendable {
    public var socketPath: String?
    public var spoolDirectory: URL?

    public init(socketPath: String?, spoolDirectory: URL?) {
        self.socketPath = socketPath
        self.spoolDirectory = spoolDirectory
    }

    /// From `SUIJIN_ORCH_SOCKET` / `SUIJIN_ORCH_SPOOL`, else derived from `SUIJIN_DATA_ROOT`.
    public init(environment: [String: String]) {
        let root = environment[OrchestrationEnvironment.dataRoot].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        socketPath = environment[OrchestrationEnvironment.socket].flatMap { $0.isEmpty ? nil : $0 }
            ?? root.map { OrchestrationPaths.socketPath(dataRoot: $0) }
        spoolDirectory = environment[OrchestrationEnvironment.spool].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.map { OrchestrationPaths.spoolDirectory(dataRoot: $0) }
    }

    public func send(_ request: BrokerRequest, timeout: TimeInterval) throws -> BrokerResponse {
        var socketFailure = "no socket path"
        if let socketPath {
            switch connect(socketPath) {
            case .connected(let fd):
                return try exchange(fd, request, timeout: timeout)
            case .failed(let reason):
                socketFailure = reason
            }
        }
        // A sandbox may refuse the socket (or hide it); the spool answers then. A broker that is not running never
        // picks the request up, which `pickupTimeout` detects quickly.
        guard let spoolDirectory, FileManager.default.fileExists(atPath: spoolDirectory.appendingPathComponent("requests").path) else {
            throw BrokerClientError.unreachable(socketFailure)
        }
        return try spoolExchange(request, directory: spoolDirectory, timeout: timeout, unreachable: socketFailure)
    }

    /// The broker sweeps the spool at least every second.
    static let pickupTimeout: TimeInterval = 3

    // MARK: Socket

    private enum ConnectOutcome {
        case connected(Int32)
        case failed(String)
    }

    private func connect(_ path: String) -> ConnectOutcome {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed(String(cString: strerror(errno))) }
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count <= OrchestrationPaths.socketPathByteLimit else {
            close(fd)
            return .failed("socket path too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            return .failed(String(cString: strerror(code)))
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return .connected(fd)
    }

    private func exchange(_ fd: Int32, _ request: BrokerRequest, timeout: TimeInterval) throws -> BrokerResponse {
        defer { close(fd) }
        var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var payload = try OrchestrationCoding.encoder.encode(request)
        payload.append(0x0A)
        let sent = payload.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written } else if written < 0, errno == EINTR { continue } else { return false }
            }
            return true
        }
        guard sent else { throw BrokerClientError.unreachable("write failed") }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while !buffer.contains(0x0A) {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw BrokerClientError.timedOut
            } else {
                break
            }
        }
        let line = buffer.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false).first ?? Data()
        guard let response = try? OrchestrationCoding.decoder.decode(BrokerResponse.self, from: Data(line)) else {
            throw BrokerClientError.invalidResponse
        }
        return response
    }

    // MARK: Spool

    private func spoolExchange(_ request: BrokerRequest, directory: URL, timeout: TimeInterval,
                               unreachable: String) throws -> BrokerResponse {
        let name = request.id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        guard !name.isEmpty else { throw BrokerClientError.invalidResponse }
        let requests = directory.appendingPathComponent("requests", isDirectory: true)
        let responses = directory.appendingPathComponent("responses", isDirectory: true)
        let temporary = requests.appendingPathComponent(".\(name).tmp").path
        let final = requests.appendingPathComponent("\(name).json").path
        let answer = responses.appendingPathComponent("\(name).json").path
        let data = try OrchestrationCoding.encoder.encode(request)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw BrokerClientError.unreachable("spool: \(String(cString: strerror(errno)))") }
        let complete = data.withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) == raw.count }
        close(fd)
        guard complete, rename(temporary, final) == 0 else {
            unlink(temporary)
            throw BrokerClientError.unreachable("spool write failed")
        }
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var pause: useconds_t = 20_000
        while Date() < deadline {
            if Date().timeIntervalSince(start) > Self.pickupTimeout, FileManager.default.fileExists(atPath: final) {
                unlink(final)
                throw BrokerClientError.unreachable(unreachable)
            }
            if let body = FileManager.default.contents(atPath: answer) {
                unlink(answer)
                guard let response = try? OrchestrationCoding.decoder.decode(BrokerResponse.self, from: body) else {
                    throw BrokerClientError.invalidResponse
                }
                return response
            }
            usleep(pause)
            pause = min(pause * 2, 200_000)
        }
        // Not picked up: withdraw it so a later broker does not act on a request nobody waits for.
        unlink(final)
        throw BrokerClientError.timedOut
    }
}
