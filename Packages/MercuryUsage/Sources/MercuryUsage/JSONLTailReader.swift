import Darwin
import Foundation

/// What `stat` says about a log file; an unchanged identity means the file needs no reading at all.
struct FileIdentity: Codable, Sendable, Hashable {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    /// Modification time in seconds since 1970, with nanoseconds.
    var modified: Double

    /// Follows symlinks; nil when the path is missing or not a regular file.
    static func current(path: String) -> FileIdentity? {
        var info = Darwin.stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileIdentity(info)
    }

    init(device: UInt64, inode: UInt64, size: Int64, modified: Double) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modified = modified
    }

    init(_ info: Darwin.stat) {
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    func isSamePhysicalFile(as other: FileIdentity) -> Bool { device == other.device && inode == other.inode }
}

/// How far a file has been read. Resuming requires the same physical file, at least `offset` bytes, and the same
/// bytes just before `offset`; anything else (truncation, replacement, rewrite) reads the file again from 0.
/// Modeled on Orca's `jsonl-file-checkpoint.ts` (inode plus a digest of the window before the boundary).
struct FileCheckpoint: Codable, Sendable, Hashable {
    var identity: FileIdentity
    /// Bytes consumed: always the end of a complete record.
    var offset: Int64
    /// `StableHash` of the up to `JSONLTailReader.boundaryWindow` bytes before `offset`.
    var boundaryHash: UInt64
}

struct LogReadError: Error, Sendable, Equatable {
    let path: String
    let code: Int32

    /// The file disappeared between discovery and reading (a session that was cleaned up).
    var isMissing: Bool { code == ENOENT || code == ENOTDIR }
}

/// Reads newline-terminated records of a file from a checkpoint, opening it read-only.
enum JSONLTailReader {
    static let boundaryWindow = 4_096
    static let chunkSize = 4 << 20

    struct Outcome: Sendable {
        var checkpoint: FileCheckpoint
        var resumed: Bool
        var bytesRead: Int64
    }

    /// Calls `onLine` for every complete line after the checkpoint (without its newline). A last line with no
    /// newline yet goes to `onUnterminatedTail`, which returns true when it is a complete record (then it is
    /// consumed; a later `\n` only adds an empty line) or false to read it again next time.
    /// `onStart` learns, before the first line, whether the read resumes at the checkpoint or starts over at 0.
    /// Only the bytes present when the file was opened are read. Checks for cancellation between chunks.
    static func read(
        path: String,
        from previous: FileCheckpoint?,
        onStart: (_ resumed: Bool) -> Void = { _ in },
        onLine: (UnsafeRawBufferPointer) -> Void,
        onUnterminatedTail: (UnsafeRawBufferPointer) -> Bool
    ) throws -> Outcome {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw LogReadError(path: path, code: errno) }
        defer { close(descriptor) }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { throw LogReadError(path: path, code: errno) }
        let identity = FileIdentity(info)

        var start: Int64 = 0
        if let previous, previous.offset > 0, previous.identity.isSamePhysicalFile(as: identity),
            identity.size >= previous.offset,
            try boundaryHash(descriptor: descriptor, offset: previous.offset, path: path) == previous.boundaryHash
        {
            start = previous.offset
        }
        onStart(start > 0)

        var position = start
        var committed = start
        var carry: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while position < identity.size {
            try Task.checkCancellation()
            let wanted = Int(min(Int64(chunkSize), identity.size - position))
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, wanted, off_t(position)) }
            if count < 0 {
                if errno == EINTR { continue }
                throw LogReadError(path: path, code: errno)
            }
            if count == 0 { break }  // The file shrank while being read; the next refresh sees the new size.
            buffer.withUnsafeBytes { raw in
                let chunk = UnsafeRawBufferPointer(rebasing: raw[0..<count])
                var lineStart = 0
                while lineStart < count {
                    let base = chunk.baseAddress! + lineStart
                    guard let found = memchr(base, 10, count - lineStart) else {
                        carry.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[lineStart..<count]))
                        break
                    }
                    let newline = lineStart + (UnsafeRawPointer(found) - base)
                    if carry.isEmpty {
                        onLine(UnsafeRawBufferPointer(rebasing: chunk[lineStart..<newline]))
                    } else {
                        carry.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[lineStart..<newline]))
                        carry.withUnsafeBytes { onLine($0) }
                        carry.removeAll(keepingCapacity: true)
                    }
                    committed = position + Int64(newline + 1)
                    lineStart = newline + 1
                }
            }
            position += Int64(count)
        }
        if !carry.isEmpty, carry.withUnsafeBytes({ onUnterminatedTail($0) }) {
            committed = position
        }
        let checkpoint = FileCheckpoint(
            identity: identity, offset: committed,
            boundaryHash: try boundaryHash(descriptor: descriptor, offset: committed, path: path))
        return Outcome(checkpoint: checkpoint, resumed: start > 0, bytesRead: position - start)
    }

    static func boundaryHash(descriptor: Int32, offset: Int64, path: String) throws -> UInt64 {
        let windowStart = max(0, offset - Int64(boundaryWindow))
        let length = Int(offset - windowStart)
        guard length > 0 else { return StableHash.seed }
        var window = [UInt8](repeating: 0, count: length)
        var filled = 0
        while filled < length {
            let count = window.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress! + filled, length - filled, off_t(windowStart) + off_t(filled))
            }
            if count < 0, errno == EINTR { continue }
            if count < 0 { throw LogReadError(path: path, code: errno) }
            // A file now shorter than the checkpoint cannot match: hash what is there.
            if count == 0 { break }
            filled += count
        }
        return window.withUnsafeBytes { StableHash.hash(UnsafeRawBufferPointer(rebasing: $0[0..<filled])) }
    }
}
