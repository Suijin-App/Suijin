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

    /// Closes a file tab. Unsaved Markdown edits are dropped: callers that act for the user go through
    /// `requestCloseFile`, which asks first.
    func closeFile(_ path: String, in context: SessionContext) {
        openFiles[context]?.removeAll { $0 == path }
        mediaPositions[MediaPositionKey(context: context, path: path)] = nil
        let key = FileTabKey(context: context, path: path)
        let discardsEdits = markdownSessions[key]?.isDirty == true
        markdownSessions[key] = nil
        if let book = markdownBooks[key] {
            if discardsEdits, let text = (try? MarkdownFile.read(URL(fileURLWithPath: path)))?.text {
                // The comments moved with edits that are now thrown away: find them in the file as it is on disk.
                book.textReplaced(text)
            } else {
                // Positions that moved while typing are written before the comments leave memory.
                book.saveMovedAnchors()
            }
        }
        markdownBooks[key] = nil
        if selectedTab[context] == .file(path) { selectedTab[context] = nil }
    }

    /// Closes a file tab the user asked to close; a Markdown file with unsaved changes asks to save them first.
    func requestCloseFile(_ path: String, in context: SessionContext) {
        let key = FileTabKey(context: context, path: path)
        if markdownSessions[key]?.isDirty == true {
            selection = context
            selectedTab[context] = .file(path)
            pendingFileClose = key
        } else {
            closeFile(path, in: context)
        }
    }

    /// The editing state of a Markdown tab; with `create`, made on first use (nil when the file is not UTF-8 text).
    func markdownSession(for path: String, in context: SessionContext, create: Bool = false) -> MarkdownEditSession? {
        let key = FileTabKey(context: context, path: path)
        if let session = markdownSessions[key] { return session }
        guard create, let session = MarkdownEditSession(path: path) else { return nil }
        markdownSessions[key] = session
        markdownBooks[key]?.attach(session)
        return session
    }

    /// The path of the selected tab when it shows a Markdown file in the main window.
    var activeMarkdownFile: FileTabKey? {
        guard isMainWindowKey, let context = selection, case .file(let path)? = currentTab(in: context),
              FileViewer.isMarkdown(path) else { return nil }
        return FileTabKey(context: context, path: path)
    }

    /// The editing state of the selected Markdown tab, if it was ever edited.
    var activeMarkdownSession: MarkdownEditSession? {
        activeMarkdownFile.flatMap { markdownSessions[$0] }
    }

    /// Switches the selected Markdown tab between reading and editing.
    func toggleMarkdownEditing() {
        guard let key = activeMarkdownFile, let session = markdownSession(for: key.path, in: key.context, create: true) else { return }
        session.mode = session.mode == .edit ? .read : .edit
    }

    /// Markdown tabs with unsaved changes, in every context.
    var unsavedMarkdownSessions: [MarkdownEditSession] {
        markdownSessions.values.filter(\.isDirty).sorted { $0.path < $1.path }
    }

    /// Asks what to do with unsaved Markdown changes before the app quits. Returns whether quitting may go on.
    func confirmQuitWithUnsavedFiles() -> Bool {
        let unsaved = unsavedMarkdownSessions
        guard !unsaved.isEmpty else { return true }
        let alert = NSAlert()
        if unsaved.count == 1, let session = unsaved.first {
            alert.messageText = String(localized: "Save changes to “\((session.path as NSString).lastPathComponent)” before quitting?")
        } else {
            alert.messageText = String(localized: "Save changes to \(unsaved.count) Markdown files before quitting?")
        }
        alert.informativeText = String(localized: "Your changes are lost if you don’t save them.")
        alert.addButton(withTitle: unsaved.count == 1 ? String(localized: "Save") : String(localized: "Save All"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don’t Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // A save that fails or meets a newer version on disk keeps the app open, on that file.
            for session in unsaved where !session.save() {
                if let key = markdownSessions.first(where: { $0.value === session })?.key {
                    selection = key.context
                    selectedTab[key.context] = .file(key.path)
                }
                return false
            }
            return true
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    /// Handles a link ⌘-clicked in a terminal of `context`: files open in a viewer tab (Finder only for files Suijin
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
    /// Suijin cannot show it.
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

    /// Opens a file in a viewer tab, or shows it in Finder when Suijin cannot display it (binary, unknown format).
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
