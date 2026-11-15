import AppKit
import Foundation
import SuijinCore
import SuijinTerminal
import SwiftUI
import Testing
@testable import Suijin

/// The Shortcuts settings list `ShortcutCatalog`; these tests keep it equal to the real bindings.
@MainActor
struct ShortcutCatalogTests {
    // MARK: Catalog

    @Test func idsAreUnique() {
        let ids = ShortcutCatalog.all.map(\.id) + ShortcutCatalog.gestures.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// Two actions on one key only where they can never both be reachable: the commit field and a diff note editor.
    @Test func noTwoShortcutsShareKeys() {
        let contextual: Set<String> = ["commit", "saveDiffNote"]
        let byKeys = Dictionary(grouping: ShortcutCatalog.all.filter { !contextual.contains($0.id) }, by: \.shortcut)
        let clashes = byKeys.values.filter { $0.count > 1 }.map { $0.map(\.id) }
        #expect(clashes.isEmpty, "Shortcuts sharing keys: \(clashes)")
    }

    @Test func everyGroupHasEntries() {
        for group in ShortcutGroup.allCases {
            let count = ShortcutCatalog.all.filter { $0.group == group }.count
                + (group == .mouse ? ShortcutCatalog.gestures.count : 0)
            #expect(count > 0, "\(group) is empty")
        }
        #expect(ShortcutCatalog.all.allSatisfy { $0.group != .mouse })
    }

    @Test func settingsListShortcutsBeforeAbout() {
        let pages = SettingsPage.allCases
        #expect(pages.firstIndex(of: .shortcuts) == pages.count - 2)
        #expect(SettingsPage.shortcuts.systemImage == "keyboard")
    }

    @Test func glyphsFollowTheMenuOrder() {
        #expect(ShortcutCatalog.splitRight.glyphs == "⌘D")
        #expect(ShortcutCatalog.splitDown.glyphs == "⇧⌘D")
        #expect(ShortcutCatalog.movePaneLeft.glyphs == "⌃⌥⌘←")
        #expect(ShortcutCatalog.zoomPane.glyphs == "⇧⌘↩")
        #expect(ShortcutCatalog.designGallery.glyphs == "⌥⇧⌘G")
        #expect(ShortcutCatalog.closeSettings.glyphs == "Esc")
        #expect(ShortcutCatalog.keyboardShortcuts.glyphs == "⌘/")
    }

    @Test func rowsAreSpokenByName() {
        #expect(ShortcutSpeech.label(for: ShortcutCatalog.splitRight.glyphs) == "Command D")
        #expect(ShortcutSpeech.label(for: ShortcutCatalog.equalizePanes.glyphs) == "Control Command Equals")
        #expect(ShortcutSpeech.label(for: ShortcutCatalog.previousTab.glyphs) == "Shift Command Left Bracket")
        #expect(ShortcutSpeech.label(for: ShortcutCatalog.closeSettings.glyphs) == "Escape")
        #expect(ShortcutSpeech.label(for: "⇧Space") == "Shift Space")
    }

    @Test func tabNumbersAreListedAndFoundByTab() {
        #expect(ShortcutCatalog.selectTabs.map(\.glyphs) == (1...9).map { "⌘\($0)" })
        #expect(ShortcutCatalog.selectTab(1).id == "selectTab1")
        #expect(ShortcutCatalog.selectTab(9).id == "selectLastTab")
        let found = ShortcutCatalog.sections(matching: "tab").flatMap { $0.shortcuts.map(\.id) }
        #expect(ShortcutCatalog.selectTabs.allSatisfy { found.contains($0.id) })
        // ⌘0 stays with the image viewer.
        #expect(ShortcutCatalog.viewerFit.glyphs == "⌘0")
    }

    @Test func tabNumbersCountFromTheFirstTabAndNineIsTheLast() {
        #expect(AppModel.tabIndex(forNumber: 1, count: 3) == 0)
        #expect(AppModel.tabIndex(forNumber: 3, count: 3) == 2)
        #expect(AppModel.tabIndex(forNumber: 5, count: 3) == nil)
        #expect(AppModel.tabIndex(forNumber: 9, count: 3) == 2)
        #expect(AppModel.tabIndex(forNumber: 9, count: 12) == 11)
        #expect(AppModel.tabIndex(forNumber: 8, count: 12) == 7)
        #expect(AppModel.tabIndex(forNumber: 1, count: 0) == nil)
        #expect(AppModel.tabIndex(forNumber: 9, count: 0) == nil)
        #expect(AppModel.tabIndex(forNumber: 0, count: 3) == nil)
        #expect(AppModel.tabIndex(forNumber: 10, count: 12) == nil)
    }

    // MARK: Search

    @Test func searchMatchesActionNames() {
        let sections = ShortcutCatalog.sections(matching: "split")
        let ids = sections.flatMap { $0.shortcuts.map(\.id) }
        #expect(Array(ids.filter { $0.hasPrefix("split") }) == ["splitRight", "splitDown"])
        #expect(!ids.contains("newSession"))
        #expect(sections.map(\.group).contains(.panes))
    }

    @Test func searchMatchesKeys() {
        let ids = ShortcutCatalog.sections(matching: "⌘D").flatMap { $0.shortcuts.map(\.id) }
        #expect(ids == ["splitRight", "splitDown"])
        let spoken = ShortcutCatalog.sections(matching: "shift command d").flatMap { $0.shortcuts.map(\.id) }
        #expect(spoken == ["splitDown"])
        let exact = ShortcutCatalog.sections(matching: "⇧⌘D").flatMap { $0.shortcuts.map(\.id) }
        #expect(exact == ["splitDown"])
    }

    @Test func searchFindsGestures() {
        let sections = ShortcutCatalog.sections(matching: "double-click")
        #expect(sections.map(\.group) == [.mouse])
        #expect(sections.first?.gestures.map(\.id) == ["equalizeByDivider", "fitImage"])
    }

    @Test func blankSearchShowsEverythingAndNoMatchShowsNothing() {
        let all = ShortcutCatalog.sections(matching: "  ")
        #expect(all.map(\.group) == ShortcutGroup.allCases)
        #expect(all.flatMap(\.shortcuts).count == ShortcutCatalog.all.count)
        #expect(ShortcutCatalog.sections(matching: "zzzz-no-such-action").isEmpty)
    }

    // MARK: Terminal key routes

    /// The catalog entry of each route. Exhaustive on purpose: a new route does not compile until it is listed here.
    private func entry(for route: TerminalKeyRoute) -> AppShortcut? {
        switch route {
        case .newTab: ShortcutCatalog.newSession
        case .closeTab: ShortcutCatalog.closeTab
        case .previousTab: ShortcutCatalog.previousTab
        case .nextTab: ShortcutCatalog.nextTab
        case .selectTab(let number): ShortcutCatalog.selectTab(number)
        case .splitRight: ShortcutCatalog.splitRight
        case .splitDown: ShortcutCatalog.splitDown
        case .focusPane(let direction): ShortcutCatalog.focusPane(edge(direction))
        case .movePane(let direction): ShortcutCatalog.movePane(edge(direction))
        case .zoomPane: ShortcutCatalog.zoomPane
        case .equalizePanes: ShortcutCatalog.equalizePanes
        case .copy: ShortcutCatalog.copy
        case .paste: ShortcutCatalog.paste
        case .selectAll: ShortcutCatalog.selectAll
        case .find: ShortcutCatalog.find
        case .app, .terminal: nil
        }
    }

    private func edge(_ direction: TerminalKeyRoute.Direction) -> PaneEdge {
        switch direction {
        case .left: .left
        case .right: .right
        case .up: .top
        case .down: .bottom
        }
    }

    private static let directions: [TerminalKeyRoute.Direction] = [.left, .right, .up, .down]
    private static let routes: [TerminalKeyRoute] = [
        .newTab, .closeTab, .previousTab, .nextTab, .splitRight, .splitDown, .zoomPane, .equalizePanes,
        .copy, .paste, .selectAll, .find,
    ] + directions.map { .focusPane($0) } + directions.map { .movePane($0) } + (1...9).map { .selectTab($0) }

    /// What a terminal does with the catalog entry's keys.
    private func route(of shortcut: KeyboardShortcut) -> TerminalKeyRoute {
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        return TerminalKeyRouter.route(key: String(shortcut.key.character), modifiers: flags)
    }

    /// Every shortcut a terminal handles itself is in the catalog with the same keys.
    @Test func everyTerminalRouteIsInTheCatalog() throws {
        for route in Self.routes {
            let entry = try #require(entry(for: route), "\(route) has no catalog entry")
            #expect(ShortcutCatalog.all.contains { $0.id == entry.id }, "\(entry.id) is missing from ShortcutCatalog.all")
            #expect(self.route(of: entry.shortcut) == route, "\(entry.id) (\(entry.glyphs)) does not route to \(route)")
        }
    }

    /// Every catalog shortcut either reaches its own action from a terminal or goes on to the menus, never to
    /// another action.
    @Test func catalogKeysRouteToTheirOwnAction() {
        for shortcut in ShortcutCatalog.all {
            let routed = route(of: shortcut.shortcut)
            if let owner = entry(for: routed) {
                #expect(owner.id == shortcut.id, "\(shortcut.glyphs) is listed as \(shortcut.id) but a terminal runs \(owner.id)")
            } else {
                #expect(routed != .terminal || !shortcut.shortcut.modifiers.contains(.command),
                        "\(shortcut.id) would be typed into the terminal")
            }
        }
    }

    // MARK: Bindings

    /// Every `.keyboardShortcut(…)` in the app binds a catalog entry (or a sheet's standard Return / Esc button), so a
    /// menu command cannot have keys the Shortcuts settings do not show.
    @Test func everyAppBindingComesFromTheCatalog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("App")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 20, "the App sources were not found at \(app.path)")
        let allowed = ["ShortcutCatalog.", ".defaultAction)", ".cancelAction)"]
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                guard let range = line.range(of: ".keyboardShortcut(") else { continue }
                let arguments = line[range.upperBound...]
                if !allowed.contains(where: { arguments.hasPrefix($0) }) {
                    offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, "Bind these through ShortcutCatalog: \(offenders)")
    }

    @Test func standardBindingsMatchTheCatalog() {
        #expect(ShortcutCatalog.saveDiffNote.shortcut == KeyboardShortcut(.return, modifiers: .command))
        #expect(ShortcutCatalog.closeSettings.shortcut == .cancelAction)
    }
}
