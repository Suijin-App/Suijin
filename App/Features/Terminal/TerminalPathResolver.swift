import Foundation
import SevindaGit

/// A terminal path that exists on disk.
struct ResolvedTerminalPath: Equatable, Sendable {
    /// Standardized absolute file URL.
    var url: URL
    var isDirectory: Bool
    var line: Int?
    var column: Int?

    var path: String { url.path }
}

/// Turns paths printed in a terminal into files on disk, and finds the full path of an elided one.
///
/// - `resolve(_:)` checks existence off the main thread, with a small cache (512 entries, 2 s) that file system
///   changes under a watched root also clear (`watch(_:)`), so a scan of the visible rows rarely touches the disk.
/// - `candidates(forElided:in:isGit:)` matches the visible tail of an elided path against the files of a worktree
///   (`git ls-files`, cached until the index changes) or, for a plain folder, a bounded walk of it.
@MainActor
final class TerminalPathResolver {
    /// What to resolve: the path text as printed, and the folders a relative path may be relative to, in order.
    struct Query: Hashable, Sendable {
        var text: String
        var bases: [String]
        var line: Int?
        var column: Int?

        init(text: String, bases: [URL?], line: Int? = nil, column: Int? = nil) {
            self.text = text
            var seen = Set<String>()
            self.bases = bases.compactMap { $0?.standardizedFileURL.path }.filter { seen.insert($0).inserted }
            self.line = line
            self.column = column
        }
    }

    /// A place a printed path may name: an absolute path, with the line suffix split off when there was one.
    struct Location: Equatable, Sendable {
        var path: String
        var line: Int?
        var column: Int?
    }

    let capacity: Int
    let timeToLive: Duration
    private let clock: @Sendable () -> ContinuousClock.Instant
    private struct Entry {
        var result: Probe?
        /// Every absolute path checked, so a change in one of their folders drops the entry.
        var probed: [String]
        var stored: ContinuousClock.Instant
        var used: UInt64
    }
    struct Probe: Equatable, Sendable {
        var path: String
        var isDirectory: Bool
        var line: Int?
        var column: Int?
    }
    private var cache: [CacheKey: Entry] = [:]
    private var useCounter: UInt64 = 0
    private struct CacheKey: Hashable {
        var text: String
        var bases: [String]
    }

    /// The app's resolver: every terminal shares its cache and its watchers.
    static let shared = TerminalPathResolver()

    init(capacity: Int = 512, timeToLive: Duration = .seconds(2),
         clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.capacity = capacity
        self.timeToLive = timeToLive
        self.clock = clock
    }

    // MARK: Parsing

    /// The absolute paths `link` may name, most likely first: as written, then without a `:line[:column]` suffix
    /// (a file can be named `a:1`, so the literal name wins when it exists). `~` expands; `file://` URLs become paths;
    /// relative paths are tried against each base in turn. Web and mail links name no path.
    nonisolated static func locations(for link: String, bases: [String]) -> [Location] {
        guard namesPath(link) else { return [] }
        let raw = link.hasPrefix("file://") ? (URL(string: link)?.path ?? String(link.dropFirst("file://".count))) : link
        var variants: [(String, Int?, Int?)] = [(raw, nil, nil)]
        if let suffix = raw.range(of: #":[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) {
            let numbers = raw[suffix].dropFirst().split(separator: ":").compactMap { Int($0) }
            variants.append((String(raw[..<suffix.lowerBound]), numbers.first, numbers.count > 1 ? numbers[1] : nil))
        }
        var result: [Location] = []
        for (text, line, column) in variants where !text.isEmpty {
            let expanded = (text as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                result.append(Location(path: expanded, line: line, column: column))
            } else {
                for base in bases {
                    result.append(Location(path: URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(expanded).path,
                                           line: line, column: column))
                }
            }
        }
        return result
    }

    /// Whether `link` may name a file: anything but a URL with a scheme other than `file` (`https://…`, `mailto:…`).
    /// `a.swift:12` has no scheme even though URL parsing would read `a.swift` as one.
    nonisolated static func namesPath(_ link: String) -> Bool {
        let lowered = link.lowercased()
        if lowered.hasPrefix("file://") { return true }
        if let separator = lowered.range(of: "://"), !lowered[..<separator.lowerBound].contains("/") { return false }
        return !["mailto:", "tel:", "news:", "magnet:"].contains { lowered.hasPrefix($0) }
    }

    /// The first of `locations(for:bases:)` that exists (blocking file system calls; call off the main thread).
    nonisolated static func probe(_ link: String, bases: [String]) -> (result: Probe?, probed: [String]) {
        var probed: [String] = []
        for location in locations(for: link, bases: bases) {
            probed.append(location.path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) {
                let path = URL(fileURLWithPath: location.path).standardizedFileURL.path
                return (Probe(path: path, isDirectory: isDirectory.boolValue, line: location.line, column: location.column), probed)
            }
        }
        return (nil, probed)
    }

