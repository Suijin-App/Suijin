import AppKit
import SevindaCore
import SevindaTerminal

/// Tab actions shared by the menus, the tab strip and the terminal's own shortcuts; panes are in `PaneLayouts.swift`.
extension AppModel {
    /// The session and split tabs of a context, in tab order.
    func sessionTabs(in context: SessionContext) -> [DetailTab] {
        var seen = Set<DetailTab>()
        return sessions(in: context).compactMap { session in
            let tab = tab(of: session.id)
            return seen.insert(tab).inserted ? tab : nil
        }
    }

    /// Every session of a context in tab order; the panes of a split tab together, in reading order.
    func tabSessions(in context: SessionContext) -> [AgentSessionRecord] {
        let records = Dictionary(sessions(in: context).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sessionTabs(in: context).flatMap { panes(of: $0).compactMap { records[$0] } }
    }

    /// Every tab of a context in order: sessions and split tabs, then Changes (git), then opened files.
    func tabList(in context: SessionContext) -> [DetailTab] {
        var tabs = sessionTabs(in: context)
        if let id = workspaceID(of: context), workspace(id)?.kind == .git { tabs.append(.changes) }
        tabs += (openFiles[context] ?? []).map { .file($0) }
        return tabs
    }

    /// The tab shown for a context: the selected one while it still exists, else the last session tab.
    func currentTab(in context: SessionContext) -> DetailTab? {
        if let tab = selectedTab[context], tabList(in: context).contains(tab) { return tab }
        return sessionTabs(in: context).last
    }

    /// The pane with focus in the selected tab: the tab's session, or a split tab's focused pane (kept by
    /// `focusPane`, which every terminal reports to when it becomes first responder). Nil for Changes and files.
    func activeSession(in context: SessionContext) -> UUID? {
        switch currentTab(in: context) {
        case .session(let id)?: id
        case .panes(let id)?: paneLayouts[id]?.focused
        case .changes?, .file?, nil: nil
        }
    }

    var defaultAgent: AgentKind {
        setting(.defaultAgent).flatMap(AgentKind.init(rawValue:)) ?? .claude
    }

    func newTab(in context: SessionContext, agent: AgentKind? = nil) {
        Task { await runtimes.start(in: context, agent: agent ?? defaultAgent, accountID: nil, prompt: nil) }
    }

    /// Closes the focused pane (the tab, when it has one pane); a file tab closes its file.
    func closeActive(in context: SessionContext) {
        if case .file(let path)? = currentTab(in: context) { closeFile(path, in: context); return }
        guard let id = activeSession(in: context) else { return }
        requestClose(id)
    }

    /// Closes a session (its tab, or its pane); a running agent is confirmed first, as a terminal confirms closing a
    /// busy process. Shells and ended sessions close at once.
    func requestClose(_ id: UUID) {
        requestClose([id])
    }

    /// Closes every pane of a tab, confirming once when agents among them still work.
    func requestCloseTab(_ tab: DetailTab) {
        switch tab {
        case .session, .panes: requestClose(panes(of: tab))
        case .file(let path): if let context = selection { closeFile(path, in: context) }
        case .changes: break
        }
    }

    private func requestClose(_ ids: [UUID]) {
        let busyStates: Set<SessionActivityDisplay> = [.starting, .running, .waitingForInput, .idle]
        let records = ids.compactMap { id in sessions.first { $0.id == id } }
        let busy = records.filter { $0.agent != .shell && runtimes.runtime(for: $0.id) != nil && busyStates.contains(runtimes.activity(of: $0)) }
        if busy.isEmpty {
            Task { await closeSessions(records.map(\.id)) }
        } else {
            pendingClose = PendingClose(sessions: records.map(\.id), busy: busy)
        }
    }

    /// Adds a pane beside the selected tab's focused pane: on its right (`.sideBySide`, ⌘D) or below it (`.stacked`,
    /// ⇧⌘D), running what Settings → Agents → New pane runs says. Nothing when no session tab is selected or the tab
    /// is full.
    func split(in context: SessionContext, axis: PaneAxis) {
        Task { await addPane(in: context, axis: axis) }
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
        case .focusPane(let direction):
            focusPane(pane)
            focusNeighborPane(in: context, toward: PaneEdge(direction))
        case .movePane(let direction):
            focusPane(pane)
            moveFocusedPane(in: context, toward: PaneEdge(direction))
        case .zoomPane: if layout(containing: pane) != nil { toggleZoom(pane) }
        case .equalizePanes: if let layout = layout(containing: pane) { equalizePanes(layout.id) }
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

extension PaneEdge {
    /// The side a pane-focus or pane-move shortcut points to.
    init(_ direction: TerminalKeyRoute.Direction) {
        switch direction {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .top
        case .down: self = .bottom
        }
    }
}
