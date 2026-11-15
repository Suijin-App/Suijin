import AppKit
import SuijinCore
import SuijinTerminal
import SwiftUI

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
        return Self.arrange(tabs, by: tabOrder[context] ?? [])
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
        let busy = records.filter { runtimes.displayAgent(of: $0) != .shell && runtimes.runtime(for: $0.id) != nil && busyStates.contains(runtimes.activity(of: $0)) }
        if busy.isEmpty || setting(.confirmClosingBusyAgents) == "false" {
            Task { await closeSessions(records.map(\.id)) }
        } else {
            pendingClose = PendingClose(sessions: records.map(\.id), busy: busy)
        }
    }

    /// The user confirmed the pending close; with `dontAskAgain` later ones close without asking (Settings → General
    /// turns the question back on).
    func confirmPendingClose(dontAskAgain: Bool) {
        guard let pending = pendingClose else { return }
        pendingClose = nil
        if dontAskAgain { setSetting(.confirmClosingBusyAgents, "false") }
        Task { await closeSessions(pending.sessions) }
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

    /// Selects the tab with that number in the tab bar (⌘1…⌘8), or the last tab for 9, as browsers do. Nothing when
    /// there is no such tab.
    func selectTab(number: Int, in context: SessionContext) {
        let tabs = tabList(in: context)
        guard let index = Self.tabIndex(forNumber: number, count: tabs.count) else { return }
        selectedTab[context] = tabs[index]
    }

    /// The position of tab `number` among `count` tabs: 1…8 count from the first tab, 9 is the last one. Nil when the
    /// number is not 1…9 or there is no tab at that position.
    nonisolated static func tabIndex(forNumber number: Int, count: Int) -> Int? {
        guard count > 0, (1...9).contains(number) else { return nil }
        if number == 9 { return count - 1 }
        return number <= count ? number - 1 : nil
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
        case .selectTab(let number): selectTab(number: number, in: context)
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

/// Asks before closing a tab whose agents still work, with "Don't ask again". It is attached to a view of its own (as
/// `PermissionConfirmationAlert` is): `dialogSuppressionToggle` reaches every dialog of the view it modifies, so two
/// dialogs on one view would share one checkbox, and ticking it in one dialog would count for the other.
struct CloseConfirmationDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var dontAskAgain = false

    /// "End Claude?" for one working agent, "End 2 sessions?" for several.
    private var title: Text {
        guard let pending = model.pendingClose else { return Text(verbatim: "") }
        if pending.busy.count == 1, let record = pending.busy.first { return Text("End \(record.title)?") }
        return Text("End \(pending.busy.count) sessions?")
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(get: { model.pendingClose != nil },
                                 set: { if !$0 { model.pendingClose = nil; dontAskAgain = false } }),
            presenting: model.pendingClose
        ) { pending in
            Button(pending.busy.count == 1 ? "End Session" : "End Sessions", role: .destructive) {
                let suppress = dontAskAgain
                dontAskAgain = false
                model.confirmPendingClose(dontAskAgain: suppress)
            }
            Button("Cancel", role: .cancel) { dontAskAgain = false }
        } message: { pending in
            if pending.busy.count == 1 {
                Text("The agent is still working. Closing the tab stops it.")
            } else {
                Text("\(pending.busy.count) agents are still working. Closing the tab stops them.")
            }
        }
        .dialogSuppressionToggle("Don’t ask again", isSuppressed: $dontAskAgain)
    }
}
