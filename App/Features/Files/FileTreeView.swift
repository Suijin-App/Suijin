import AppKit
import SevindaUI
import SwiftUI

/// One visible row of the file tree: a node and how deep it sits.
private struct FileRow: Identifiable {
    let node: FileNode
    let depth: Int
    var id: URL { node.url }
}

/// The inspector's file browser: the context's folder as a tree of rows with their own fold chevrons (a flat list,
/// so folders can be opened from code to reveal a path, which `List(children:)` cannot do). Choosing a file opens it
/// in a viewer tab; choosing a folder folds or unfolds it. The tree follows changes on disk while it is shown.
struct FileTreeView: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext
    @State private var tree: FileTree?
    @State private var filter = ""
    @State private var selection: URL?
    /// Set when a reveal selects a row, so that selection does not also fold or open what was revealed.
    @State private var selectionFromReveal: URL?

    private var expanded: Set<String> { model.expandedFolders(in: context) }
    private var roots: [FileNode] { tree?.roots ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SevindaSpacing.s) {
                TextField("Filter", text: $filter, prompt: Text("Filter files"))
                    .textFieldStyle(.roundedBorder)
                Button { tree?.reloadAll() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(Text("Reload the folder"))
                    .accessibilityLabel(Text("Reload"))
            }
            .padding(SevindaSpacing.s)
            ScrollViewReader { reader in
                List(selection: $selection) {
                    if filter.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(visibleRows) { row in
                            rowView(row.node, depth: row.depth).tag(row.node.url)
                        }
                    } else {
                        ForEach(matches) { node in
                            rowView(node, depth: 0, showsFolder: true).tag(node.url)
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: model.fileTreeReveal?.request) {
                    guard let path = model.fileTreeReveal?.path else { return }
                    model.fileTreeReveal = nil
                    reveal(path, reader: reader)
                }
                .task(id: context) {
                    guard let directory = model.directory(of: context) else { tree = nil; return }
                    let tree = FileTree(directory: directory) { [model, context] in model.expandedFolders(in: context) }
                    self.tree = tree
                    tree.startWatching()
                    // A folder link opens the inspector and is revealed once the tree exists; otherwise opening the
                    // inspector while a file is open shows that file.
                    if let pending = model.fileTreeReveal?.path {
                        model.fileTreeReveal = nil
                        reveal(pending, reader: reader)
                    } else if case .file(let path)? = model.currentTab(in: context) {
                        reveal(path, reader: reader)
                    }
                    // Watch until the tree goes away or shows another context.
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
                    tree.stopWatching()
                }
            }
            .overlay {
                if let tree, !tree.rootExists {
                    ContentUnavailableView("Folder Not Found", systemImage: "questionmark.folder",
                                           description: Text(verbatim: tree.root.url.path))
                } else if roots.isEmpty {
                    ContentUnavailableView("Empty Folder", systemImage: "folder")
                } else if !filter.isEmpty, matches.isEmpty {
                    ContentUnavailableView.search(text: filter)
                }
            }
        }
        .onChange(of: tree?.revision) {
            // A selected file deleted on disk just disappears.
            if let selection, node(at: selection.path) == nil { self.selection = nil }
        }
        .onChange(of: selection) { _, url in
            if let url, url == selectionFromReveal { selectionFromReveal = nil; return }
            guard let url, let node = node(at: url.path) ?? matches.first(where: { $0.url == url }) else { return }
            // Folders are not selectable (their rows are buttons, see `rowView`); files open.
            if !node.isDirectory {
                model.open(fileAt: url.standardizedFileURL, in: context)
            }
        }
    }

    /// Rows of the expanded tree, depth first.
    private var visibleRows: [FileRow] {
        var rows: [FileRow] = []
        func add(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                rows.append(FileRow(node: node, depth: depth))
                if node.isDirectory, expanded.contains(node.url.path) {
                    add(node.children ?? [], depth: depth + 1)
                }
            }
        }
        add(roots, depth: 0)
        return rows
    }

    /// A file row selects and opens like any list row. A folder row is a button over its whole width that folds or
    /// unfolds it on every click, and is never selected: folding through the selection meant a second click on the
    /// selected folder did nothing, a click on the chevron folded twice, and clearing the selection made rows flash.
    @ViewBuilder
    private func rowView(_ node: FileNode, depth: Int, showsFolder: Bool = false) -> some View {
        if node.isDirectory && !showsFolder {
            Button { toggle(node.url.path) } label: {
                rowContent(node, depth: depth, showsFolder: showsFolder)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .selectionDisabled()
            .accessibilityLabel(Text(verbatim: node.name))
            .accessibilityValue(expanded.contains(node.url.path) ? Text("Expanded") : Text("Collapsed"))
        } else {
            rowContent(node, depth: depth, showsFolder: showsFolder)
        }
    }

    private func rowContent(_ node: FileNode, depth: Int, showsFolder: Bool) -> some View {
        HStack(spacing: 4) {
            // Custom on purpose: the tree is a flat list (see the type comment), so the fold chevron is its own.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(expanded.contains(node.url.path) ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .opacity(node.isDirectory && !showsFolder ? 1 : 0)
            Image(nsImage: FileIcons.icon(forPath: node.url.path, isDirectory: node.isDirectory))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: node.name).lineLimit(1).truncationMode(.middle)
                if showsFolder, let root = model.directory(of: context) {
                    Text(verbatim: String(node.url.deletingLastPathComponent().path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .help(Text(verbatim: node.url.path))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
            if !node.isDirectory {
                Button("Open in Default App") { NSWorkspace.shared.open(node.url) }
            }
        }
    }

    private func toggle(_ path: String) {
        var folders = expanded
        if folders.contains(path) { folders.remove(path) } else { folders.insert(path) }
        model.setExpandedFolders(folders, in: context)
    }

    /// Unfolds every folder on the way to `path`, selects it and scrolls it into view. Paths outside the context's
    /// folder are ignored.
    private func reveal(_ path: String, reader: ScrollViewProxy) {
        guard let root = model.directory(of: context)?.standardizedFileURL.path, path.hasPrefix(root + "/") else { return }
        filter = ""
        var folders = expanded
        var current = URL(fileURLWithPath: path).deletingLastPathComponent()
        while current.path.count > root.count {
            folders.insert(current.path)
            current = current.deletingLastPathComponent()
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { folders.insert(path) }
        model.setExpandedFolders(folders, in: context)
        let target = URL(fileURLWithPath: path)
        selectionFromReveal = target
        selection = target
        DispatchQueue.main.async {
            withAnimation(.snappy) { reader.scrollTo(target, anchor: .center) }
        }
    }

    /// The node at `path`, found by walking down from the roots (folders keep their loaded children).
    private func node(at path: String) -> FileNode? {
        var nodes = roots
        while let next = nodes.first(where: { path == $0.url.path || path.hasPrefix($0.url.path + "/") }) {
            if next.url.path == path { return next }
            nodes = next.children ?? []
        }
        return nil
    }

    /// Files whose name contains the filter, among the folders already loaded and their first levels (so a filter
    /// finds files without reading a whole repository).
    private var matches: [FileNode] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var found: [FileNode] = []
        func visit(_ nodes: [FileNode], depth: Int) {
            for node in nodes where found.count < 300 {
                if !node.isDirectory, node.name.lowercased().contains(needle) { found.append(node) }
                if node.isDirectory, depth < 4 { visit(node.children ?? [], depth: depth + 1) }
            }
        }
        visit(roots, depth: 0)
        return found
    }
}