    // MARK: Resolving

    /// Resolves each query, in order: the cached answer when fresh, otherwise a check on disk off the main thread.
    func resolve(_ queries: [Query]) async -> [ResolvedTerminalPath?] {
        let now = clock()
        var answers: [Int: Probe?] = [:]
        var misses: [(Int, CacheKey)] = []
        for (index, query) in queries.enumerated() {
            let key = CacheKey(text: query.text, bases: query.bases)
            if let entry = cache[key], now - entry.stored < timeToLive {
                useCounter += 1
                cache[key]?.used = useCounter
                answers[index] = entry.result
            } else {
                misses.append((index, key))
            }
        }
        if !misses.isEmpty {
            let keys = misses.map(\.1)
            let probes = await Task.detached(priority: .userInitiated) {
                keys.map { TerminalPathResolver.probe($0.text, bases: $0.bases) }
            }.value
            let stored = clock()
            for ((index, key), probe) in zip(misses, probes) {
                answers[index] = probe.result
                useCounter += 1
                cache[key] = Entry(result: probe.result, probed: probe.probed, stored: stored, used: useCounter)
            }
            evictIfNeeded()
        }
        return queries.enumerated().map { index, query in
            guard let probe = answers[index] ?? nil else { return nil }
            // A suffix in the printed text wins over the one the match carried (`a.swift:3` given as text).
            return ResolvedTerminalPath(url: URL(fileURLWithPath: probe.path, isDirectory: probe.isDirectory),
                                        isDirectory: probe.isDirectory, line: probe.line ?? query.line,
                                        column: probe.column ?? (probe.line == nil ? query.column : nil))
        }
    }

    /// One query; see `resolve(_:)`.
    func resolve(_ query: Query) async -> ResolvedTerminalPath? {
        await resolve([query]).first ?? nil
    }

    /// Number of cached answers (tests).
    var cachedCount: Int { cache.count }

    private func evictIfNeeded() {
        guard cache.count > capacity else { return }
        // Drop the least recently used eighth at once, so a full cache does not sort on every insert.
        let drop = cache.count - capacity + capacity / 8
        for key in cache.sorted(by: { $0.value.used < $1.value.used }).prefix(drop).map(\.key) { cache[key] = nil }
    }

    /// Forgets answers that depend on the contents of `folders` (absolute paths), or of anything below `subtrees`.
    func invalidate(folders: Set<String>, subtrees: Set<String> = []) {
        guard !cache.isEmpty, !(folders.isEmpty && subtrees.isEmpty) else { return }
        cache = cache.filter { _, entry in
            !entry.probed.contains { path in
                let parent = (path as NSString).deletingLastPathComponent
                return folders.contains(parent) || folders.contains(path)
                    || subtrees.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            }
        }
    }

    func invalidateAll() {
        cache.removeAll()
        fileLists.removeAll()
    }

    // MARK: Watching

    private var watchers: [String: (watcher: FileSystemWatcher, count: Int)] = [:]

    /// Clears answers below `root` as files change there, until a matching `unwatch(_:)`. Calls are counted, so panes
    /// of the same worktree share one watcher.
    func watch(_ root: URL) {
        let path = root.standardizedFileURL.path
        if let existing = watchers[path] {
            watchers[path] = (existing.watcher, existing.count + 1)
            return
        }
        let watcher = FileSystemWatcher(root: URL(fileURLWithPath: path, isDirectory: true)) { [weak self] change in
            self?.apply(change, root: path)
        }
        watchers[path] = (watcher, 1)
    }

    func unwatch(_ root: URL) {
        let path = root.standardizedFileURL.path
        guard let existing = watchers[path] else { return }
        if existing.count > 1 {
            watchers[path] = (existing.watcher, existing.count - 1)
        } else {
            existing.watcher.stop()
            watchers[path] = nil
        }
    }

    var watchedRoots: Set<String> { Set(watchers.keys) }

    func apply(_ change: FileSystemWatcher.Change, root: String) {
        func absolute(_ relative: String) -> String { relative.isEmpty ? root : root + "/" + relative }
        invalidate(folders: Set(change.folders.map(absolute)), subtrees: Set(change.subtrees.map(absolute)))
        if !change.isEmpty { fileLists[root] = nil }
    }

    // MARK: Elided paths

    /// How many entries a walk of a plain folder visits at most, and the folders it never enters.
    nonisolated static let walkLimit = 50_000
    nonisolated static let skippedFolders: Set<String> = [
        ".git", "node_modules", "build", ".build", "DerivedData", "Pods", ".venv", "venv", "__pycache__", ".next", "dist",
        "target", ".gradle", ".idea",
    ]
    /// The most candidates `candidates(forElided:in:isGit:)` returns.
    nonisolated static let candidateLimit = 20

