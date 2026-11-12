import Darwin
import Foundation

/// What identifies one version of a file on disk: an atomic save (a new file renamed over the old one) changes the
/// inode, an in-place write changes the size or modification time.
struct FileSignature: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modified: timespec
    let changed: timespec

    /// The signature of the file at `path`, or nil when nothing is there.
    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modified = info.st_mtimespec
        changed = info.st_ctimespec
    }

    static func == (lhs: FileSignature, rhs: FileSignature) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
            && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
    }
}

/// The content of a file shown in a viewer tab, kept in step with the disk: a write reloads it, a delete or move shows
/// the missing state, and the file coming back (editors that save by deleting and renaming) loads it again.
/// One FSEvents stream on the file's folder; nothing is read again unless the file's signature changed.
@MainActor
@Observable
final class FileViewerModel {
    let path: String
    private(set) var content: FileViewer.Content = .loading
    /// Bumped each time the content is read again, for views that load the file themselves (the PDF view).
    private(set) var revision = 0

    @ObservationIgnored private var signature: FileSignature?
    @ObservationIgnored private var watcher: FileSystemWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false
    /// How long a vanished file is given to come back before the viewer says it is gone.
    @ObservationIgnored private let missingGrace: Duration

    init(path: String, missingGrace: Duration = .milliseconds(300)) {
        self.path = path
        self.missingGrace = missingGrace
    }

    private var url: URL { URL(fileURLWithPath: path) }

    var isWatching: Bool { watcher?.isWatching == true }

    /// Reads the file and starts following it.
    func start() async {
        if watcher == nil {
            watcher = FileSystemWatcher(root: url.deletingLastPathComponent()) { [weak self] change in
                // Only the folder's own entries matter; changes in its subfolders cannot touch this file.
                guard change.folders.contains("") || !change.subtrees.isEmpty else { return }
                self?.fileMayHaveChanged()
            }
        }
        signature = FileSignature(path: path)
        await read()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Checks the file again; passes requested while one runs are folded into a single follow-up pass.
    func fileMayHaveChanged() {
        guard refreshTask == nil else {
            needsAnotherPass = true
            return
        }
        refreshTask = Task { [weak self] in
            repeat {
                guard let self, !Task.isCancelled else { return }
                self.needsAnotherPass = false
                await self.refresh()
            } while self?.needsAnotherPass == true
            self?.refreshTask = nil
        }
    }

    private func refresh() async {
        guard let current = FileSignature(path: path) else {
            if case .missing = content { return }
            // An editor saving through delete + rename brings the file back a moment later.
            try? await Task.sleep(for: missingGrace)
            guard !Task.isCancelled else { return }
            if FileSignature(path: path) != nil { return await refresh() }
            signature = nil
            content = .missing
            return
        }
        guard current != signature else { return }
        // The signature is taken before reading, so a write that lands during the read triggers one more pass.
        signature = current
        await read()
    }

    private func read() async {
        let url = url
        let fresh = await Task.detached { FileViewer.read(url) }.value
        guard !Task.isCancelled else { return }
        content = fresh
        revision += 1
    }
}
