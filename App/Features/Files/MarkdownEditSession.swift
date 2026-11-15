import AppKit
import Foundation
import SuijinDiff
import SuijinMarkdown
import SuijinUI
import SwiftUI

/// The text of a Markdown file as the editor holds it, with what is needed to write the same bytes back.
struct MarkdownFileContents: Equatable {
    var text: String
    /// The file starts with a UTF-8 byte order mark; it is kept out of the text and written back on save.
    var hasBOM: Bool
    /// Every line of the file ends in CRLF.
    var usesCRLF: Bool
}

/// Reads and writes a Markdown file for the editor. Every write of a user's file goes through `write`.
enum MarkdownFile {
    enum ReadError: Error {
        case notUTF8
    }

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    static func read(_ url: URL) throws -> MarkdownFileContents {
        var data = try Data(contentsOf: url)
        let hasBOM = data.starts(with: bom)
        if hasBOM { data.removeFirst(bom.count) }
        guard let text = String(data: data, encoding: .utf8) else { throw ReadError.notUTF8 }
        return MarkdownFileContents(text: text, hasBOM: hasBOM, usesCRLF: usesCRLF(text))
    }

    /// Whether `text` has line endings and all of them are CRLF.
    static func usesCRLF(_ text: String) -> Bool {
        var sawCRLF = false
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                guard previous == 0x0D else { return false }
                sawCRLF = true
            }
            previous = byte
        }
        return sawCRLF
    }

    /// `text` as it is written to a file whose lines end in CRLF: a line feed typed or pasted on its own gets its
    /// carriage return. Nothing else is changed.
    static func normalized(_ text: String, usesCRLF: Bool) -> String {
        guard usesCRLF else { return text }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count + 16)
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A, previous != 0x0D { bytes.append(0x0D) }
            bytes.append(byte)
            previous = byte
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The bytes of the file for `contents`.
    static func data(for contents: MarkdownFileContents) -> Data {
        var data = Data(contents.hasBOM ? bom : [])
        data.append(Data(normalized(contents.text, usesCRLF: contents.usesCRLF).utf8))
        return data
    }

    /// Writes `contents` over the file: atomically (a reader never sees half a file), through a symbolic link to
    /// the file it names, keeping the file's permissions.
    static func write(_ contents: MarkdownFileContents, to url: URL) throws {
        let manager = FileManager.default
        let target = destination(of: url)
        let bytes = data(for: contents)
        guard manager.fileExists(atPath: target.path) else {
            // Nothing to replace (the file was deleted): create it.
            try bytes.write(to: target, options: .atomic)
            return
        }
        // The new bytes go to a file beside the old one, which then takes the old one's place and keeps its
        // metadata: permissions, extended attributes (Finder tags), access control lists.
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions]
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).suijin-\(UUID().uuidString)")
        do {
            try bytes.write(to: staging)
            if let permissions { try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: staging.path) }
            _ = try manager.replaceItemAt(target, withItemAt: staging)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// The file `url` names: itself, or the file a chain of symbolic links ends at, also when that file does not
    /// exist (saving then creates it there and leaves the link a link).
    static func destination(of url: URL) -> URL {
        var current = url
        for _ in 0..<16 {
            guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { break }
            current = URL(fileURLWithPath: link, relativeTo: current.deletingLastPathComponent()).standardizedFileURL
        }
        return current.resolvingSymlinksInPath()
    }
}

/// The editing state of one Markdown file tab: the editor with its text, undo history and scroll position, whether
/// it has unsaved changes, and what happened to the file on disk meanwhile. Lives in `AppModel` for as long as the
/// tab is open, so switching tabs loses nothing.
@MainActor
@Observable
final class MarkdownEditSession {
    enum Mode: Hashable {
        case read, edit
    }

    /// What the disk did while there were unsaved changes.
    enum Conflict: Equatable {
        /// Someone else wrote the file.
        case changed
        /// The file is gone.
        case deleted
    }

    let path: String
    var mode = Mode.read
    private(set) var isDirty = false
    private(set) var conflict: Conflict?
    /// A save that failed, shown in an alert.
    var saveError: String?
    /// The user kept their changes over a newer version on disk; the next save asks before it overwrites.
    var isConfirmingOverwrite = false
    /// Bumped on every edit, for views that show the unsaved text (the reader).
    private(set) var textRevision = 0
    /// The editor's selection, for commands that act on it (Add Comment).
    private(set) var selection = NSRange(location: 0, length: 0)

