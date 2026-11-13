import AppKit
import SevindaUI
import SwiftUI

/// The inspector's file browser: the context's folder as an outline (`FileOutline`). A click on a file opens it in a
/// viewer tab; a click on a folder folds or unfolds it; a drag carries the rows' file URLs (onto a terminal, which
/// pastes their paths, or to the Finder) and opens nothing. The tree follows changes on disk while it is shown.
struct FileTreeView: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext
    @State private var tree: FileTree?
    @State private var filter = ""
    @State private var reveal: FileOutlineController.Reveal?

    private var roots: [FileNode] { tree?.roots ?? [] }
    private var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty }

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
            FileOutline(
                content: .init(tree: tree, revision: tree?.revision ?? 0, matches: isFiltering ? matches : nil,
                               expanded: model.expandedFolders(in: context), reveal: reveal),
                open: { [model, context] url in model.open(fileAt: url, in: context) },
                setExpanded: { [model, context] folders in model.setExpandedFolders(folders, in: context) }
            )
            .overlay {
                if let tree, !tree.rootExists {
                    ContentUnavailableView("Folder Not Found", systemImage: "questionmark.folder",
                                           description: Text(verbatim: tree.root.url.path))
                } else if roots.isEmpty {
                    ContentUnavailableView("Empty Folder", systemImage: "folder")
                } else if isFiltering, matches.isEmpty {
                    ContentUnavailableView.search(text: filter)
                }
            }
        }
        .onChange(of: model.fileTreeReveal?.request) {
            guard let path = model.fileTreeReveal?.path else { return }
            model.fileTreeReveal = nil
            show(path)
        }
        .task(id: context) {
            guard let directory = model.directory(of: context) else { tree = nil; return }
            let tree = FileTree(directory: directory) { [model, context] in model.expandedFolders(in: context) }
            self.tree = tree
            tree.startWatching()
            // A folder link opens the inspector and is revealed once the tree exists; otherwise opening the inspector
            // while a file is open shows that file.
            if let pending = model.fileTreeReveal?.path {
                model.fileTreeReveal = nil
                show(pending)
            } else if case .file(let path)? = model.currentTab(in: context) {
                show(path)
            }
            // Watch until the tree goes away or shows another context.
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            tree.stopWatching()
        }
    }

    /// Clears the filter and asks the outline to unfold the way to `path`, select it and scroll to it.
    private func show(_ path: String) {
        filter = ""
        reveal = .init(path: path, id: UUID())
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
