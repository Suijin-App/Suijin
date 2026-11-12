import SevindaCore
import SevindaDiff
import SevindaGit
import SevindaUI
import SwiftUI

/// Changes of a git context: changed files on the left, the selected file's diff (unified or side by side) on the
/// right, with line notes for the agent. Refreshes when files in the checkout change. A folder workspace shows how to
/// turn it into a repository instead.
struct DiffScreen: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext

    var body: some View {
        if let directory = model.directory(of: context), isGit {
            ChangesView(context: context, directory: directory, base: baseBranch)
                .id(directory)
        } else {
            FolderWithoutGitView(context: context)
        }
    }

    private var isGit: Bool {
        guard let id = model.workspaceID(of: context) else { return false }
        return model.workspace(id)?.kind == .git
    }

    private var baseBranch: String? {
        if case .worktree(let id) = context { return model.worktree(id)?.baseBranch }
        return nil
    }
}

private struct ChangesView: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext
    let directory: URL
    let base: String?

    @State private var uncommitted: [ChangedFile] = []
    @State private var committed: [ChangedFile] = []
    /// The branch the committed group is measured against (the worktree's base, else origin's default branch).
    @State private var resolvedBase: String?
    @State private var commitsAhead: Int?
    @State private var commits: [CommitSummary] = []
    /// The commit the committed group is narrowed to; nil shows all of them.
    @State private var selectedCommit: String?
    @State private var commitFiles: [ChangedFile] = []
    @State private var selection: ChangeSelection?
    @State private var diff: FileDiff?
    @State private var diffError: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var watcher: FileSystemWatcher?
    @State private var book: DiffNotesBook?
    @State private var showsUnsentOnly = false
    @State private var diffWidth: CGFloat = 0
    @AppStorage(DiffNotePreferences.layoutKey) private var layout: DiffDisplayMode = .unified

    /// Side by side only when the pane is wide enough to read two columns.
    private var effectiveLayout: DiffDisplayMode {
        layout == .sideBySide && diffWidth > 0 && diffWidth < SideBySideDiffView.minimumWidth ? .unified : layout
    }

    /// The two groups as listed: with the Unsent filter, only files that have unsent notes.
    private var sections: [ChangeSection] {
        let base = resolvedBase ?? String(localized: "the base branch")
        let filter: ([ChangedFile]) -> [ChangedFile] = { files in
            guard showsUnsentOnly, let book else { return files }
            let paths = Set(book.unsent.map(\.filePath))
            return files.filter { paths.contains($0.path) }
        }
        let commits: Text = switch commitsAhead {
        case 1?: Text("1 commit not on \(base)")
        case let count?: Text("\(count) commits not on \(base)")
        case nil: Text("Not on \(base)")
        }
        let files: Text = uncommitted.count == 1 ? Text("1 file") : Text("\(uncommitted.count) files")
        return [
            ChangeSection(group: .uncommitted, title: Text("Uncommitted"), detail: files, files: filter(uncommitted)),
            ChangeSection(group: .committed, title: Text("Committed"), detail: commits,
                          files: filter(selectedCommit == nil ? committed : commitFiles), commits: self.commits),
        ]
    }

    private var listedSelections: [ChangeSelection] {
        sections.flatMap { section in section.files.map { ChangeSelection(group: section.group, path: $0.path) } }
    }

    private var noteCounts: [String: Int] {
        guard let book else { return [:] }
        let notes = showsUnsentOnly ? book.unsent : book.notes
        return notes.reduce(into: [:]) { $0[$1.filePath, default: 0] += 1 }
    }

    var body: some View {
        HSplitView {
            ChangedFilesList(sections: sections, selection: $selection, isLoading: isLoading, error: error,
                             emptyDescription: Text("Nothing uncommitted, and no commits that \(resolvedBase ?? String(localized: "the base branch")) does not have."),
                             noteCounts: noteCounts, isFilteredToUnsent: showsUnsentOnly, selectedCommit: $selectedCommit)
                .frame(minWidth: 200, idealWidth: 260, maxWidth: 340)
            Group {
                if let diffError {
                    ContentUnavailableView("Cannot Show the Diff", systemImage: "exclamationmark.triangle",
                                           description: Text(verbatim: diffError))
                } else if let diff {
                    VStack(spacing: 0) {
                        DiffFileNotesHeader(diff: diff, book: book, showsUnsentOnly: showsUnsentOnly,
                                            layout: effectiveLayout, isNarrowFallback: effectiveLayout != layout,
                                            scope: noteScope)
                        DiffDocumentView(diff: diff, language: SyntaxHighlighter.language(forPath: diff.displayPath),
                                         mode: effectiveLayout, notes: notesConfiguration(for: diff))
                    }
                } else if selection == nil {
                    ContentUnavailableView("No File Selected", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Choose a changed file to see its diff."))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { diffWidth = $0 }
        }
        .toolbar {
            ToolbarItem {
                Picker("Layout", selection: $layout) {
                    Label("Unified", systemImage: "rectangle.split.1x2").tag(DiffDisplayMode.unified)
                    Label("Side by Side", systemImage: "rectangle.split.2x1").tag(DiffDisplayMode.sideBySide)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help(Text("Show the diff in one column, or the old and new versions side by side"))
            }
            if let book {
                ToolbarItem {
                    DiffNotesSendMenu(context: context, book: book, showsUnsentOnly: $showsUnsentOnly)
                }
            }
        }
        .task { await reloadFiles() }
        .task(id: selectedCommit) {
            await reloadCommitFiles()
            if selection?.group == .committed { await reloadDiff() }
        }
        .task(id: selection) {
            diff = nil
            diffError = nil
            await reloadDiff()
        }
        .task {
            let book = DiffNotesBook(context: context, model: model)
            await book?.load()
            self.book = book
        }
        .onChange(of: showsUnsentOnly) {
            if let selection, !listedSelections.contains(selection) { self.selection = listedSelections.first }
        }
        .onAppear {
            watcher?.stop()
            // Any change matters here, including commits and branch moves under `.git`.
            watcher = FileSystemWatcher(root: directory) { _ in
                Task { await reloadFiles(); await reloadDiff() }
            }
        }
        .onDisappear {
            watcher?.stop()
            watcher = nil
        }
    }

    private var noteScope: DiffNoteScope {
        selection?.group == .committed ? .branch : .uncommitted
    }

    /// Line notes of the shown file for the diff view; file notes and notes whose lines are not shown appear in the
    /// header above it.
    private func notesConfiguration(for diff: FileDiff) -> DiffNotesConfiguration? {
        guard let book else { return nil }
        let lines = DiffNoteAnchoring.newSideLines(of: diff)
        let items = book.notes(forFile: diff.displayPath)
            .filter { !$0.isFileNote && (!showsUnsentOnly || $0.sentAt == nil) }
            .map { $0.item(lines: lines) }
        let scope = noteScope
        return DiffNotesConfiguration(notes: items, actions: DiffNoteActions(
            create: { anchor, body in book.create(anchor, body: body, in: diff, scope: scope) },
            update: { id, body in book.update(id, body: body) },
            delete: { id in book.delete(id) }))
    }

    /// The diff a group shows: the working tree against HEAD, or the base's merge base against HEAD.
    private func diffScope(for group: ChangeGroup) -> DiffScope {
        switch group {
        case .uncommitted: .uncommitted
        case .committed: selectedCommit.map { .commit($0) } ?? .committed(resolvedBase ?? "HEAD")
        }
    }

    /// The files of the chosen commit; keeps the selected file when that commit changed it too.
    private func reloadCommitFiles() async {
        guard let sha = selectedCommit else { commitFiles = []; return }
        let loaded = (try? await DiffService(worktree: directory).changedFiles(.commit(sha))) ?? []
        guard sha == selectedCommit else { return }
        commitFiles = loaded
        if selection?.group == .committed, let path = selection?.path, !loaded.contains(where: { $0.path == path }) {
            selection = loaded.first.map { ChangeSelection(group: .committed, path: $0.path) }
        }
    }

    /// Reads both groups. The committed group is empty when the base cannot be resolved (no remote, a new repository).
    private func reloadFiles() async {
        let service = DiffService(worktree: directory)
        var baseName = base
        if baseName == nil { baseName = try? await WorktreeService(repository: directory).defaultBaseBranch() }
        do {
            let loadedUncommitted = try await service.changedFiles(.uncommitted)
            var loadedCommitted: [ChangedFile] = []
            var ahead: Int?
            var loadedCommits: [CommitSummary] = []
            if let baseName {
                loadedCommitted = (try? await service.changedFiles(.committed(baseName))) ?? []
                ahead = await service.commitsAhead(of: baseName)
                loadedCommits = await service.commits(notOn: baseName)
            }
            commits = loadedCommits
            if let chosen = selectedCommit, !loadedCommits.contains(where: { $0.sha == chosen }) { selectedCommit = nil }
            uncommitted = loadedUncommitted
            committed = loadedCommitted
            resolvedBase = baseName
            commitsAhead = ahead
            error = nil
        } catch {
            self.error = error.localizedDescription
            uncommitted = []
            committed = []
        }
        isLoading = false
        if let selection, !listedSelections.contains(selection) { self.selection = nil }
        if selection == nil { selection = listedSelections.first }
    }

    /// Applies a result only if the selection did not change meanwhile; git calls are not cancellable, so a slower
    /// earlier request must not overwrite a newer one.
    private func reloadDiff() async {
        guard let requested = selection else { diff = nil; diffError = nil; return }
        let service = DiffService(worktree: directory)
        do {
            let loaded = try await service.diff(for: requested.path, scope: diffScope(for: requested.group))
            guard requested == selection else { return }
            if loaded != diff { diff = loaded }
            diffError = nil
        } catch {
            guard requested == selection else { return }
            diff = nil
            diffError = error.localizedDescription
        }
    }
}

extension DiffNote {
    /// The note as the diff view shows it, stale when the noted lines no longer match.
    func item(lines: [Int: String]) -> DiffNoteItem {
        let anchor = DiffNoteAnchor(startLine: startLine, lineNumber: lineNumber)
        return DiffNoteItem(id: id, anchor: anchor, body: body, isSent: sentAt != nil,
                            isStale: DiffNoteAnchoring.isStale(anchor, identity: diffIdentity, in: lines))
    }
}

/// Above the diff: the file's path, a quiet notice when side by side fell back to unified, the "Note on File"
/// button, and the notes that are not shown between lines (file notes, and notes whose lines are no longer in the
/// diff).
private struct DiffFileNotesHeader: View {
    let diff: FileDiff
    let book: DiffNotesBook?
    let showsUnsentOnly: Bool
    let layout: DiffDisplayMode
    let isNarrowFallback: Bool
    let scope: DiffNoteScope
    @State private var draft: String?

    var body: some View {
        let notes = headerNotes
        VStack(alignment: .leading, spacing: MercurySpacing.s) {
            HStack(spacing: MercurySpacing.s) {
                Text(verbatim: diff.displayPath)
                    .font(MercuryFont.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: diff.displayPath))
                Spacer(minLength: MercurySpacing.s)
                if isNarrowFallback {
                    Label("Too narrow for side by side", systemImage: "rectangle.split.1x2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                        .help(Text("The diff is shown unified until the pane is wide enough for two columns."))
                }
                if book != nil {
                    Button("Note on File", systemImage: "text.bubble") { draft = draft ?? "" }
                        .controlSize(.small)
                        .glassButtonStyle()
                        .disabled(draft != nil)
                        .help(Text("Write a note about the whole file"))
                }
            }
            if let book, !notes.isEmpty || draft != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: MercurySpacing.s) {
                        ForEach(notes) { note in
                            DiffNoteCard(note: note, onSave: { book.update(note.id, body: $0) },
                                         onDelete: { book.delete(note.id) })
                        }
                        if draft != nil {
                            DiffNoteComposer(title: DiffNoteCard.title(for: .file),
                                             text: Binding(get: { draft ?? "" }, set: { draft = $0 }),
                                             saveTitle: String(localized: "Add Note"),
                                             onCancel: { draft = nil },
                                             onSave: { body in
                                                 book.create(.file, body: body, in: diff, scope: scope)
                                                 draft = nil
                                             })
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, MercurySpacing.m)
        .padding(.vertical, MercurySpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: diff.displayPath) { draft = nil }
    }

    /// File notes, plus line notes the diff cannot place under a line.
    private var headerNotes: [DiffNoteItem] {
        guard let book else { return [] }
        let lines = DiffNoteAnchoring.newSideLines(of: diff)
        let placeable = DiffNoteAnchoring.placeableLines(of: diff, mode: layout)
        return book.notes(forFile: diff.displayPath)
            .filter { !showsUnsentOnly || $0.sentAt == nil }
            .filter { $0.isFileNote || !placeable.contains($0.lineNumber) }
            .map { $0.item(lines: lines) }
    }
}

/// A folder workspace has no history to compare with; offer `git init` after confirmation.
private struct FolderWithoutGitView: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext
    @State private var isConfirming = false

    var body: some View {
        ContentUnavailableView {
            Label("No Changes to Show", systemImage: "folder")
        } description: {
            Text("This workspace is a plain folder, so there is no history to compare with. Initialize a git repository to see diffs and create worktrees.")
        } actions: {
            Button("Initialize Git…") { isConfirming = true }
                .glassButtonStyle()
        }
        .confirmationDialog("Initialize a git repository in this folder?", isPresented: $isConfirming) {
            Button("Initialize Git") { Task { await initialize() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs `git init`. Nothing is committed.")
        }
    }

    private func initialize() async {
        guard let id = model.workspaceID(of: context), let workspace = model.workspace(id) else { return }
        await model.perform(String(localized: "Could not initialize git")) {
            _ = try await GitRunner().run(["init"], in: URL(fileURLWithPath: workspace.path, isDirectory: true))
            await model.refreshKind(of: workspace)
        }
    }
}
