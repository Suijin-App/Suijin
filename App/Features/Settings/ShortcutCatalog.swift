import SuijinCore
import SuijinDiff
import SwiftUI

/// The sections of the Shortcuts settings, in display order.
enum ShortcutGroup: String, CaseIterable, Identifiable {
    case sessions, panes, terminal, files, sourceControl, app, mouse

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .sessions: "Sessions & Tabs"
        case .panes: "Panes"
        case .terminal: "Terminal"
        case .files: "Files & Viewer"
        case .sourceControl: "Source Control"
        case .app: "App & Window"
        case .mouse: "Mouse"
        }
    }
}

/// One keyboard shortcut of the app: the menu command or button that owns it reads `shortcut` from here, so the
/// Shortcuts settings cannot drift from the real bindings.
struct AppShortcut: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource?
    let group: ShortcutGroup
    let shortcut: KeyboardShortcut

    /// The shortcut as menu glyphs, for example "⇧⌘D".
    var glyphs: String { ShortcutGlyphs.text(for: shortcut) }
}

/// A mouse gesture listed with the shortcuts: what to do, and what it does.
struct MouseGesture: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource?
    /// The gesture itself, for example "Double-click a divider".
    let gesture: LocalizedStringResource
    let systemImage: String
}

/// Every keyboard shortcut and mouse gesture of Suijin. The single source of truth: menu commands and buttons bind
/// `ShortcutCatalog.<entry>.shortcut`, and tests check the terminal key routes against these entries.
@MainActor
enum ShortcutCatalog {
    // MARK: Sessions & Tabs

    static let newSession = AppShortcut(id: "newSession", title: "New Session", detail: "Start the default agent in a new tab.",
                                        group: .sessions, shortcut: KeyboardShortcut("t"))
    static let newShell = AppShortcut(id: "newShell", title: "New Shell", detail: "Open a shell in a new tab.",
                                      group: .sessions, shortcut: KeyboardShortcut("t", modifiers: [.command, .option]))
    static let newWorktree = AppShortcut(id: "newWorktree", title: "New Worktree",
                                         detail: "Create a worktree on a new branch of a git workspace.",
                                         group: .sessions, shortcut: KeyboardShortcut("n"))
    static let addWorkspace = AppShortcut(id: "addWorkspace", title: "Add Workspace",
                                          detail: "Add a git repository or a plain folder.",
                                          group: .sessions, shortcut: KeyboardShortcut("o", modifiers: [.command, .shift]))
    static let closeTab = AppShortcut(id: "closeTab", title: "Close Tab or Pane",
                                      detail: "In a split tab, closes the focused pane only.",
                                      group: .sessions, shortcut: KeyboardShortcut("w"))
    static let previousTab = AppShortcut(id: "previousTab", title: "Previous Tab", detail: nil,
                                         group: .sessions, shortcut: KeyboardShortcut("[", modifiers: [.command, .shift]))
    static let nextTab = AppShortcut(id: "nextTab", title: "Next Tab", detail: nil,
                                     group: .sessions, shortcut: KeyboardShortcut("]", modifiers: [.command, .shift]))
    /// ⌘1…⌘8 select the tab with that number, ⌘9 the last tab.
    static let selectTabs: [AppShortcut] = (1...9).map { number in
        let key = KeyboardShortcut(KeyEquivalent(Character(String(number))))
        guard number < 9 else {
            return AppShortcut(id: "selectLastTab", title: "Select Last Tab", detail: nil, group: .sessions, shortcut: key)
        }
        return AppShortcut(id: "selectTab\(number)", title: "Select Tab \(number)", detail: nil, group: .sessions, shortcut: key)
    }

    /// The entry of ⌘`number`, 1…9.
    static func selectTab(_ number: Int) -> AppShortcut {
        selectTabs[number - 1]
    }

    // MARK: Panes

    static let splitRight = AppShortcut(id: "splitRight", title: "Split Right", detail: "Add a pane to the right of the focused one.",
                                        group: .panes, shortcut: KeyboardShortcut("d"))
    static let splitDown = AppShortcut(id: "splitDown", title: "Split Down", detail: "Add a pane below the focused one.",
                                       group: .panes, shortcut: KeyboardShortcut("d", modifiers: [.command, .shift]))
    static let zoomPane = AppShortcut(id: "zoomPane", title: "Zoom Pane", detail: "Show the focused pane alone, or all panes again.",
                                      group: .panes, shortcut: KeyboardShortcut(.return, modifiers: [.command, .shift]))
    static let equalizePanes = AppShortcut(id: "equalizePanes", title: "Equalize Panes",
                                           detail: "Give every pane of the tab the same room.",
                                           group: .panes, shortcut: KeyboardShortcut("=", modifiers: [.command, .control]))
    static let focusPaneLeft = focus("focusPaneLeft", "Focus Pane Left", .leftArrow)
    static let focusPaneRight = focus("focusPaneRight", "Focus Pane Right", .rightArrow)
    static let focusPaneAbove = focus("focusPaneAbove", "Focus Pane Above", .upArrow)
    static let focusPaneBelow = focus("focusPaneBelow", "Focus Pane Below", .downArrow)
    static let movePaneLeft = move("movePaneLeft", "Move Pane Left", .leftArrow)
    static let movePaneRight = move("movePaneRight", "Move Pane Right", .rightArrow)
    static let movePaneUp = move("movePaneUp", "Move Pane Up", .upArrow)
    static let movePaneDown = move("movePaneDown", "Move Pane Down", .downArrow)

