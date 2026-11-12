import AppKit
import MercuryGit
import SwiftUI

/// Chooses a folder with the system open panel and adds it as a workspace. Git or plain folder is detected by
/// `AppModel.addWorkspace(at:)`.
@MainActor
enum AddWorkspaceFlow {
    static func run(model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose a git repository or any folder to run agents in.")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls {
                for workspace in await choose(for: url) { await model.addWorkspace(at: workspace) }
            }
        }
    }

    /// A plain folder whose direct subfolders are git repositories (a "projects" folder) can be added as those
    /// repositories, each a git workspace with worktrees and diffs, or as one folder workspace. The user decides.
    private static func choose(for url: URL) async -> [URL] {
        guard await GitRepository.toplevel(of: url) == nil else { return [url] }
        let repositories = repositoriesInside(url)
        guard !repositories.isEmpty else { return [url] }
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(url.lastPathComponent)” contains \(repositories.count) git repositories")
        alert.informativeText = String(localized: "Add each repository as its own workspace to get worktrees, diffs and commits, or add the whole folder and run agents straight in it.")
        alert.addButton(withTitle: String(localized: "Add \(repositories.count) Repositories"))
        alert.addButton(withTitle: String(localized: "Add Folder"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return repositories
        case .alertSecondButtonReturn: return [url]
        default: return []
        }
    }

    /// Direct subfolders that are git repositories (have a `.git` folder or file), sorted by name.
    static func repositoriesInside(_ url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