    private struct FileList {
        var paths: [String]
        var stamp: Date?
        var stored: ContinuousClock.Instant
    }
    private var fileLists: [String: FileList] = [:]

    /// Files of `root` whose path ends like the visible part of `elided` (`…/feature/x.swift`), best match first:
    /// whole path components before partial ones, then shorter paths. At most `candidateLimit`.
    func candidates(forElided elided: String, in root: URL, isGit: Bool) async -> [URL] {
        let rootPath = root.standardizedFileURL.path
        let files = await fileList(rootPath, isGit: isGit)
        return Self.rank(elided: elided, among: files, root: rootPath).map { URL(fileURLWithPath: rootPath).appendingPathComponent($0) }
    }

    /// The relative file paths of `root`: `git ls-files` (tracked and untracked, ignored files left out), reused
    /// until the index changes or 30 s pass; for a plain folder, a walk of at most `walkLimit` entries.
    private func fileList(_ root: String, isGit: Bool) async -> [String] {
        let stamp = isGit ? await Self.indexStamp(root) : nil
        if let cached = fileLists[root], cached.stamp == stamp, clock() - cached.stored < .seconds(30) { return cached.paths }
        let paths: [String]
        if isGit, let listed = try? await GitRunner().run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                                           in: URL(fileURLWithPath: root, isDirectory: true)) {
            paths = listed.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        } else {
            paths = await Task.detached(priority: .userInitiated) { Self.walk(root, limit: Self.walkLimit) }.value
        }
        fileLists[root] = FileList(paths: paths, stamp: stamp, stored: clock())
        return paths
    }

    /// The modification date of the worktree's git index (`.git` may be a file pointing elsewhere, in a worktree).
    nonisolated private static func indexStamp(_ root: String) async -> Date? {
        guard let gitPath = try? await GitRunner().run(["rev-parse", "--git-path", "index"], in: URL(fileURLWithPath: root, isDirectory: true)) else {
            return nil
        }
        var index = String(decoding: gitPath, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !index.hasPrefix("/") { index = root + "/" + index }
        return (try? FileManager.default.attributesOfItem(atPath: index))?[.modificationDate] as? Date
    }

    /// Relative paths of the files below `root`, visiting at most `limit` entries and never entering
    /// `skippedFolders` or hidden folders.
    nonisolated static func walk(_ root: String, limit: Int) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsPackageDescendants]) else { return [] }
        var paths: [String] = []
        var visited = 0
        let prefix = rootURL.standardizedFileURL.path + "/"
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > limit { break }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let name = url.lastPathComponent
            if isDirectory {
                if skippedFolders.contains(name) || name.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(prefix) { paths.append(String(path.dropFirst(prefix.count))) }
        }
        return paths
    }

    /// The parts of an elided path: what precedes the first ellipsis (relative to `root` when it lies inside it) and
    /// what follows the last one. `tailIsPartial` means the ellipsis cut a name, so the tail's first component is the
    /// end of a name.
    nonisolated static func elidedParts(_ elided: String, root: String) -> (head: String, tail: String, tailIsPartial: Bool)? {
        let marks = ["…", "..."]
        guard let first = marks.compactMap({ elided.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }),
              let last = marks.compactMap({ elided.range(of: $0, options: .backwards) }).max(by: { $0.upperBound < $1.upperBound }) else {
            return nil
        }
        var head = String(elided[..<first.lowerBound])
        var tail = String(elided[last.upperBound...])
        let tailIsPartial = !tail.hasPrefix("/")
        while tail.hasPrefix("/") { tail.removeFirst() }
        guard !tail.isEmpty else { return nil }
        head = (head as NSString).expandingTildeInPath
        if head.hasPrefix("/") {
            // An absolute head inside the root narrows the search; one outside it says nothing about the root's files.
            head = head.hasPrefix(root + "/") ? String(head.dropFirst(root.count + 1)) : ""
        }
        if head == "~" || head == "~/" { head = "" }
        return (head, tail, tailIsPartial)
    }

    /// The best matches for `elided` among `files` (relative to `root`).
    nonisolated static func rank(elided: String, among files: [String], root: String, limit: Int = candidateLimit) -> [String] {
        guard let parts = elidedParts(elided, root: root) else { return [] }
        var scored: [(path: String, whole: Bool)] = []
        for file in files where file.hasPrefix(parts.head) && file.count >= parts.head.count + parts.tail.count {
            if file == parts.tail || file.hasSuffix("/" + parts.tail) {
                scored.append((file, true))
            } else if parts.tailIsPartial, file.hasSuffix(parts.tail) {
                scored.append((file, false))
            }
        }
        return scored.sorted { lhs, rhs in
            if lhs.whole != rhs.whole { return lhs.whole }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }.prefix(limit).map(\.path)
    }
}
