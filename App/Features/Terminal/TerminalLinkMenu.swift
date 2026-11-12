import AppKit
import SevindaCore
import SevindaTerminal
import SevindaUI
import SwiftUI

/// The context menu for a right-click on a path or link in a terminal: actions for the path first, then the terminal's
/// own Copy, Paste, Select All and Find.
///
/// An AppKit `NSMenu` because SwiftTerm's view is AppKit and asks for one in `menu(for:)`; SwiftUI's `.contextMenu`
/// cannot depend on where in the view the click landed.
@MainActor
struct TerminalLinkMenu {
    /// What the click was on.
    enum Subject: Equatable {
        /// A path that exists.
        case file(ResolvedTerminalPath)
        case web(URL)
        /// A path the program shortened (`…/feature/x.swift`), as shown.
        case elided(String)
        /// Text that looks like a path but names nothing, as shown.
        case missing(String)
    }

    let model: AppModel
    let context: SessionContext
    let view: SevindaTerminalView
    /// Folders a relative path is tried against, in order.
    let bases: [URL?]

    /// The subject of a right-click: the underlined link, else the longest candidate that exists on disk now (the
    /// screen may not have been scanned since it appeared), else an elided path or a web link, else missing text.
    static func subject(of request: TerminalLinkMenuRequest, bases: [URL?]) -> Subject? {
        if let link = request.link {
            switch link.target {
            case .web(let url):
                return .web(url)
            case .file(let file):
                return .file(ResolvedTerminalPath(url: URL(fileURLWithPath: file.path, isDirectory: file.isDirectory),
                                                  isDirectory: file.isDirectory, line: file.line, column: file.column))
            }
        }
        let folders = TerminalPathResolver.Query(text: "", bases: bases).bases
        for candidate in request.candidates {
            switch candidate.kind {
            case .url:
                if let url = URL(string: candidate.text), url.host != nil { return .web(url) }
            case .elided:
                return .elided(candidate.displayText)
            case .path:
                if let probe = TerminalPathResolver.probe(candidate.text, bases: folders).result {
                    return .file(ResolvedTerminalPath(url: URL(fileURLWithPath: probe.path, isDirectory: probe.isDirectory),
                                                      isDirectory: probe.isDirectory, line: probe.line ?? candidate.line,
                                                      column: probe.line == nil ? candidate.column : probe.column))
                }
            }
        }
        return request.candidates.first.map { .missing($0.displayText) }
    }

    func menu(for request: TerminalLinkMenuRequest) -> NSMenu? {
        guard let subject = Self.subject(of: request, bases: bases) else { return nil }
        let menu = NSMenu()
        // Items are enabled as built: the terminal answers every action, and only Copy depends on a selection.
        menu.autoenablesItems = false
        for item in items(for: subject, at: request.point) { menu.addItem(item) }
        menu.addItem(.separator())
        for item in terminalItems() { menu.addItem(item) }
        return menu
    }

    // MARK: Items

    private var root: URL? { model.directory(of: context)?.standardizedFileURL }

