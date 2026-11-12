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
