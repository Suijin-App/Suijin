import CryptoKit
import Darwin
import Foundation

/// File type of a path without following a final symlink.
enum EntryKind: Equatable, Sendable {
    case file, directory, symlink, other
}

/// Result of reading a JSON object file.
enum JSONObjectRead {
    case present([String: Any])
    case absent
    /// The file exists but is not valid JSON (a copy Suijin may replace).
    case invalidJSON
    /// The file is valid JSON but not an object, or could not be read for another reason.
    case unreadable(String)
}

/// POSIX file helpers with explicit modes. Paths are handled as strings so symlinks are never resolved implicitly.
enum FileOps {
    static func errnoError(_ operation: String, _ path: String, _ code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) \(path): \(String(cString: strerror(code)))"])
    }

    /// `nil` when the path definitively does not exist (ENOENT or ENOTDIR).
    static func lstatKind(_ path: String) throws -> EntryKind? {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw errnoError("lstat", path)
        }
        return kind(of: info.st_mode)
    }

    /// True only when nothing (not even a dangling link) is at `path`; a read error is not absence.
    static func isDefinitelyAbsent(_ path: String) -> Bool {
        do {
            return try lstatKind(path) == nil
        } catch {
            return false
        }
    }

    /// Like `lstatKind` but follows symlinks; a dangling link reads as absent.
    static func statKind(_ path: String) throws -> EntryKind? {
        var info = stat()
        if stat(path, &info) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw errnoError("stat", path)
        }
        return kind(of: info.st_mode)
    }

    private static func kind(of mode: mode_t) -> EntryKind {
        switch mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symlink
        default: .other
        }
    }

    static func mode(_ path: String) throws -> mode_t {
        var info = stat()
        guard stat(path, &info) == 0 else { throw errnoError("stat", path) }
        return info.st_mode & 0o7777
    }

    static func device(_ path: String) throws -> dev_t {
        var info = stat()
        guard stat(path, &info) == 0 else { throw errnoError("stat", path) }
        return info.st_dev
    }

    /// `realpath(3)`; `nil` when a component is missing.
    static func realpath(_ path: String) throws -> String? {
        guard let resolved = Darwin.realpath(path, nil) else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw errnoError("realpath", path)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Lexically normalized absolute path (no symlink resolution), like Node's `path.resolve`.
    static func resolve(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        var parts: [Substring] = []
        for part in absolute.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Resolves ancestor links even for a path that does not exist yet.
    static func canonicalPath(_ path: String) throws -> String {
        let resolved = resolve(path)
        if let real = try realpath(resolved) { return real }
        let parent = (resolved as NSString).deletingLastPathComponent
        if parent == resolved { return resolved }
        return join(try canonicalPath(parent), (resolved as NSString).lastPathComponent)
    }

    static func join(_ base: String, _ components: String...) -> String {
        var result = base
        for component in components {
            result = result.hasSuffix("/") ? result + component : result + "/" + component
        }
        return result
    }

    /// Whether `candidate` equals `root` or lies below it. Case-insensitive, because the default macOS volume is,
    /// which only makes the overlap checks stricter.
    static func isInsideOrEqual(_ candidate: String, root: String) -> Bool {
        let candidate = candidate.lowercased()
        let root = root.lowercased()
        if candidate == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return candidate.hasPrefix(prefix)
    }

    /// Creates the directory and missing parents. Only directories this call creates get `mode`.
    static func ensureDirectory(_ path: String, mode: mode_t = 0o700) throws {
        if let kind = try statKind(path) {
            guard kind == .directory else { throw errnoError("mkdir", path, ENOTDIR) }
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        if parent != path { try ensureDirectory(parent, mode: mode) }
        if mkdir(path, mode) != 0 && errno != EEXIST { throw errnoError("mkdir", path) }
        // mkdir applies the umask; set the exact mode explicitly.
        _ = chmod(path, mode)
    }

    static func readData(_ path: String) throws -> Data? {
        guard try statKind(path) != nil else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Writes to a temporary sibling and renames it over `path`, so readers never see a partial file.
    static func writeAtomically(_ data: Data, to path: String, mode: mode_t = 0o600) throws {
        let staged = try stage(data, besides: path, mode: mode)
        if rename(staged, path) != 0 {
            let code = errno
            unlink(staged)
            throw errnoError("rename", path, code)
        }
    }

    /// Publishes `data` at `path` only if nothing exists there; returns false when another writer won.
    static func createExclusively(_ data: Data, at path: String, mode: mode_t = 0o600) throws -> Bool {
        let staged = try stage(data, besides: path, mode: mode)
        defer { unlink(staged) }
        if link(staged, path) != 0 {
            if errno == EEXIST { return false }
            throw errnoError("link", path)
        }
        return true
    }

    private static func stage(_ data: Data, besides path: String, mode: mode_t) throws -> String {
        let staged = "\(path).\(getpid()).\(UUID().uuidString).tmp"
        let fd = open(staged, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw errnoError("open", staged) }
        var failure: NSError?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errnoError("write", staged)
                    return
                }
                offset += written
            }
        }
        if failure == nil && fchmod(fd, mode) != 0 { failure = errnoError("chmod", staged) }
        close(fd)
        if let failure {
            unlink(staged)
            throw failure
        }
        return staged
    }

    static func readJSONObject(_ path: String) -> JSONObjectRead {
        let data: Data
        do {
            guard let read = try readData(path) else { return .absent }
            data = read
        } catch {
            return .unreadable("\((path as NSString).lastPathComponent) could not be read")
        }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .invalidJSON
        }
        guard let object = value as? [String: Any] else {
            return .unreadable("\((path as NSString).lastPathComponent) is not a JSON object")
        }
        return .present(object)
    }

    /// Stable serialization used for comparisons and digests.
    static func canonicalJSON(_ value: Any) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
    }

    static func prettyJSON(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    static func jsonEqual(_ left: Any, _ right: Any) -> Bool {
        canonicalJSON(left) == canonicalJSON(right)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes a tree without following symlinks inside it (`FileManager` unlinks links rather than descending).
    static func removeTree(_ path: String) throws {
        guard try lstatKind(path) != nil else { return }
        try FileManager.default.removeItem(atPath: path)
    }
}

/// The selected-host file the terminal shell functions read: an absolute home path, absent = default login.
enum PointerFile {
    static func write(home: URL?, to pointer: URL) throws {
        let path = pointer.path
        guard let home else {
            if unlink(path) != 0 && errno != ENOENT { throw FileOps.errnoError("unlink", path) }
            return
        }
        let contents = Data(home.path.utf8)
        // Avoid rewriting the pointer on every launch.
        if (try? FileOps.readData(path)) == contents { return }
        try FileOps.ensureDirectory((path as NSString).deletingLastPathComponent)
        try FileOps.writeAtomically(contents, to: path, mode: 0o600)
    }
}
