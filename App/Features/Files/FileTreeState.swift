import Foundation

extension AppModel {
    private static let expandedFoldersKey = "fileTree.expandedFolders"

    /// The folders expanded in `context`'s file tree. The first time a context asks, the folders saved at the last
    /// quit are restored, minus those that no longer exist.
    func expandedFolders(in context: SessionContext) -> Set<String> {
        if let folders = expandedFoldersCache[context] { return folders }
        let saved = (UserDefaults.standard.dictionary(forKey: Self.expandedFoldersKey)?[context.storageValue] as? [String]) ?? []
        let folders = Set(saved.filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        })
        expandedFoldersCache[context] = folders
        return folders
    }

    /// Replaces the expanded folders of `context`'s file tree and saves them.
    func setExpandedFolders(_ folders: Set<String>, in context: SessionContext) {
        expandedFoldersCache[context] = folders
        var saved = UserDefaults.standard.dictionary(forKey: Self.expandedFoldersKey) ?? [:]
        saved[context.storageValue] = folders.isEmpty ? nil : folders.sorted()
        UserDefaults.standard.set(saved, forKey: Self.expandedFoldersKey)
    }
}

/// A file or folder of a context's directory. Folders list their contents the first time they are asked, so a large
/// repository costs one directory read per folder the user opens.
/// Used only on the main thread (by `FileTree` and the views).
final class FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
    private(set) var loaded: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// Folder contents, folders first then by name; nil for a file (no disclosure triangle).
    var children: [FileNode]? {
        guard isDirectory else { return nil }
        if let loaded { return loaded }
        let nodes = Self.list(url)
        loaded = nodes
        return nodes
    }

    /// Reads a loaded folder again. Entries still there keep their node (and its loaded contents), so rows keep their
    /// identity. Returns whether the entries changed; a folder never listed stays unread.
    @discardableResult
    func reload() -> Bool {
        guard isDirectory, let old = loaded else { return false }
        let existing = Dictionary(old.map { (EntryKey(name: $0.name, isDirectory: $0.isDirectory), $0) },
                                  uniquingKeysWith: { first, _ in first })
        let fresh = Self.list(url).map { existing[EntryKey(name: $0.name, isDirectory: $0.isDirectory)] ?? $0 }
        loaded = fresh
        return fresh.map(\.url) != old.map(\.url) || fresh.map(\.isDirectory) != old.map(\.isDirectory)
    }

    /// Forgets the contents, which are read again the next time they are asked for.
    func unload() { loaded = nil }

    private struct EntryKey: Hashable {
        let name: String
        let isDirectory: Bool
    }

    private static func list(_ url: URL) -> [FileNode] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: []
        )) ?? []
        return entries
            .filter { !hiddenNames.contains($0.lastPathComponent) }
            .map { entry in
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                // Packages (an `.app`, an `.xcodeproj`) open as files, as in Finder. The child's path is built on this
                // folder's own path: the listing may spell it differently (`/private/tmp` for `/tmp`), and revealing a
                // path compares strings.
                return FileNode(url: url.appendingPathComponent(entry.lastPathComponent),
                                isDirectory: values?.isDirectory == true && values?.isPackage != true)
            }
            .sorted { lhs, rhs in
                lhs.isDirectory != rhs.isDirectory ? lhs.isDirectory : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Never useful to browse.
    static let hiddenNames: Set<String> = [".git", ".DS_Store"]
}

/// The file tree of one folder, kept current while it is watched: files and folders created, deleted or renamed by
/// anything (Finder, an editor, an agent's shell) show up without a reload. Only folders the tree has already read are
/// refreshed, and only those on screen are read again: a change deep in an unopened `node_modules` costs nothing.
@MainActor
@Observable
final class FileTree {
    @ObservationIgnored let root: FileNode
    /// Bumped whenever the shown entries change; views read it through `roots`.
    private(set) var revision = 0
    /// The folders expanded in the view, as absolute paths.
    @ObservationIgnored private let expandedFolders: @MainActor () -> Set<String>
    @ObservationIgnored private var watcher: FileSystemWatcher?

    init(directory: URL, expandedFolders: @escaping @MainActor () -> Set<String>) {
        root = FileNode(url: directory.standardizedFileURL, isDirectory: true)
        self.expandedFolders = expandedFolders
    }

    /// The root folder's entries.
    var roots: [FileNode] {
        _ = revision
        return root.children ?? []
    }

    /// Whether the root folder exists (it may have been deleted or moved while shown).
    var rootExists: Bool {
        _ = revision
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var isWatching: Bool { watcher?.isWatching == true }

    func startWatching() {
        guard watcher == nil else { return }
        watcher = FileSystemWatcher(root: root.url) { [weak self] change in self?.apply(change) }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Reads every loaded folder again (the reload button).
    func reloadAll() {
        _ = refresh(root, subtree: true, expanded: expandedFolders())
        revision += 1
    }

    /// Refreshes the loaded folders a change touched. Events under `.git` are noise for a tree that hides `.git`; a
    /// branch switch still shows through the working files it rewrites.
    func apply(_ change: FileSystemWatcher.Change) {
        let expanded = expandedFolders()
        var changed = false
        for path in change.subtrees where !Self.isInsideGit(path) {
            changed = refresh(nearestLoadedFolder(at: path), subtree: true, expanded: expanded) || changed
        }
        for path in change.folders where !Self.isInsideGit(path) {
            guard let node = loadedFolder(at: path) else { continue }
            changed = refresh(node, subtree: false, expanded: expanded) || changed
        }
        if changed { revision += 1 }
    }

    /// Re-reads `node` when it is on screen, or forgets its contents when it is not (they are read again when its
    /// folder opens). With `subtree`, does the same for every loaded folder below it.
    private func refresh(_ node: FileNode, subtree: Bool, expanded: Set<String>) -> Bool {
        guard node.loaded != nil else { return false }
        guard isShown(node, expanded: expanded) else {
            node.unload()
            return true
        }
        var changed = node.reload()
        if subtree {
            for child in node.loaded ?? [] where child.loaded != nil {
                changed = refresh(child, subtree: true, expanded: expanded) || changed
            }
        }
        return changed
    }

    /// Whether `node`'s entries are rows of the tree: the root, or a folder expanded with all its ancestors.
    private func isShown(_ node: FileNode, expanded: Set<String>) -> Bool {
        var path = node.url.path
        let rootPath = root.url.path
        while path.count > rootPath.count {
            guard expanded.contains(path) else { return false }
            path = (path as NSString).deletingLastPathComponent
        }
        return true
    }

    /// The loaded folder at a path relative to the root, walking only folders already read.
    private func loadedFolder(at relativePath: String) -> FileNode? {
        var node = root
        for component in relativePath.split(separator: "/") {
            guard let next = node.loaded?.first(where: { $0.isDirectory && $0.name == component }) else { return nil }
            node = next
        }
        return node.loaded == nil ? nil : node
    }

    /// The deepest loaded folder on the way to a path relative to the root.
    private func nearestLoadedFolder(at relativePath: String) -> FileNode {
        var node = root
        for component in relativePath.split(separator: "/") {
            guard let next = node.loaded?.first(where: { $0.isDirectory && $0.name == component }), next.loaded != nil else { break }
            node = next
        }
        return node
    }

    static func isInsideGit(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains(".git")
    }
}