    func items(for subject: Subject, at point: CGPoint) -> [NSMenuItem] {
        let model = model, context = context
        switch subject {
        case .file(let resolved):
            let url = resolved.url.standardizedFileURL
            var items: [NSMenuItem] = [
                ActionMenuItem(String(localized: "Open"), symbol: resolved.isDirectory ? "sidebar.right" : "doc.text") {
                    model.openTerminalPath(resolved, in: context)
                },
            ]
            if !resolved.isDirectory {
                items.append(ActionMenuItem(String(localized: "Open With Default App"), symbol: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(url)
                })
            }
            if let root, url.path == root.path || url.path.hasPrefix(root.path + "/") {
                items.append(ActionMenuItem(String(localized: "Reveal in File Tree"), symbol: "list.bullet.indent") {
                    UserDefaults.standard.set(true, forKey: "inspector.shown")
                    model.revealInFileTree(url.path)
                })
            }
            items.append(ActionMenuItem(String(localized: "Show in Finder"), symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
            items.append(.separator())
            items.append(ActionMenuItem(String(localized: "Copy Path"), symbol: "doc.on.doc") { Self.copy(url.path) })
            if let relative = relativePath(url) {
                items.append(ActionMenuItem(String(localized: "Copy Relative Path"), symbol: "doc.on.doc") { Self.copy(relative) })
            }
            if let line = resolved.line {
                let text = resolved.column.map { "\(url.path):\(line):\($0)" } ?? "\(url.path):\(line)"
                items.append(ActionMenuItem(String(localized: "Copy Path with Line"), symbol: "doc.on.doc") { Self.copy(text) })
            }
            return items
        case .web(let url):
            return [
                ActionMenuItem(String(localized: "Open Link"), symbol: "safari") { NSWorkspace.shared.open(url) },
                ActionMenuItem(String(localized: "Copy Link"), symbol: "link") { Self.copy(url.absoluteString) },
            ]
        case .elided(let text):
            let view = view
            return [
                ActionMenuItem(String(localized: "Find Full Path…"), symbol: "magnifyingglass") {
                    FullPathFinder.present(for: text, model: model, context: context, from: view, at: point)
                },
                ActionMenuItem(String(localized: "Copy Text"), symbol: "doc.on.doc") { Self.copy(text) },
            ]
        case .missing(let text):
            return [ActionMenuItem(String(localized: "Copy Text"), symbol: "doc.on.doc") { Self.copy(text) }]
        }
    }

    /// The terminal's own actions, sent to the terminal view.
    func terminalItems() -> [NSMenuItem] {
        let copy = NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copy.isEnabled = view.selectionActive
        let paste = NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "")
        let selectAll = NSMenuItem(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        let find = NSMenuItem(title: String(localized: "Find…"), action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        let items = [copy, paste, selectAll, find]
        for item in items { item.target = view }
        return items
    }

    private func relativePath(_ url: URL) -> String? {
        guard let root, url.path.hasPrefix(root.path + "/") else { return nil }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A menu item that runs a closure.
@MainActor
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() {
        handler()
    }
}

/// "Find Full Path…": the files of the workspace whose path ends like an elided path, to open one. A single match opens
/// at once; several are listed to choose from; none says so.
struct FullPathFinder: View {
    @Environment(AppModel.self) private var model
    let elided: String
    let context: SessionContext
    let dismiss: @MainActor () -> Void
    @State private var candidates: [URL]?
    @State private var selection: URL?

    /// Shows the finder in a popover at `point` of the terminal view.
    static func present(for elided: String, model: AppModel, context: SessionContext, from view: NSView, at point: CGPoint) {
        let popover = NSPopover()
        popover.behavior = .transient
        let finder = FullPathFinder(elided: elided, context: context) { [weak popover] in popover?.performClose(nil) }
        popover.contentViewController = NSHostingController(rootView: finder.environment(model))
        popover.show(relativeTo: CGRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .maxY)
    }

    private var root: URL? { model.directory(of: context)?.standardizedFileURL }

    var body: some View {
        VStack(alignment: .leading, spacing: SevindaSpacing.m) {
            VStack(alignment: .leading, spacing: SevindaSpacing.xs) {
                Text("Find Full Path").font(.headline)
                Text(verbatim: elided)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Group {
                if let candidates {
                    if candidates.isEmpty {
                        ContentUnavailableView {
                            Label("No Matching File", systemImage: "doc.questionmark")
                        } description: {
                            Text("No matching file in this workspace.")
                        }
                    } else {
                        List(candidates, id: \.self, selection: $selection) { url in
                            row(url)
                        }
                        .contextMenu(forSelectionType: URL.self, menu: { _ in }, primaryAction: { urls in
                            if let url = urls.first { open(url) }
                        })
                        .accessibilityLabel(Text("Matching files"))
                    }
                } else {
                    ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 440, height: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { if let selection { open(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(SevindaSpacing.l)
        .task { await search() }
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: SevindaSpacing.s) {
            Image(nsImage: FileIcons.icon(forPath: url.path))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: relative(url))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(verbatim: (url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .tag(url)
        .help(Text(verbatim: url.path))
    }

    private func relative(_ url: URL) -> String {
        guard let root, url.path.hasPrefix(root.path + "/") else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    private func search() async {
        guard let root else {
            candidates = []
            return
        }
        let isGit = model.workspaceID(of: context).flatMap(model.workspace)?.kind == .git
        let found = await TerminalPathResolver.shared.candidates(forElided: elided, in: root, isGit: isGit)
        if found.count == 1, let only = found.first {
            open(only)
            return
        }
        candidates = found
        selection = found.first
    }

    private func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        model.openTerminalPath(ResolvedTerminalPath(url: url, isDirectory: isDirectory.boolValue), in: context)
        dismiss()
    }
}
