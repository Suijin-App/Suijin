import CoreServices
import Foundation

/// Watches a directory tree with one FSEvents stream and reports which folders changed, relative to the root.
///
/// The stream uses directory-level events: FSEvents names the folder whose entries or files changed (a create, delete,
/// rename or write inside it), which is exactly what a file tree re-lists and what a viewer needs to re-check its file.
/// Changes are coalesced: a batch is delivered once the tree has been quiet for `quietPeriod`, but never later than
/// `maximumDelay` after its first event, so a folder that never stops changing (a build, a log) still reports.
@MainActor
final class FileSystemWatcher {
    /// Folders that changed since the last delivery, as paths relative to the root ("" is the root itself).
    struct Change: Equatable, Sendable {
        /// Folders whose own entries or files changed.
        var folders: Set<String> = []
        /// Folders whose whole subtree must be checked again: FSEvents dropped or merged events below them. Contains
        /// "" when the root itself was moved, deleted or recreated, or events were lost.
        var subtrees: Set<String> = []

        var isEmpty: Bool { folders.isEmpty && subtrees.isEmpty }

        mutating func merge(_ other: Change) {
            folders.formUnion(other.folders)
            subtrees.formUnion(other.subtrees)
        }
    }

    let root: URL
    private let quietPeriod: Duration
    private let maximumDelay: Duration
    private let onChange: @MainActor (Change) -> Void
    private var stream: StreamHandle?
    private var pending = Change()
    private var lastEvent = ContinuousClock.now
    private var flush: Task<Void, Never>?

    /// Starts watching `root` at once. `latency` is the FSEvents latency in seconds.
    init(root: URL, latency: CFTimeInterval = 0.15, quietPeriod: Duration = .milliseconds(200),
         maximumDelay: Duration = .milliseconds(600), onChange: @escaping @MainActor (Change) -> Void) {
        self.root = root
        self.quietPeriod = quietPeriod
        self.maximumDelay = maximumDelay
        self.onChange = onChange
        stream = StreamHandle(root: root, latency: latency) { [weak self] change in self?.enqueue(change) }
    }

    /// Whether the FSEvents stream is running (false once stopped, or when the system refused to create it).
    var isWatching: Bool { stream != nil }

    /// Stops the stream and drops undelivered changes. Releasing the watcher does the same.
    func stop() {
        flush?.cancel()
        flush = nil
        pending = Change()
        stream = nil
    }

    private func enqueue(_ change: Change) {
        guard stream != nil, !change.isEmpty else { return }
        pending.merge(change)
        lastEvent = .now
        guard flush == nil else { return }
        let started = ContinuousClock.now
        flush = Task { [weak self, quietPeriod, maximumDelay] in
            while true {
                try? await Task.sleep(for: quietPeriod)
                guard !Task.isCancelled, let self else { return }
                let now = ContinuousClock.now
                if now - self.lastEvent >= quietPeriod || now - started >= maximumDelay { break }
            }
            self?.deliver()
        }
    }

    private func deliver() {
        flush = nil
        let change = pending
        pending = Change()
        guard !change.isEmpty else { return }
        onChange(change)
    }
}

extension FileSystemWatcher {
    /// Adds one FSEvents event to `change`. Event paths are canonical (`/private/tmp/…` for `/tmp/…`); they are mapped
    /// back to the root as the caller spelled it, and anything outside the root marks the whole tree for a rescan.
    nonisolated static func record(path: String, flags: FSEventStreamEventFlags, into change: inout FileSystemWatcher.Change,
                                   rootPath: String, canonicalRootPath: String) {
        let rescanFlags = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            change.subtrees.insert("")
            return
        }
        guard let relative = relativePath(of: path, root: canonicalRootPath) ?? relativePath(of: path, root: rootPath) else {
            change.subtrees.insert("")
            return
        }
        if flags & FSEventStreamEventFlags(rescanFlags) != 0 {
            change.subtrees.insert(relative)
        } else {
            change.folders.insert(relative)
        }
    }

    /// `path` relative to `root` ("" for the root itself), or nil when it lies outside. Compared without case, as
    /// APFS volumes usually are.
    nonisolated static func relativePath(of path: String, root: String) -> String? {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard let range = path.range(of: root, options: [.anchored, .caseInsensitive]) else { return nil }
        let rest = path[range.upperBound...]
        if rest.isEmpty { return "" }
        guard rest.hasPrefix("/") else { return nil }
        return String(rest.dropFirst())
    }
}

/// Owns the FSEvents stream: stopped, invalidated and released on deinit, so a watcher can never leak its stream or
/// receive a callback after it is gone. The stream retains its `Sink`, which holds the handler.
private final class StreamHandle {
    private let stream: FSEventStreamRef

    /// Delivers decoded events on the main queue. Unchecked: its properties are immutable and the handler is only
    /// called on the main queue, where the stream is scheduled.
    private final class Sink: @unchecked Sendable {
        let rootPath: String
        let canonicalRootPath: String
        let handler: @MainActor (FileSystemWatcher.Change) -> Void

        init(rootPath: String, canonicalRootPath: String, handler: @escaping @MainActor (FileSystemWatcher.Change) -> Void) {
            self.rootPath = rootPath
            self.canonicalRootPath = canonicalRootPath
            self.handler = handler
        }
    }

    init?(root: URL, latency: CFTimeInterval, handler: @escaping @MainActor (FileSystemWatcher.Change) -> Void) {
        let rootPath = root.standardizedFileURL.path
        let sink = Sink(rootPath: rootPath, canonicalRootPath: Self.canonicalPath(rootPath), handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Sink>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Sink>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes: the paths arrive as a CFArray of CFString.
            let list = unsafeBitCast(paths, to: NSArray.self)
            var change = FileSystemWatcher.Change()
            for index in 0..<count {
                guard let path = list[index] as? String else { continue }
                FileSystemWatcher.record(path: path, flags: flags[index], into: &change,
                                    rootPath: sink.rootPath, canonicalRootPath: sink.canonicalRootPath)
            }
            // The stream is scheduled on the main queue.
            MainActor.assumeIsolated { sink.handler(change) }
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(flags)
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// The path with every symbolic link resolved (FSEvents reports `/private/tmp`, not `/tmp`).
    nonisolated static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
