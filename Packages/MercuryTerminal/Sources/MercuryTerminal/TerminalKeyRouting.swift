import AppKit

/// Who handles a ⌘ key press while a terminal has keyboard focus.
///
/// Copy, paste (through the paste guard), select all and find belong to the terminal view. Tab and split shortcuts
/// (⌘T, ⌘W, ⇧⌘[ / ⇧⌘], ⌘D, ⇧⌘D) go to the session's owner through `MercuryTerminalView.onKeyRoute`. Every other ⌘
/// shortcut goes on to the app's menus. Keys without ⌘ take the normal event path, where SwiftTerm turns them into
/// terminal input (and input methods such as Vietnamese Telex compose text), so nothing here touches them.
public enum TerminalKeyRoute: Equatable, Sendable {
    case newTab
    case closeTab
    case previousTab
    case nextTab
    case splitRight
    case splitDown
    case copy
    case paste
    case selectAll
    case find
    /// Handled by the app's menus.
    case app
    /// Normal key handling by the terminal view.
    case terminal
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
        return .app
    }
}
