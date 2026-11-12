import AppKit
import Foundation

/// Files opened in tabs from ⌘-clicked terminal links.
extension AppModel {
    /// Opens `path` in a tab of `context`, or selects it when it is already open.
    func openFile(_ path: String, in context: SessionContext) {
        if !(openFiles[context] ?? []).contains(path) { openFiles[context, default: []].append(path) }
        selection = context
        selectedTab[context] = .file(path)
    }

    func closeFile(_ path: String, in context: SessionContext) {
        openFiles[context]?.removeAll { $0 == path }
        mediaPositions[MediaPositionKey(context: context, path: path)] = nil
        if selectedTab[context] == .file(path) { selectedTab[context] = nil }
    }

    /// Handles a link ⌘-clicked in a terminal of `context`: files open in a viewer tab (Finder only for files Sevinda
    /// cannot show), folders in the inspector's file tree; web and mail links return `false` so the terminal opens
    /// them in their default app. Relative paths are resolved against `directory`, the session's working directory; a
    /// `:line` or `:line:column` suffix is split off (`TerminalPathResolver.locations(for:bases:)`).
    func openTerminalLink(_ link: String, in context: SessionContext, relativeTo directory: URL?) -> Bool {
        openTerminalLink(link, in: context, relativeTo: [directory])
    }

    /// As above, a relative path tried against each of `directories` in turn (the shell's reported directory, the
    /// session's, the worktree's root).
    func openTerminalLink(_ link: String, in context: SessionContext, relativeTo directories: [URL?]) -> Bool {
        guard TerminalPathResolver.namesPath(link) else { return false }
        let bases = TerminalPathResolver.Query(text: link, bases: directories).bases
        guard let probe = TerminalPathResolver.probe(link, bases: bases).result else { return true }
        openTerminalPath(ResolvedTerminalPath(url: URL(fileURLWithPath: probe.path, isDirectory: probe.isDirectory),
                                              isDirectory: probe.isDirectory, line: probe.line, column: probe.column),
                         in: context)
        return true
    }

    /// Opens a path from a terminal in the app: a folder in the inspector's file tree (the inspector opens on its Files
    /// tab), a file in a viewer tab (at its line, when the path named one and the viewer shows code), or in Finder when
    /// Sevinda cannot show it.
    func openTerminalPath(_ resolved: ResolvedTerminalPath, in context: SessionContext) {
        let standardized = resolved.url.standardizedFileURL
        if resolved.isDirectory {
            UserDefaults.standard.set(true, forKey: "inspector.shown")
            revealInFileTree(standardized.path)
        } else {
            // The tree follows only while the inspector is open; closed, nothing moves there.
            let wasOpen = isInspectorOpen
            guard open(fileAt: standardized, in: context) else { return }
            if wasOpen { revealInFileTree(standardized.path) }
            if let line = resolved.line, line > 0 { fileLineReveal = (standardized.path, line, UUID()) }
        }
    }

    /// Opens a file in a viewer tab, or shows it in Finder when Sevinda cannot display it (binary, unknown format).
    /// Returns whether it opened in the app.
    @discardableResult
    func open(fileAt url: URL, in context: SessionContext) -> Bool {
        if case .unsupported = FileViewer.read(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return false
        }
        openFile(url.path, in: context)
        return true
    }

    /// Whether the window shows the inspector (its own preference, also read by `RootView`).
    var isInspectorOpen: Bool {
        UserDefaults.standard.object(forKey: "inspector.shown") as? Bool ?? true
    }

    /// Shows `path` in the inspector's file tree, switching the inspector to its Files tab.
    func revealInFileTree(_ path: String) {
        UserDefaults.standard.set("files", forKey: "inspector.tab")
        fileTreeReveal = (path, UUID())
    }
}