    /// ⌥⌘ arrow toward `edge`.
    static func focusPane(_ edge: PaneEdge) -> AppShortcut {
        switch edge {
        case .left: focusPaneLeft
        case .right: focusPaneRight
        case .top: focusPaneAbove
        case .bottom: focusPaneBelow
        }
    }

    /// ⌃⌥⌘ arrow toward `edge`.
    static func movePane(_ edge: PaneEdge) -> AppShortcut {
        switch edge {
        case .left: movePaneLeft
        case .right: movePaneRight
        case .top: movePaneUp
        case .bottom: movePaneDown
        }
    }

    // MARK: Terminal

    static let copy = AppShortcut(id: "copy", title: "Copy", detail: "Copy the selected terminal text.",
                                  group: .terminal, shortcut: KeyboardShortcut("c"))
    static let paste = AppShortcut(id: "paste", title: "Paste", detail: "Paste into the terminal, with a review of several command lines first.",
                                   group: .terminal, shortcut: KeyboardShortcut("v"))
    static let selectAll = AppShortcut(id: "selectAll", title: "Select All", detail: "Select the whole terminal buffer.",
                                       group: .terminal, shortcut: KeyboardShortcut("a"))
    static let find = AppShortcut(id: "find", title: "Find", detail: "Search the terminal’s text.",
                                  group: .terminal, shortcut: KeyboardShortcut("f"))

    // MARK: Files & Viewer

    static let toggleInspector = AppShortcut(id: "toggleInspector", title: "Show or Hide Inspector",
                                             detail: "Browse the files of the workspace or worktree.",
                                             group: .files, shortcut: KeyboardShortcut("i", modifiers: [.command, .option]))
    static let viewerZoomIn = AppShortcut(id: "viewerZoomIn", title: "Zoom In", detail: "Enlarge an image in the file viewer.",
                                          group: .files, shortcut: KeyboardShortcut("=", modifiers: .command))
    static let viewerZoomOut = AppShortcut(id: "viewerZoomOut", title: "Zoom Out", detail: "Shrink an image in the file viewer.",
                                           group: .files, shortcut: KeyboardShortcut("-", modifiers: .command))
    static let viewerFit = AppShortcut(id: "viewerFit", title: "Zoom to Fit", detail: "Fit an image to the file viewer.",
                                       group: .files, shortcut: KeyboardShortcut("0", modifiers: .command))

    // MARK: Source Control

    static let commit = AppShortcut(id: "commit", title: "Commit", detail: "Commit the staged changes on the Changes tab.",
                                    group: .sourceControl, shortcut: KeyboardShortcut(.return, modifiers: .command))
    static let saveDiffNote = AppShortcut(id: "saveDiffNote", title: "Save Note",
                                          detail: "Save the note you are writing on a diff for the agent.",
                                          group: .sourceControl, shortcut: DiffNoteComposer.saveShortcut)

    // MARK: App & Window

    static let settings = AppShortcut(id: "settings", title: "Settings", detail: "Show or hide Settings.",
                                      group: .app, shortcut: KeyboardShortcut(",", modifiers: .command))
    static let keyboardShortcuts = AppShortcut(id: "keyboardShortcuts", title: "Keyboard Shortcuts",
                                               detail: "Open this list from the Help menu.",
                                               group: .app, shortcut: KeyboardShortcut("/", modifiers: .command))
    static let closeSettings = AppShortcut(id: "closeSettings", title: "Back to Suijin",
                                           detail: "Leave Settings or the welcome tour, or cancel a sheet.",
                                           group: .app, shortcut: .cancelAction)
    static let designGallery = AppShortcut(id: "designGallery", title: "Design Gallery",
                                           detail: "Open the gallery of Suijin’s controls in a window of its own.",
                                           group: .app, shortcut: KeyboardShortcut("g", modifiers: [.command, .option, .shift]))

    /// Every keyboard shortcut, in display order within each group.
    static let all: [AppShortcut] = [
        newSession, newShell, newWorktree, addWorkspace, closeTab, previousTab, nextTab,
    ] + selectTabs + [
        splitRight, splitDown, zoomPane, equalizePanes,
        focusPaneLeft, focusPaneRight, focusPaneAbove, focusPaneBelow,
        movePaneLeft, movePaneRight, movePaneUp, movePaneDown,
        copy, paste, selectAll, find,
        toggleInspector, viewerZoomIn, viewerZoomOut, viewerFit,
        commit, saveDiffNote,
        settings, keyboardShortcuts, closeSettings, designGallery,
    ]