    @ObservationIgnored let controller: MarkdownEditorController
    /// What the file held when it was last loaded or saved.
    @ObservationIgnored private(set) var saved: MarkdownFileContents
    /// The newer version on disk while a conflict is shown or was dismissed with "Keep My Changes".
    @ObservationIgnored private var diskVersion: MarkdownFileContents?
    @ObservationIgnored private var keepsOwnChanges = false
    /// Called after each edit of the text, in order (comments follow their text through these).
    @ObservationIgnored var onTextChange: ((MarkdownTextChange) -> Void)?
    /// Called after the whole text was replaced by the version on disk.
    @ObservationIgnored var onTextReplaced: (() -> Void)?
    @ObservationIgnored var onSelectionChange: ((NSRange) -> Void)?
    /// Called when the user asks for a comment on the selection (the button by the selection, the context menu).
    @ObservationIgnored var onCommentRequested: (() -> Void)?
    @ObservationIgnored private var commentMenuTarget: MenuActionTarget?

    private var url: URL { URL(fileURLWithPath: path) }

    /// Nil when the file cannot be read as UTF-8 text.
    init?(path: String) {
        guard let contents = try? MarkdownFile.read(URL(fileURLWithPath: path)) else { return nil }
        self.path = path
        saved = contents
        controller = MarkdownEditorController(text: contents.text, theme: .suijin)
        controller.textView.lineEnding = contents.usesCRLF ? "\r\n" : "\n"
        controller.codeHighlighter = Self.highlight
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        controller.onOpenLink = { destination in
            guard let link = URL(string: destination, relativeTo: folder) else { return }
            NSWorkspace.shared.open(link)
        }
        controller.onSelectionChange = { [weak self] selection in
            guard let self else { return }
            if selection != self.selection { self.selection = selection }
            self.onSelectionChange?(selection)
        }
        installCommentControls()
        controller.onTextChange = { [weak self] change in
            guard let self else { return }
            self.refreshDirty()
            self.textRevision += 1
            self.onTextChange?(change)
        }
    }

    /// The text being edited, saved or not.
    var text: String { controller.text }

    /// Whether Save has something to do: unsaved changes, or a file to put back on disk.
    var canSave: Bool { isDirty || conflict == .deleted }

    private func refreshDirty() {
        let dirty = controller.text != saved.text
        if dirty != isDirty { isDirty = dirty }
    }

    // MARK: Saving

    /// Writes the text to the file. Returns whether the file now holds it. A newer version on disk is never
    /// overwritten without the user's answer: it raises the conflict, or the overwrite question once it was kept.
    @discardableResult
    func save(overwriting: Bool = false) -> Bool {
        controller.flushPendingChanges()
        if !overwriting {
            diskMayHaveChanged()
            if conflict == .changed {
                // The bar that asks what to do is part of the editor: show it, whatever asked for the save.
                mode = .edit
                return false
            }
            if keepsOwnChanges {
                isConfirmingOverwrite = true
                return false
            }
        }
        guard canSave || overwriting else { return true }
        var contents = saved
        contents.text = MarkdownFile.normalized(controller.text, usesCRLF: saved.usesCRLF)
        do {
            try MarkdownFile.write(contents, to: url)
        } catch {
            saveError = error.localizedDescription
            return false
        }
        saved = contents
        diskVersion = nil
        keepsOwnChanges = false
        conflict = nil
        // A line feed pasted into a CRLF file was written with its carriage return; show what was written.
        if contents.text != controller.text {
            controller.setText(contents.text)
            onTextReplaced?()
        }
        refreshDirty()
        return true
    }

    // MARK: Disk

    /// Looks at the file again (the viewer's file watcher calls this): its own save changes nothing, another
    /// writer's version replaces the text when there are no unsaved changes, and raises a conflict when there are.
    func diskMayHaveChanged() {
        guard var disk = try? MarkdownFile.read(url) else {
            if !FileManager.default.fileExists(atPath: path) { conflict = .deleted }
            return
        }
        // A text without any line break says nothing about line endings: the file keeps the kind it had.
        if !disk.text.contains(where: \.isNewline) { disk.usesCRLF = saved.usesCRLF }
        if conflict == .deleted { conflict = nil }
        guard disk != saved else {
            if conflict == .changed, !isDirty { conflict = nil }
            return
        }
        if !isDirty {
            adopt(disk)
        } else if disk != diskVersion {
            // A version the user has not answered for yet.
            diskVersion = disk
            keepsOwnChanges = false
            conflict = .changed
        }
    }

