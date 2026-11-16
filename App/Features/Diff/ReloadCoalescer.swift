import Foundation

/// Runs one reload at a time. A request that arrives while a run is in progress is remembered, and exactly one more
/// run follows it, so a burst of file changes costs at most two runs and the last one reads the latest state. git
/// calls cannot be cancelled, so starting a new run beside a slow one would only pile up processes.
@MainActor
final class ReloadCoalescer {
    private let operation: @MainActor () async -> Void
    private var isRunning = false
    private var isPending = false
    private var isStopped = false

    init(_ operation: @escaping @MainActor () async -> Void) {
        self.operation = operation
    }

    /// Asks for a reload: starts one now, or marks one to follow the run in progress.
    func request() {
        guard !isStopped else { return }
        guard !isRunning else {
            isPending = true
            return
        }
        isRunning = true
        Task {
            repeat {
                isPending = false
                await operation()
            } while isPending && !isStopped
            isRunning = false
        }
    }

    /// Drops a pending run and refuses new requests; a run in progress finishes.
    func stop() {
        isStopped = true
        isPending = false
    }
}

extension ReloadCoalescer {
    /// Folders under `.git` that change without changing what the Changes tab lists: new objects and reflogs. A commit,
    /// a checkout or `git add` also writes `HEAD`, `refs/` or `index`, and those still cause a reload.
    static let ignoredFolders = [".git/objects", ".git/logs"]

    /// Whether `change` can alter the files or commits the Changes tab shows. A rescan of the whole tree (the empty
    /// path) matches no ignored folder, so it always counts.
    static func matters(_ change: FileSystemWatcher.Change) -> Bool {
        change.folders.union(change.subtrees).contains { path in
            !ignoredFolders.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }
}