    /// The mouse gestures, shown as the last group.
    static let gestures: [MouseGesture] = [
        MouseGesture(id: "reorderTabs", title: "Reorder Tabs", detail: nil,
                     gesture: "Drag a tab onto another tab", systemImage: "hand.draw"),
        MouseGesture(id: "placePane", title: "Place a Pane",
                     detail: "Put the pane on that side of the other pane.",
                     gesture: "Drag a pane header onto an edge", systemImage: "rectangle.righthalf.inset.filled"),
        MouseGesture(id: "swapPanes", title: "Swap Panes", detail: nil,
                     gesture: "Drag a pane header onto the center of another pane", systemImage: "arrow.left.arrow.right"),
        MouseGesture(id: "paneToTab", title: "Move Pane to New Tab", detail: nil,
                     gesture: "Drag a pane header onto the tab bar", systemImage: "macwindow.badge.plus"),
        MouseGesture(id: "tabToPane", title: "Move a Tab into a Split", detail: "The tab becomes a pane on that side.",
                     gesture: "Drag a tab onto a pane", systemImage: "rectangle.split.2x1"),
        MouseGesture(id: "equalizeByDivider", title: "Equalize Panes", detail: "Every pane of that split gets the same room.",
                     gesture: "Double-click a divider", systemImage: "equal.square"),
        MouseGesture(id: "openPath", title: "Open a Path or Link",
                     detail: "Files open in a viewer tab, web links in the browser.",
                     gesture: "⌘-click it in a terminal", systemImage: "cursorarrow.click"),
        MouseGesture(id: "pathActions", title: "Path Actions",
                     detail: "Open with the default app, reveal in the file tree or Finder, copy, or find the full path of a shortened one.",
                     gesture: "Right-click a path in a terminal", systemImage: "contextualmenu.and.cursorarrow"),
        MouseGesture(id: "zoomImage", title: "Zoom an Image", detail: "Zooms around the pointer in the image viewer.",
                     gesture: "Scroll with ⌘ or ⌥ held", systemImage: "plus.magnifyingglass"),
        MouseGesture(id: "fitImage", title: "Fit or Actual Size", detail: "Switches an image between fitting the pane and its own size.",
                     gesture: "Double-click an image", systemImage: "arrow.up.left.and.down.right.magnifyingglass"),
        MouseGesture(id: "panImage", title: "Move a Zoomed Image", detail: nil,
                     gesture: "Drag the image", systemImage: "hand.raised"),
    ]

    private static func focus(_ id: String, _ title: LocalizedStringResource, _ key: KeyEquivalent) -> AppShortcut {
        AppShortcut(id: id, title: title, detail: "Move the keyboard focus to the pane next to this one.",
                    group: .panes, shortcut: KeyboardShortcut(key, modifiers: [.command, .option]))
    }

    private static func move(_ id: String, _ title: LocalizedStringResource, _ key: KeyEquivalent) -> AppShortcut {
        AppShortcut(id: id, title: title, detail: "Swap the focused pane with the one next to it.",
                    group: .panes, shortcut: KeyboardShortcut(key, modifiers: [.command, .option, .control]))
    }
}

/// Menu glyphs for a shortcut, modifiers in the system order (⌃⌥⇧⌘) and then the key.
enum ShortcutGlyphs {
    static func text(for shortcut: KeyboardShortcut) -> String {
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        return text + key(shortcut.key)
    }

    private static func key(_ key: KeyEquivalent) -> String {
        switch key {
        case .return: "↩"
        case .escape: "Esc"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .tab: "⇥"
        case .delete: "⌫"
        case .space: "Space"
        default: String(key.character).uppercased()
        }
    }
}

/// A group of the Shortcuts settings after a search.
struct ShortcutSection: Identifiable {
    let group: ShortcutGroup
    let shortcuts: [AppShortcut]
    let gestures: [MouseGesture]

    var id: ShortcutGroup { group }
}

extension ShortcutCatalog {
    /// The groups with the entries matching `query` by action name, description, group, key glyphs ("⌘D") or spoken
    /// keys ("command d"); every entry when the query is blank. Groups without a match are left out.
    static func sections(matching query: String) -> [ShortcutSection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ fields: [String]) -> Bool {
            query.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return ShortcutGroup.allCases.compactMap { group in
            let groupTitle = String(localized: group.title)
            let shortcuts = all.filter { entry in
                entry.group == group && matches([
                    String(localized: entry.title), entry.detail.map { String(localized: $0) } ?? "", groupTitle,
                    entry.glyphs, ShortcutSpeech.label(for: entry.glyphs),
                ])
            }
            let gestures = group != .mouse ? [] : self.gestures.filter { gesture in
                matches([String(localized: gesture.title), gesture.detail.map { String(localized: $0) } ?? "",
                         String(localized: gesture.gesture), groupTitle])
            }
            return shortcuts.isEmpty && gestures.isEmpty ? nil : ShortcutSection(group: group, shortcuts: shortcuts, gestures: gestures)
        }
    }
}
