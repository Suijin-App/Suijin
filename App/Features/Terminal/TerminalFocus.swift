import AppKit

extension AppModel {
    /// Gives the keyboard to the selected context's active terminal once the current click is over. The list that
    /// was clicked takes the focus while it tracks the mouse, so focusing earlier (as the pane does when it updates)
    /// would be undone when the button comes up.
    func focusActiveTerminalAfterClick(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Still pressed: the list is tracking the mouse; try again shortly (for a second at most).
                if NSEvent.pressedMouseButtons != 0 {
                    if attempt < 33 { self.focusActiveTerminalAfterClick(attempt: attempt + 1) }
                    return
                }
                guard let context = self.selection, let id = self.activeSession(in: context),
                      let view = self.runtimes.runtime(for: id)?.terminal.view, let window = view.window else { return }
                // Only take the focus from the list itself, never from a field or sheet the user moved to meanwhile.
                guard window.firstResponder === window || window.firstResponder is NSTableView else { return }
                window.makeFirstResponder(view)
            }
        }
    }
}

/// A click anywhere in the sidebar list (a session, its context, or the row already selected) leaves the keyboard in
/// the selected session's terminal rather than in the list, where the arrow keys would switch sessions instead of
/// moving through an agent's menu. Watching clicks, not selection changes, also covers a click that selects nothing
/// new. The arrow keys still move through the list once it has the keyboard some other way (Tab, ⌥⌘S).
@MainActor
enum SidebarClickFocus {
    private static var monitor: Any?

    static func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak model] event in
            if let model, let window = event.window, window === model.mainWindow,
               let hit = window.contentView?.hitTest(event.locationInWindow), isInSidebarList(hit) {
                model.focusActiveTerminalAfterClick()
            }
            return event
        }
    }

    /// The sidebar list is the list in the leading pane of the window's split view (the inspector's file tree sits in
    /// a trailing pane). SwiftUI does not pass an accessibility identifier down to the AppKit list.
    static func isInSidebarList(_ view: NSView) -> Bool {
        var current: NSView? = view
        var list: NSTableView?
        while let candidate = current {
            if list == nil, let table = candidate as? NSTableView { list = table }
            if let list, let split = candidate as? NSSplitView {
                return split.arrangedSubviews.first.map { list.isDescendant(of: $0) } ?? false
            }
            current = candidate.superview
        }
        return false
    }
}
