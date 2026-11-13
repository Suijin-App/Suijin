import AppKit
import SwiftUI

/// The inspector's file tree on the system outline view, as the Finder's list view and Xcode's navigator are. The
/// outline view tells a click from a drag: pressing on a row only selects it, a drag beyond the system threshold drags
/// the rows' file URLs and opens nothing, and a click (released without dragging) opens a file or folds a folder.
/// Built on AppKit because SwiftUI's `List` acts on the selection at mouse-down and cannot tell a click from a drag.
struct FileOutline: NSViewRepresentable {
    let content: FileOutlineController.Content
    let open: (URL) -> Void
    let setExpanded: (Set<String>) -> Void

    func makeCoordinator() -> FileOutlineController { FileOutlineController() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let outline = FileOutlineView()
        scroll.documentView = outline
        context.coordinator.attach(outline)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.open = open
        context.coordinator.setExpanded = setExpanded
        context.coordinator.update(content)
    }
}

/// The outline view of the file tree. Return opens the selection, as a click does.
class FileOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        // Return (36) and the keypad's Enter (76).
        if [36, 76].contains(event.keyCode), modifiers.isEmpty, let onReturn {
            onReturn()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Data source and delegate of the file tree's outline view. The items are the tree's `FileNode`s, whose identity
/// survives a refresh, so the outline view keeps their expansion and selection. Which folders are expanded belongs to
/// the app model (saved across launches); the outline view follows it and reports the user's changes back.
@MainActor
final class FileOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    /// What the outline shows.
    struct Content {
        var tree: FileTree?
        /// The tree's revision, bumped when entries changed on disk.
        var revision: Int
        /// The files matching the filter, shown as a flat list; nil when no filter is typed.
        var matches: [FileNode]?
        /// The expanded folders, as absolute paths.
        var expanded: Set<String>
        /// The latest request to show a path (a new `id` asks again).
        var reveal: Reveal?
    }

    struct Reveal: Equatable {
        let path: String
        let id: UUID
    }

    /// Opens a file in a viewer tab.
    var open: (URL) -> Void = { _ in }
    /// Stores the expanded folders after the user folded or unfolded some.
    var setExpanded: (Set<String>) -> Void = { _ in }

    private(set) weak var outline: FileOutlineView?
    private var tree: FileTree?
    private var revision = 0
    private var matches: [FileNode]?
    private var expanded: Set<String> = []
    private var lastReveal: UUID?
    /// The children last handed to the outline view, by parent (the root node for the top level). The outline view
    /// asks for a count, then for each child: answering from this copy keeps both answers consistent, and comparing it
    /// with the tree after a refresh tells which folders to reload.
    private var shown: [ObjectIdentifier: (parent: FileNode, children: [FileNode])] = [:]
    /// Set while the outline view's expansion is brought in line with `expanded`, so its notifications are not taken
    /// for the user's own folding.
    private var syncing = false
    /// The folder being folded, while the outline view reports its subfolders folding with it.
    private var collapsing: FileNode?

    func attach(_ outline: FileOutlineView) {
        self.outline = outline
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.usesAutomaticRowHeights = true
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        // A drag copies (the Finder copies the files, a terminal pastes their paths); never a move.
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.doubleAction = #selector(rowClicked(_:))
        outline.onReturn = { [weak self] in self?.openSelection() }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        outline.setAccessibilityLabel(String(localized: "Files"))
    }

    // MARK: Updates

    func update(_ content: Content) {
        guard let outline else { return }
        let expandedChanged = content.expanded != expanded
        expanded = content.expanded
        let sameMatches = switch (matches, content.matches) {
        case (nil, nil): true
        case let (old?, new?): old.elementsEqual(new, by: ===)
        default: false
        }
        if content.tree !== tree || !sameMatches {
            tree = content.tree
            matches = content.matches
            revision = content.revision
            shown = [:]
            outline.reloadData()
            syncExpansion(below: nil)
        } else if content.revision != revision {
            revision = content.revision
            reloadChangedFolders()
        } else if expandedChanged {
            syncExpansion(below: nil)
        }
        if let reveal = content.reveal, reveal.id != lastReveal {
            lastReveal = reveal.id
            self.reveal(reveal.path)
        }
    }

    /// Reloads the folders on screen whose entries changed since the outline view read them, keeping the selection
    /// and the first visible row where they were.
    private func reloadChangedFolders() {
        guard let outline, let tree, matches == nil else { return }
        let selected = selectedNodes.map(\.url.path)
        let anchor = scrollAnchor()
        // Parents before children: reloading a folder reads its expanded subfolders again.
        let parents = shown.values.map(\.parent).sorted { $0.url.path.count < $1.url.path.count }
        for parent in parents {
            let key = ObjectIdentifier(parent)
            guard let entry = shown[key] else { continue }
            let isRoot = parent === tree.root
            guard isRoot || (outline.row(forItem: parent) >= 0 && outline.isItemExpanded(parent)) else {
                // Not on screen: the outline view asks again when the folder (or a folder above it) opens.
                shown[key] = nil
                continue
            }
            if let current = parent.loaded, current.elementsEqual(entry.children, by: ===) { continue }
            outline.reloadItem(isRoot ? nil : parent, reloadChildren: true)
        }
        syncExpansion(below: nil)
        let rows = IndexSet(selected.compactMap { path in
            tree.node(at: path).map { outline.row(forItem: $0) }.flatMap { $0 >= 0 ? $0 : nil }
        })
        if rows != outline.selectedRowIndexes {
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }
        restore(anchor)
    }

    /// Expands the folders in `expanded` and collapses the others, among the folders shown below `parent`.
    private func syncExpansion(below parent: FileNode?) {
        guard let outline, matches == nil else { return }
        let wasSyncing = syncing
        syncing = true
        defer { syncing = wasSyncing }
        func visit(_ item: FileNode?) {
            for index in 0..<outline.numberOfChildren(ofItem: item) {
                guard let child = outline.child(index, ofItem: item) as? FileNode, child.isDirectory else { continue }
                if expanded.contains(child.url.path) {
                    if !outline.isItemExpanded(child) { outline.expandItem(child) }
                    visit(child)
                } else if outline.isItemExpanded(child) {
                    outline.collapseItem(child)
                }
            }
        }
        visit(parent)
    }

    /// Unfolds every folder on the way to `path`, selects its row and scrolls it to the middle. Paths outside the
    /// tree's folder are ignored; selecting opens nothing.
    private func reveal(_ path: String) {
        guard let outline, let tree, matches == nil else { return }
        let root = tree.root.url.path
        guard path.hasPrefix(root + "/") else { return }
        var folders = expanded
        var current = URL(fileURLWithPath: path).deletingLastPathComponent()
        while current.path.count > root.count {
            folders.insert(current.path)
            current = current.deletingLastPathComponent()
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { folders.insert(path) }
        if folders != expanded {
            expanded = folders
            setExpanded(folders)
        }
        syncExpansion(below: nil)
        guard let node = tree.node(at: path) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        // After layout: a tree shown for the first time has no height yet.
        DispatchQueue.main.async { [weak self] in self?.center(node) }
    }

    private func center(_ node: FileNode) {
        guard let outline, let clip = outline.enclosingScrollView?.contentView else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        let rect = outline.rect(ofRow: row)
        let maxY = max(0, outline.bounds.height - clip.bounds.height)
        outline.scroll(NSPoint(x: clip.bounds.minX, y: min(maxY, max(0, rect.midY - clip.bounds.height / 2))))
    }

    /// The first visible row's node and how far the view is scrolled past its top.
    private func scrollAnchor() -> (node: FileNode, offset: CGFloat)? {
        guard let outline else { return nil }
        let visible = outline.visibleRect
        let row = outline.row(at: NSPoint(x: visible.minX, y: visible.minY))
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return nil }
        return (node, visible.minY - outline.rect(ofRow: row).minY)
    }

    private func restore(_ anchor: (node: FileNode, offset: CGFloat)?) {
        guard let outline, let anchor, let clip = outline.enclosingScrollView?.contentView else { return }
        let row = outline.row(forItem: anchor.node)
        guard row >= 0 else { return }
        let y = outline.rect(ofRow: row).minY + anchor.offset
        if abs(y - outline.visibleRect.minY) > 0.5 { outline.scroll(NSPoint(x: clip.bounds.minX, y: y)) }
    }

    // MARK: Clicks and keys

    private var selectedNodes: [FileNode] {
        guard let outline else { return [] }
        return outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
    }

    /// What a click on a row was, as far as opening is concerned.
    struct Click {
        var modifiers: NSEvent.ModifierFlags = []
        var clickCount = 1
        /// The click landed on the disclosure triangle, which folds the row by itself.
        var onDisclosure = false
    }

    /// The outline view's action and double action, sent when the mouse goes up without having dragged (a drag sends
    /// neither).
    @objc func rowClicked(_ sender: Any?) {
        guard let outline else { return }
        let row = outline.clickedRow
        guard row >= 0 else { return }
        var click = Click()
        if let event = NSApp.currentEvent, [.leftMouseUp, .leftMouseDown].contains(event.type) {
            click.modifiers = event.modifierFlags
            click.clickCount = event.clickCount
            click.onDisclosure = outline.frameOfOutlineCell(atRow: row)
                .contains(outline.convert(event.locationInWindow, from: nil))
        }
        handle(click, onRow: row)
    }

    /// A click on a row: a file opens; a folder folds or unfolds once. ⌘-, ⇧- and ⌃-clicks only change the
    /// selection, and the second click of a double click does not fold back what the first one unfolded.
    func handle(_ click: Click, onRow row: Int) {
        guard let outline, let node = outline.item(atRow: row) as? FileNode else { return }
        guard click.modifiers.intersection([.command, .shift, .control]).isEmpty else { return }
        guard node.isDirectory else {
            open(node.url.standardizedFileURL)
            return
        }
        guard matches == nil, click.clickCount <= 1, !click.onDisclosure else { return }
        toggle(node)
    }

    /// Return: opens the selected files, or folds or unfolds the one selected folder.
    func openSelection() {
        let nodes = selectedNodes
        if nodes.count == 1, let folder = nodes.first, folder.isDirectory {
            if matches == nil { toggle(folder) }
            return
        }
        for node in nodes where !node.isDirectory { open(node.url.standardizedFileURL) }
    }

    private func toggle(_ folder: FileNode) {
        guard let outline else { return }
        if outline.isItemExpanded(folder) {
            outline.animator().collapseItem(folder)
        } else {
            outline.animator().expandItem(folder)
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let matches { return item == nil ? matches.count : 0 }
        guard let parent = (item as? FileNode) ?? tree?.root else { return 0 }
        let children = parent.children ?? []
        shown[ObjectIdentifier(parent)] = (parent, children)
        return children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let matches { return matches[index] }
        // The outline view asks for the count first, which records the children it is about to ask for.
        guard let parent = (item as? FileNode) ?? tree?.root else { return NSNull() }
        if shown[ObjectIdentifier(parent)] == nil { _ = self.outlineView(outlineView, numberOfChildrenOfItem: item) }
        return shown[ObjectIdentifier(parent)]?.children[index] ?? NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        matches == nil && (item as? FileNode)?.isDirectory == true
    }

    /// Rows drag as file URLs only (`public.file-url`), no text: a terminal pastes the paths, the Finder takes the
    /// files, and the pane and tab drop targets ignore them. The outline view drags every selected row when the drag
    /// starts on one of them.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        (item as? FileNode).map { Self.pasteboardWriter(for: $0.url) }
    }

    static func pasteboardWriter(for url: URL) -> any NSPasteboardWriting {
        url.standardizedFileURL as NSURL
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: FileOutlineCell.identifier, owner: nil) as? FileOutlineCell ?? FileOutlineCell()
        var folder: String?
        if matches != nil, let root = tree?.root.url.path {
            folder = String(node.url.deletingLastPathComponent().path.dropFirst(root.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        cell.show(node, folder: folder)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? FileNode)?.name
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !syncing, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expanded.insert(node.url.path)
        setExpanded(expanded)
        // Subfolders left expanded earlier open again with it.
        syncExpansion(below: node)
    }

    /// Folding a folder also reports its expanded subfolders as folded, though the outline view unfolds them again
    /// with it; only the folder the user folded leaves `expanded`.
    func outlineViewItemWillCollapse(_ notification: Notification) {
        guard !syncing, collapsing == nil, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        collapsing = node
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !syncing, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        if let collapsing, collapsing !== node { return }
        collapsing = nil
        expanded.remove(node.url.path)
        setExpanded(expanded)
    }

    // MARK: Context menu

    /// The rows a right-click acts on: the selection when the clicked row is part of it, otherwise that row alone.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let outline, outline.clickedRow >= 0 else { return }
        let rows = outline.selectedRowIndexes.contains(outline.clickedRow) ? outline.selectedRowIndexes : [outline.clickedRow]
        let urls = rows.compactMap { (outline.item(atRow: $0) as? FileNode)?.url }
        guard !urls.isEmpty else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = urls
            menu.addItem(item)
        }
        add(String(localized: "Show in Finder"), #selector(showInFinder(_:)))
        add(String(localized: "Copy Path"), #selector(copyPath(_:)))
        let allFiles = rows.allSatisfy { (outline.item(atRow: $0) as? FileNode)?.isDirectory == false }
        if allFiles { add(String(localized: "Open in Default App"), #selector(openInDefaultApp(_:))) }
    }

    @objc private func showInFinder(_ item: NSMenuItem) {
        guard let urls = item.representedObject as? [URL] else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func copyPath(_ item: NSMenuItem) {
        guard let urls = item.representedObject as? [URL] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc private func openInDefaultApp(_ item: NSMenuItem) {
        guard let urls = item.representedObject as? [URL] else { return }
        for url in urls { NSWorkspace.shared.open(url) }
    }
}

/// A row of the file tree: the file's icon and name, and under it the folder it is in while the tree is filtered.
final class FileOutlineCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileOutlineCell")

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = name
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.truncatesLastVisibleLine = true
        folder.lineBreakMode = .byTruncatingHead
        folder.font = .preferredFont(forTextStyle: .caption1)
        folder.textColor = .secondaryLabelColor
        for label in [name, folder] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.maximumNumberOfLines = 1
        }
        let text = NSStackView(views: [name, folder])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ node: FileNode, folder location: String?) {
        icon.image = FileIcons.icon(forPath: node.url.path, isDirectory: node.isDirectory)
        name.stringValue = node.name
        folder.stringValue = location ?? ""
        folder.isHidden = location == nil
        toolTip = node.url.path
    }
}
