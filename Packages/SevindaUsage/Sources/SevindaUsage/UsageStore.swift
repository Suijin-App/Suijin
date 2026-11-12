import Darwin
import Foundation

public enum UsageStoreError: Error, Sendable, Equatable, LocalizedError {
    /// The cache URL lies inside a log folder, which Sevinda never writes to.
    case cacheInsideLogFolder(String)
    /// The cache could not be written (errno); the returned usage is still valid in memory.
    case cacheWriteFailed(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .cacheInsideLogFolder(let path): "The usage cache cannot be stored inside the log folder \(path)."
        case .cacheWriteFailed(let path, let code): "Could not save the usage cache at \(path): \(String(cString: strerror(code)))."
        }
    }
}

/// Owns the aggregated usage and refreshes it from the logs.
///
/// A refresh lists the log files, skips every file whose size, modification time and inode are unchanged, and reads
/// only the bytes appended since its checkpoint (a truncated or replaced file is read again from the start). Files
/// are read in parallel, at most `maxConcurrentReads` at a time, off the caller's actor; results are merged in path
/// order so deduplication is deterministic. The cache is saved after each refresh, including a cancelled one (what was
/// merged so far is kept).
public actor UsageStore {
    public let cacheURL: URL
    public private(set) var sources: UsageSourceSet
    let maxConcurrentReads: Int

    private var ledger = UsageLedger()
    private var loaded = false
    private var unreadableFiles = 0
    private var inFlight: Task<UsageSnapshot, Error>?

    public init(cacheURL: URL, sources: UsageSourceSet) {
        self.cacheURL = cacheURL
        self.sources = sources
        maxConcurrentReads = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    /// Use when managed accounts change; the next refresh reads the new roots.
    public func updateSources(_ sources: UsageSourceSet) { self.sources = sources }

    /// What the cache file holds, without reading any log; nil when there is no usable cache yet.
    public func cachedSnapshot() -> UsageSnapshot? {
        loadIfNeeded()
        return ledger.updatedAt == nil ? nil : ledger.snapshot(unreadableFiles: unreadableFiles)
    }

    /// Reads what changed in the logs and returns the updated usage. `progress` receives 0…1 (share of the bytes to
    /// read) from a background thread. A second call while one runs joins it. Cancelling the calling task stops the
    /// scan and throws `CancellationError`.
    public func refresh(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> UsageSnapshot {
        if let inFlight {
            return try await Self.join(inFlight)
        }
        let task = Task { try await self.performRefresh(progress: progress) }
        inFlight = task
        defer { inFlight = nil }
        return try await Self.join(task)
    }

    private static func join(_ task: Task<UsageSnapshot, Error>) async throws -> UsageSnapshot {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    // MARK: Refresh

    private struct Job: Sendable {
        let file: DiscoveredLogFile
        let previous: FileState?
    }

    private enum JobOutcome: Sendable {
        case scanned(FileScanResult)
        /// Gone between discovery and reading.
        case vanished
        case unreadable
    }

    private func performRefresh(progress: @escaping @Sendable (Double) -> Void) async throws -> UsageSnapshot {
        loadIfNeeded()
        try checkCacheLocation()
        progress(0)
        let timeZone = TimeZone.current
        let discovered = UsageFileDiscovery.discover(sources)
        try Task.checkCancellation()

        var dirty = ledger.dropFiles(notIn: Set(discovered.map(\.path)))
        let jobs = discovered.compactMap { file -> Job? in
            let previous = ledger.files[file.path]
            if let previous, previous.provider == file.provider, previous.checkpoint.identity == file.identity {
                return nil
            }
            return Job(file: file, previous: previous)
        }
        let totalBytes = max(
            1,
            jobs.reduce(Int64(0)) { sum, job in
                let start = job.previous.map { state in
                    state.checkpoint.identity.isSamePhysicalFile(as: job.file.identity)
                        && job.file.identity.size >= state.checkpoint.offset ? state.checkpoint.offset : 0
                } ?? 0
                return sum + job.file.identity.size - start
            })

        var unreadable = 0
        var doneBytes: Int64 = 0
        do {
            try await withThrowingTaskGroup(of: (Int, JobOutcome).self) { group in
                var next = 0
                func startNext() {
                    guard next < jobs.count else { return }
                    let index = next
                    let job = jobs[index]
                    next += 1
                    group.addTask { (index, try Self.scan(job, timeZone: timeZone)) }
                }
                for _ in 0..<min(maxConcurrentReads, jobs.count) { startNext() }
                var finished: [Int: JobOutcome] = [:]
                var mergeIndex = 0
                while let (index, outcome) = try await group.next() {
                    finished[index] = outcome
                    startNext()
                    while let ready = finished.removeValue(forKey: mergeIndex) {
                        switch ready {
                        case .scanned(let result):
                            ledger.apply(result)
                            doneBytes += result.outcome.bytesRead
                            dirty = true
                        case .vanished:
                            if ledger.files.removeValue(forKey: jobs[mergeIndex].file.path) != nil { dirty = true }
                        case .unreadable:
                            unreadable += 1
                        }
                        mergeIndex += 1
                        progress(min(1, Double(doneBytes) / Double(totalBytes)))
                    }
                }
            }
        } catch {
            // Keep what was merged; files not merged keep their old checkpoints and are read next time.
            if dirty { try? save() }
            throw error
        }

        unreadableFiles = unreadable
        ledger.updatedAt = Date()
        if dirty || !FileManager.default.fileExists(atPath: cacheURL.path) { try save() }
        progress(1)
        return ledger.snapshot(unreadableFiles: unreadableFiles)
    }

    /// Reads one file from its checkpoint. Runs on the global executor, never on the actor.
    private nonisolated static func scan(_ job: Job, timeZone: TimeZone) throws -> JobOutcome {
        let path = job.file.path
        let checkpoint = job.previous?.provider == job.file.provider ? job.previous?.checkpoint : nil
        do {
            switch job.file.provider {
            case .claude:
                var parser = ClaudeFileParser(path: path, timeZone: timeZone)
                let outcome = try JSONLTailReader.read(
                    path: path, from: checkpoint, onLine: { parser.consume($0) },
                    onUnterminatedTail: { parser.consumeTail($0) })
                return .scanned(
                    FileScanResult(
                        path: path, provider: .claude, outcome: outcome, turns: parser.turns,
                        skippedLines: parser.skippedLines, codex: nil))
            case .codex:
                // The saved context only applies when the read resumes at the checkpoint.
                var parser = CodexFileParser(context: CodexContext(path: path), timeZone: timeZone)
                let outcome = try JSONLTailReader.read(
                    path: path, from: checkpoint,
                    onStart: { resumed in
                        if resumed, let context = job.previous?.codex {
                            parser = CodexFileParser(context: context, timeZone: timeZone)
                        }
                    },
                    onLine: { parser.consume($0) }, onUnterminatedTail: { parser.consumeTail($0) })
                return .scanned(
                    FileScanResult(
                        path: path, provider: .codex, outcome: outcome, turns: parser.turns,
                        skippedLines: parser.skippedLines, codex: parser.context))
            }
        } catch let error as LogReadError {
            return error.isMissing ? .vanished : .unreadable
        }
    }

    // MARK: Cache

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        // A missing, unreadable or corrupt cache, or one from another format, is rebuilt from the logs.
        guard let data = try? Data(contentsOf: cacheURL),
            let file = try? JSONDecoder().decode(UsageCacheFile.self, from: data), let restored = file.ledger()
        else { return }
        ledger = restored
    }

    private func checkCacheLocation() throws {
        let cache = cacheURL.standardizedFileURL.resolvingSymlinksInPath().path
        for (_, root) in sources.resolvedRoots where cache == root.path || cache.hasPrefix(root.path + "/") {
            throw UsageStoreError.cacheInsideLogFolder(root.path)
        }
    }

    /// Writes the cache atomically: a 600 temporary file in a 700 directory, then a rename over the old cache.
    private func save() throws {
        let directory = cacheURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw UsageStoreError.cacheWriteFailed(path: directory.path, code: EACCES)
        }
        guard chmod(directory.path, 0o700) == 0 else {
            throw UsageStoreError.cacheWriteFailed(path: directory.path, code: errno)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(UsageCacheFile(ledger))
        } catch {
            throw UsageStoreError.cacheWriteFailed(path: cacheURL.path, code: EINVAL)
        }
        let temporary = directory.appendingPathComponent(".\(cacheURL.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UsageStoreError.cacheWriteFailed(path: temporary.path, code: errno) }
        var failure: Int32 = 0
        data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let count = write(descriptor, raw.baseAddress! + written, raw.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                written += count
            }
        }
        if failure == 0, fchmod(descriptor, 0o600) != 0 { failure = errno }
        close(descriptor)
        if failure == 0, rename(temporary.path, cacheURL.path) != 0 { failure = errno }
        if failure != 0 {
            unlink(temporary.path)
            throw UsageStoreError.cacheWriteFailed(path: cacheURL.path, code: failure)
        }
    }
}