    /// Drops the unsaved changes and shows the version on disk.
    func reload() {
        guard var disk = (try? MarkdownFile.read(url)) ?? diskVersion else { return }
        if !disk.text.contains(where: \.isNewline) { disk.usesCRLF = saved.usesCRLF }
        adopt(disk)
    }

    /// Keeps the unsaved changes; the next save asks once before it overwrites the newer version on disk.
    func keepOwnChanges() {
        conflict = nil
        keepsOwnChanges = true
    }

    private func adopt(_ disk: MarkdownFileContents) {
        saved = disk
        diskVersion = nil
        keepsOwnChanges = false
        conflict = nil
        controller.textView.lineEnding = disk.usesCRLF ? "\r\n" : "\n"
        controller.setText(disk.text)
        textRevision += 1
        refreshDirty()
        onTextReplaced?()
    }

    // MARK: Comments

    /// The Comment button that follows the selection, and the same command in the context menu.
    private func installCommentControls() {
        let button = NSHostingView(rootView: SelectionCommentButton { [weak self] in self?.onCommentRequested?() })
        button.frame.size = button.fittingSize
        controller.selectionAccessory = button
        let target = MenuActionTarget { [weak self] in self?.onCommentRequested?() }
        commentMenuTarget = target
        controller.contextMenuItems = { [weak self] in
            guard let self, self.selection.length > 0 else { return [] }
            let item = NSMenuItem(title: String(localized: "Add Comment"), action: #selector(MenuActionTarget.run), keyEquivalent: "")
            item.target = target
            item.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
            return [item]
        }
    }

    // MARK: Code

    /// Colors a fenced code block with the diff viewer's grammars.
    private static func highlight(_ code: String, _ language: String) async -> [MarkdownCodeSpan] {
        let name = language.lowercased()
        guard let grammar = SyntaxHighlighter.supportedLanguages.contains(name) ? name : SyntaxHighlighter.language(forPath: "code." + name) else {
            return []
        }
        return await SyntaxHighlighter.highlight(code, language: grammar).map { MarkdownCodeSpan(range: $0.range, color: $0.token.color) }
    }
}

/// Runs a closure as the action of an AppKit menu item.
final class MenuActionTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) { self.action = action }

    @objc func run() { action() }
}

/// The button shown under the end of a selection in the editor. A floating view placed by the editor: text views
/// have no place for a control tied to the selection.
private struct SelectionCommentButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Comment", systemImage: "text.bubble")
        }
        .controlSize(.small)
        .glassButtonStyle()
        .help(Text("Comment on the selected text for an agent (\(ShortcutCatalog.addComment.glyphs))"))
        .padding(2)
    }
}

extension MarkdownTheme {
    /// The editor in the colors and sizes of the Markdown reader (`Theme.suijin`).
    @MainActor static var suijin: MarkdownTheme {
        var theme = MarkdownTheme()
        theme.background = .windowBackgroundColor
        theme.blockBackground = NSColor(SuijinColor.card)
        theme.inlineCodeBackground = NSColor(SuijinColor.card)
        theme.checkboxColor = .controlAccentColor
        theme.contentInset = NSSize(width: SuijinSpacing.xl, height: SuijinSpacing.l)
        return theme
    }
}

/// Hosts the session's editor. The editor's views belong to the session, so the same text view (with its undo
/// history and scroll position) comes back when the tab is shown again.
struct MarkdownEditorView: NSViewRepresentable {
    let session: MarkdownEditSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    /// Nothing to do: the editor's views are attached once, when this view is made. An older copy of this view must
    /// not take them back while SwiftUI is replacing it (the Comments column opening or closing rebuilds the tab).
    func updateNSView(_ container: NSView, context: Context) {}

    private func attach(to container: NSView) {
        let scrollView = session.controller.scrollView
        container.subviews.forEach { $0.removeFromSuperview() }
        scrollView.removeFromSuperview()
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        // The editor takes the keyboard when it appears, as a document does.
        DispatchQueue.main.async { [weak scrollView] in
            guard let textView = scrollView?.documentView, let window = textView.window else { return }
            if !(window.firstResponder is NSTextView) { window.makeFirstResponder(textView) }
        }
    }
}
