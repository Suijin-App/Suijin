import Foundation
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

    /// The pane with focus: the second pane of a split tab when the user clicked it, else the tab's session.
    func activeSession(in context: SessionContext) -> UUID? {
        guard let tab = selectedSession(in: context) else { return nil }
        return focusedPane[tab] ?? tab
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

    /// Handles a tab or split shortcut typed in a terminal; returns whether it was handled.
    func handle(_ route: TerminalKeyRoute, in context: SessionContext) -> Bool {
        switch route {
        case .newTab: newTab(in: context)
        case .closeTab: closeActive(in: context)
        case .splitRight: split(in: context, axis: .sideBySide)
        case .splitDown: split(in: context, axis: .stacked)
        case .previousTab: selectAdjacentTab(in: context, offset: -1)
        case .nextTab: selectAdjacentTab(in: context, offset: 1)
        default: return false
        }
        return true
    }
}
