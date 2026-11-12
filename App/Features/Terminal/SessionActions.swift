import AppKit
import MercuryCore
import MercuryTerminal

/// Tab and split actions shared by the menus, the tab strip and the terminal's own shortcuts.
extension AppModel {
    /// Sessions shown as tabs: second panes of splits live inside their tab.
    func tabSessions(in context: SessionContext) -> [AgentSessionRecord] {
        let secondaries = Set(splits.values.map(\.secondary))
        return sessions(in: context).filter { !secondaries.contains($0.id) }
    }

    /// Every tab of a context in order: sessions, then Changes (git), then opened files.
    func tabList(in context: SessionContext) -> [DetailTab] {
        var tabs: [DetailTab] = tabSessions(in: context).map { .session($0.id) }
        if let id = workspaceID(of: context), workspace(id)?.kind == .git { tabs.append(.changes) }
        tabs += (openFiles[context] ?? []).map { .file($0) }
        return tabs
    }

    /// The tab shown for a context: the selected one while it still exists, else the last session.
    func currentTab(in context: SessionContext) -> DetailTab? {
        if let tab = selectedTab[context], tabList(in: context).contains(tab) { return tab }
        return tabSessions(in: context).last.map { .session($0.id) }
    }

    /// The session the selected tab shows, if the tab is a session.
    func selectedSession(in context: SessionContext) -> UUID? {
        let tabs = tabSessions(in: context)
        switch currentTab(in: context) {
        case .session(let id)?: return tabs.contains { $0.id == id } ? id : nil
        case .changes?, .file?: return nil
        case nil: return tabs.last?.id
        }
    }

    /// The pane with focus in the selected tab: the pane focused last (`focusPane`, which every terminal reports to
    /// when it becomes first responder), else the tab's session.
    func activeSession(in context: SessionContext) -> UUID? {
        guard let tab = selectedSession(in: context) else { return nil }
        let panes = [tab] + (splits[tab].map { [$0.secondary] } ?? [])
        return focusedPane[tab].flatMap { panes.contains($0) ? $0 : nil } ?? tab
    }

    /// Marks a pane as its tab's focused pane. The one entry point: the pane's terminal reports here whenever it
    /// becomes first responder, however the keyboard got there.
    func focusPane(_ id: UUID) {
        if splits[id] != nil {
            if focusedPane[id] != nil { focusedPane[id] = nil }
        } else if let primary = splits.first(where: { $0.value.secondary == id })?.key, focusedPane[primary] != id {
            focusedPane[primary] = id
        }
    }

    var defaultAgent: AgentKind {
        setting(.defaultAgent).flatMap(AgentKind.init(rawValue:)) ?? .claude
    }

    func newTab(in context: SessionContext, agent: AgentKind? = nil) {
        Task { await runtimes.start(in: context, agent: agent ?? defaultAgent, accountID: nil, prompt: nil) }
    }

    /// Closes the focused pane (a split's second pane, or the tab); a file tab closes its file.
    func closeActive(in context: SessionContext) {
        if case .file(let path)? = currentTab(in: context) { closeFile(path, in: context); return }
        guard let id = activeSession(in: context) else { return }
        requestClose(id)
    }

    /// Closes a tab; a running agent is confirmed first, as a terminal confirms closing a busy process. Shells and
    /// ended sessions close at once.
    func requestClose(_ id: UUID) {
        guard let record = sessions.first(where: { $0.id == id }) else { return }
        let busy: Set<SessionActivityDisplay> = [.starting, .running, .waitingForInput, .idle]
        if record.agent != .shell, runtimes.runtime(for: id) != nil, busy.contains(runtimes.activity(of: record)) {
            pendingClose = record
        } else {
            Task { await closeSession(id) }
        }
    }

    /// Opens a shell next to the selected tab's session. A tab that is already split keeps its split.
    func split(in context: SessionContext, axis: TerminalSplit.Axis) {
        guard let primary = selectedSession(in: context), splits[primary] == nil else { return }
        Task {
            guard let secondary = await runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil) else { return }
            // The tab may have closed while the shell started; the shell then stays a tab of its own.
            guard sessions.contains(where: { $0.id == primary }) else { return }
            splits[primary] = TerminalSplit(secondary: secondary, axis: axis)
            focusedPane[primary] = secondary
            selectedTab[context] = .session(primary)
        }
    }

    func selectAdjacentTab(in context: SessionContext, offset: Int) {
        let tabs = tabList(in: context)
        guard !tabs.isEmpty else { return }
        let current = selectedTab[context].flatMap { tabs.firstIndex(of: $0) } ?? (tabs.count - 1)
        selectedTab[context] = tabs[(current + offset + tabs.count) % tabs.count]
    }

    /// Handles a tab or split shortcut typed in the terminal of session `pane`; returns whether it was handled. ⌘W
    /// closes that pane: the terminal that received the key is the one with the keyboard.
    func handle(_ route: TerminalKeyRoute, in context: SessionContext, from pane: UUID) -> Bool {
        switch route {
        case .newTab: newTab(in: context)
        case .closeTab: requestClose(pane)
        case .splitRight: split(in: context, axis: .sideBySide)
        case .splitDown: split(in: context, axis: .stacked)
        case .previousTab: selectAdjacentTab(in: context, offset: -1)
        case .nextTab: selectAdjacentTab(in: context, offset: 1)
        default: return false
        }
        return true
    }

    /// The Close Tab command (⌘W when no terminal has the keyboard): in the main window closes the focused pane or
    /// file tab, leaves the Changes tab for the tab before it, and closes a window with no tabs; in any other window
    /// (the gallery) closes that window.
    func performCloseCommand() {
        guard isMainWindowKey, let context = selection else {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        let isFileTab = if case .file? = currentTab(in: context) { true } else { false }
        if activeSession(in: context) != nil || isFileTab {
            closeActive(in: context)
        } else if selectedTab[context] == .changes, !tabSessions(in: context).isEmpty {
            selectAdjacentTab(in: context, offset: -1)
        } else if selectedTab[context] != .changes {
            NSApp.keyWindow?.performClose(nil)
        }
    }
}
