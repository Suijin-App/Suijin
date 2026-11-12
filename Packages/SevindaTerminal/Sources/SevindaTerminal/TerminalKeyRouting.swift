import AppKit

/// Who handles a ⌘ key press while a terminal has keyboard focus.
///
/// Copy, paste (through the paste guard), select all and find belong to the terminal view. Tab, split and pane
/// shortcuts (⌘T, ⌘W, ⇧⌘[ / ⇧⌘], ⌘D, ⇧⌘D, ⌥⌘ and ⌃⌥⌘ arrows, ⇧⌘↩, ⌃⌘=) go to the session's owner through
/// `MercuryTerminalView.onKeyRoute`, so the program never receives them as escape sequences. Every other ⌘
/// shortcut goes on to the app's menus. Keys without ⌘ take the normal event path, where SwiftTerm turns them into
/// terminal input (and input methods such as Vietnamese Telex compose text), so nothing here touches them.
public enum TerminalKeyRoute: Equatable, Sendable {
    case newTab
    case closeTab
    case previousTab
    case nextTab
    case splitRight
    case splitDown
    /// ⌥⌘ arrow: focus the pane next to this one.
    case focusPane(Direction)
    /// ⌃⌥⌘ arrow: swap this pane with the one next to it.
    case movePane(Direction)
    /// ⇧⌘↩: show this pane alone, or all panes again.
    case zoomPane
    /// ⌃⌘=: every split of the tab shares its room equally.
    case equalizePanes
    case copy
    case paste
    case selectAll
    case find
    /// Handled by the app's menus.
    case app
    /// Normal key handling by the terminal view.
    case terminal
}

extension TerminalKeyRoute {
    public enum Direction: Equatable, Sendable {
        case left, right, up, down
    }
}

public enum TerminalKeyRouter {
    public static func route(_ event: NSEvent) -> TerminalKeyRoute {
        route(key: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags)
    }

    public static func route(key: String, modifiers: NSEvent.ModifierFlags) -> TerminalKeyRoute {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) else { return .terminal }
        let key = key.lowercased()
        let extra = flags.subtracting(.command)

        if extra.isEmpty {
            switch key {
            case "t": return .newTab
            case "w": return .closeTab
            case "d": return .splitRight
            case "c": return .copy
            case "v": return .paste
            case "a": return .selectAll
            case "f": return .find
            default: return .app
            }
        }
        // ⇧⌘[ and ⇧⌘]; with ⇧ held the key arrives as `{` / `}` on most layouts.
        if extra == [.shift], key == "[" || key == "{" { return .previousTab }
        if extra == [.shift], key == "]" || key == "}" { return .nextTab }
        if extra == [.shift], key == "d" { return .splitDown }
        if extra == [.shift], key == "\r" { return .zoomPane }
        if extra == [.control], key == "=" { return .equalizePanes }
        if extra == [.option], let direction = arrow(key) { return .focusPane(direction) }
        if extra == [.control, .option], let direction = arrow(key) { return .movePane(direction) }
        return .app
    }

    /// The direction of an arrow key (AppKit's function-key characters).
    private static func arrow(_ key: String) -> TerminalKeyRoute.Direction? {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return nil }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: return .left
        case NSRightArrowFunctionKey: return .right
        case NSUpArrowFunctionKey: return .up
        case NSDownArrowFunctionKey: return .down
        default: return nil
        }
    }
}
