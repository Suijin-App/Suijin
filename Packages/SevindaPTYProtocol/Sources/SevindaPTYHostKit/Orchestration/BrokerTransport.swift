import Darwin
import Foundation
import SevindaPTYProtocol
import os

/// Answers one decoded request; `reply` may run later and on any queue.
typealias BrokerRequestHandler = @Sendable (BrokerRequest, @escaping @Sendable (BrokerResponse) -> Void) -> Void

private let transportLogger = Logger(subsystem: "com.tekmium.mercury.ptyhost", category: "orchestration")

/// Largest request accepted (a spec may be long, but not unbounded).
private let maximumRequestBytes = 1 << 20

/// The broker's Unix domain socket: one line of JSON in, one line out, then the connection closes. The socket file is
/// 600 inside a 700 directory, and a peer whose uid differs from the helper's is dropped before it is read.
final class BrokerSocketServer: @unchecked Sendable {
    let path: String
    private let handler: BrokerRequestHandler
    private let queue = DispatchQueue(label: "com.tekmium.mercury.ptyhost.orchestration.socket")
    // Confined to `queue` after `start`.
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    /// The socket file this server bound, so `stop` never unlinks a newer server's socket at the same path.
    private var boundFile: (device: dev_t, inode: ino_t)?

    init(path: String, handler: @escaping BrokerRequestHandler) {
        self.path = path
        self.handler = handler
    }

    deinit {
        source?.cancel()
    }

    func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try makePrivateDirectory(directory)
        var info = stat()
        if lstat(path, &info) == 0 {
            // A socket left by an earlier helper process; anything else at that path is not ours to remove.
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw posixError("refusing to replace a non-socket at", path, EEXIST) }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket", path, errno) }
        var address = sockaddr_un()
        guard fillAddress(&address, path: path) else {
            close(fd)
            throw posixError("socket path too long", path, ENAMETOOLONG)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw posixError("bind", path, code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var boundInfo = stat()
        let file = lstat(path, &boundInfo) == 0 ? (device: boundInfo.st_dev, inode: boundInfo.st_ino) : nil
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        // The only place the listening descriptor is closed: after the source can no longer read it.
        source.setCancelHandler { close(fd) }
        queue.sync {
            listenFD = fd
            self.source = source
            boundFile = file
        }
        source.resume()
    }

    /// Closes the listening socket and removes its file, unless another server has since bound the same path.
    func stop() {
        let file = queue.sync { () -> (device: dev_t, inode: ino_t)? in
            source?.cancel()
            source = nil
            listenFD = -1
            defer { boundFile = nil }
            return boundFile
        }
        var info = stat()
        if let file, lstat(path, &info) == 0, info.st_dev == file.device, info.st_ino == file.inode {
            unlink(path)
        }
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return } // EAGAIN: drained
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                transportLogger.error("dropped a socket peer of another user")
                close(client)
                continue
            }
            let handler = self.handler
            DispatchQueue.global(qos: .userInitiated).async { Self.serve(client, handler: handler) }
        }
    }

    private static func serve(_ fd: Int32, handler: BrokerRequestHandler) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while !buffer.contains(0x0A), buffer.count < maximumRequestBytes {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        let line = buffer.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false).first ?? Data()
        guard let request = try? OrchestrationCoding.decoder.decode(BrokerRequest.self, from: Data(line)) else {
            respond(fd, .failure(BrokerFailure(code: "bad_request", message: "The request is not valid JSON.")))
            return
        }
        handler(request) { response in respond(fd, response) }
    }

    private static func respond(_ fd: Int32, _ response: BrokerResponse) {
        var data = (try? OrchestrationCoding.encoder.encode(response)) ?? Data(#"{"ok":false}"#.utf8)
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written } else if written < 0, errno == EINTR { continue } else { break }
            }
        }
        close(fd)
    }
}

/// The broker's drop box for callers that may write files but not connect to sockets (Codex's default sandbox). The
/// CLI renames `requests/<id>.json` into place; the broker reads and removes it, then writes `responses/<id>.json`,
/// which the CLI reads and removes. Both directories are 700 and every file 600; files not owned by the helper's user
/// are ignored.
final class BrokerSpool: @unchecked Sendable {
    let root: URL
    private let handler: BrokerRequestHandler
    private let queue = DispatchQueue(label: "com.tekmium.mercury.ptyhost.orchestration.spool")
    // Confined to `queue`.
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var inFlight: Set<String> = []

