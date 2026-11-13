import Foundation

/// Follows a session's hook events file and emits each newly completed line as a `ClaudeHookEvent`.
///
/// - The file may not exist yet: the parent directory is watched until it appears.
/// - Only complete lines are consumed; a partially written last line is read again once finished.
/// - Truncation (size below the read offset) restarts from the beginning; deletion or rename
///   returns to watching the directory for a new file.
///
/// All state lives on a private serial queue, which is why the class can be `@unchecked Sendable`.
/// `handler` is called on that queue.
public final class HookEventWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([ClaudeHookEvent]) -> Void

    public let fileURL: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.tekmium.suijin.hook-event-watcher")
    private var offset: UInt64 = 0
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var isRunning = false

    /// - Parameter readExisting: emit events already in the file (true) or only ones appended after start.
    public init(fileURL: URL, readExisting: Bool = true, handler: @escaping Handler) {
        self.fileURL = fileURL
        self.handler = handler
        if !readExisting {
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)??.uint64Value
            offset = size ?? 0
        }
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }

    public func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            openFileOrWatchDirectory()
        }
    }

    /// Stops watching. Must not be called from `handler` (it synchronizes with the watcher queue).
    public func stop() {
        queue.sync { [self] in
            isRunning = false
            closeFile()
            directorySource?.cancel()
            directorySource = nil
        }
    }

    // MARK: Queue-confined

    private func openFileOrWatchDirectory() {
        guard isRunning else { return }
        if openFile() { return }
        watchDirectory()
        // The file may have appeared between the failed open and the directory watch.
        if openFile() {
            directorySource?.cancel()
            directorySource = nil
        }
    }

    private func openFile() -> Bool {
        guard fileSource == nil else { return true }
        let descriptor = open(fileURL.path, O_RDONLY | O_EVTONLY)
        guard descriptor >= 0 else { return false }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            close(descriptor)
            return false
        }
        fileHandle = handle
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, let current = self.fileSource else { return }
            let events = current.data
            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                self.readAvailable()
                self.closeFile()
                self.offset = 0
                self.openFileOrWatchDirectory()
            } else {
                self.readAvailable()
            }
        }
        source.setCancelHandler { close(descriptor) }
        fileSource = source
        source.resume()
        readAvailable()
        return true
    }

    private func closeFile() {
        fileSource?.cancel()
        fileSource = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func watchDirectory() {
        guard directorySource == nil else { return }
        let directory = fileURL.deletingLastPathComponent()
        // A directory created here is private (event files hold prompt text); an existing one is left as is.
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.isRunning, self.openFile() else { return }
            self.directorySource?.cancel()
            self.directorySource = nil
        }
        source.setCancelHandler { close(descriptor) }
        directorySource = source
        source.resume()
    }

    private func readAvailable() {
        guard isRunning, let handle = fileHandle else { return }
        do {
            let size = try handle.seekToEnd()
            if size < offset { offset = 0 }
            guard size > offset else { return }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: Int(size - offset)), !data.isEmpty else { return }
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
            let complete = data[data.startIndex...lastNewline]
            offset += UInt64(complete.count)
            let events = ClaudeHooks.parseEvents(Data(complete))
            if !events.isEmpty { handler(events) }
        } catch {
            // A read error leaves the offset unchanged; the next file event retries.
        }
    }
}
