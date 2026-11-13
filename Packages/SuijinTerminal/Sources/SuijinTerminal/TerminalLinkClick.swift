import AppKit

/// Decides whether a mouse click opens the link under it. The terminal still receives every press and release it would
/// otherwise (selection, word and line selection, clicks sent to the program); opening is only added on top:
///
/// | Click | Opens |
/// |---|---|
/// | ⌘-click on a link, without moving | at once, in either mode |
/// | plain single click, "Click" mode, program not reading the mouse, pane already focused, no selection before or after | after the double-click interval, unless a second click comes |
/// | a drag, a double or triple click, Shift/Option/Control held | never |
/// | the first click on a pane that did not have the keyboard | never: it only focuses the pane |
/// | press and release on different links, or off a link | never |
struct TerminalLinkClick: Equatable {
    enum Decision: Equatable {
        case none
        case openNow(TerminalLink)
        /// Wait out the double-click interval: the press may be the first of a double click that selects a word.
        case openAfterDoubleClickInterval(TerminalLink)
    }

    /// How far the pointer may move between press and release, in points, and still count as a click.
    static let dragThreshold: CGFloat = 3

    var trigger: TerminalLinkTrigger
    var clickCount: Int
    var modifiers: NSEvent.ModifierFlags
    /// The pointer moved past `dragThreshold` while the button was down.
    var dragged: Bool
    var selectionWasActive: Bool
    var selectionIsActive: Bool
    var reportsMouse: Bool
    /// The pane had the keyboard before this press.
    var paneWasFocused: Bool
    var pressLink: TerminalLink?
    var releaseLink: TerminalLink?

    var decision: Decision {
        guard clickCount == 1, !dragged, let link = pressLink, link == releaseLink else { return .none }
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        if flags == .command { return .openNow(link) }
        guard flags.isEmpty, trigger == .click, !reportsMouse, paneWasFocused, !selectionWasActive, !selectionIsActive else {
            return .none
        }
        return .openAfterDoubleClickInterval(link)
    }
}

/// What a right-click found under the pointer, for the host to build a menu from.
public struct TerminalLinkMenuRequest {
    /// The underlined link at the pointer, when there is one.
    public var link: TerminalLink?
    /// Every candidate at the pointer, longest first (scrollback rows): paths not confirmed yet or missing, elided
    /// paths, links. Empty when only `link` is known.
    public var candidates: [TerminalPathMatch]
    /// Where the click was, in the terminal view's coordinates (to anchor a popover).
    public var point: CGPoint

    public init(link: TerminalLink?, candidates: [TerminalPathMatch], point: CGPoint) {
        self.link = link
        self.candidates = candidates
        self.point = point
    }
}