    /// Responses nobody collected are removed after this long.
    static let responseRetention: TimeInterval = 600

    var requests: URL { root.appendingPathComponent("requests", isDirectory: true) }
    var responses: URL { root.appendingPathComponent("responses", isDirectory: true) }

    init(root: URL, handler: @escaping BrokerRequestHandler) {
        self.root = root
        self.handler = handler
    }

    deinit {
        watcher?.cancel()
        timer?.cancel()
    }

    func start() throws {
        try makePrivateDirectory(root.deletingLastPathComponent().path)
        try makePrivateDirectory(root.path)
        try makePrivateDirectory(requests.path)
        try makePrivateDirectory(responses.path)
        let fd = open(requests.path, O_EVTONLY)
        guard fd >= 0 else { throw posixError("open", requests.path, errno) }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: queue)
        watcher.setEventHandler { [weak self] in self?.scan() }
        // The only place the watched directory's descriptor is closed: after the source can no longer use it.
        watcher.setCancelHandler { close(fd) }
        // The watcher can coalesce or miss events; a slow sweep picks up anything it missed.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.scan() }
        queue.sync {
            self.watcher = watcher
            self.timer = timer
        }
        watcher.resume()
        timer.resume()
        queue.async { self.scan() }
    }

    func stop() {
        queue.sync {
            watcher?.cancel()
            timer?.cancel()
            watcher = nil
            timer = nil
        }
    }

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            let stem = String(name.dropLast(5))
            guard Self.isSafeName(stem), !inFlight.contains(stem) else { continue }
            let path = requests.appendingPathComponent(name).path
            guard let data = readOwnedFile(path) else { continue }
            unlink(path)
            inFlight.insert(stem)
            let responsePath = responses.appendingPathComponent(name).path
            let queue = self.queue
            let finish: @Sendable (BrokerResponse) -> Void = { [weak self] response in
                Self.writeResponse(response, to: responsePath)
                queue.async { [weak self] in _ = self?.inFlight.remove(stem) }
            }
            guard let request = try? OrchestrationCoding.decoder.decode(BrokerRequest.self, from: data) else {
                finish(.failure(BrokerFailure(code: "bad_request", message: "The request is not valid JSON.")))
                continue
            }
            handler(request, finish)
        }
        pruneResponses()
    }

    private func pruneResponses() {
        let cutoff = Date().addingTimeInterval(-Self.responseRetention)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: responses.path)) ?? []
        for name in names {
            let path = responses.appendingPathComponent(name).path
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if let modified, modified < cutoff { unlink(path) }
        }
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func writeResponse(_ response: BrokerResponse, to path: String) {
        guard let data = try? OrchestrationCoding.encoder.encode(response) else { return }
        let temporary = path + ".tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        let complete = data.withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) == raw.count }
        close(fd)
        if complete { rename(temporary, path) } else { unlink(temporary) }
    }
}

/// Reads a regular file owned by this user (no symlinks), at most `maximumRequestBytes`.
func readOwnedFile(_ path: String) -> Data? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
          info.st_size >= 0, info.st_size <= maximumRequestBytes else { return nil }
    var data = Data(count: Int(info.st_size))
    let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    return count == Int(info.st_size) ? data : nil
}

/// Creates `path` (and parents) with mode 700 and tightens an existing directory; refuses a symlink or another
/// user's directory.
func makePrivateDirectory(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
        throw posixError("not a private directory:", path, EPERM)
    }
    if info.st_mode & 0o777 != 0o700 { chmod(path, 0o700) }
}

func fillAddress(_ address: inout sockaddr_un, path: String) -> Bool {
    let bytes = Array(path.utf8)
    guard bytes.count <= OrchestrationPaths.socketPathByteLimit else { return false }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.initializeMemory(as: UInt8.self, repeating: 0)
        raw.copyBytes(from: bytes)
    }
    return true
}

func posixError(_ what: String, _ path: String, _ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(what) \(path): \(String(cString: strerror(code)))"])
}
