import AppKit
import SevindaAgents
import SevindaCore
import SwiftUI

/// Context-menu items of a sidebar row that holds sessions (a folder's sessions, a main checkout, a worktree): start
/// sessions there, open its changes, fold it, and close its sessions in bulk. `closeAll` asks the row to confirm.
struct ContextRowMenuItems: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext
    let closeAll: () -> Void

    var body: some View {
        let sessions = model.tabSessions(in: context)
        let finished = sessions.filter { model.runtimes.runtime(for: $0.id) == nil || model.runtimes.activity(of: $0).isEnded }
        Section {
            ForEach([AgentKind.claude, .codex, .shell], id: \.self) { agent in
                Button { start(agent) } label: {
                    Label {
                        Text(agent == .shell ? "New Shell" : "New \(NewSessionMenu.name(of: agent)) Session")
                    } icon: {
                        if agent == .shell { Image(systemName: "terminal") } else { Image(nsImage: NewSessionMenu.menuIcon(agent)) }
                    }
                }
            }
        }
        if model.isGitContext(context) {
            Button("Show Changes") {
                model.selection = context
                model.selectedTab[context] = .changes
            }
        }
        if !sessions.isEmpty {
            Divider()
            let collapsed = model.collapsedContexts.contains(context)
            Button(collapsed ? "Expand Sessions" : "Collapse Sessions") {
                withAnimation(.snappy(duration: 0.2)) {
                    if collapsed { model.collapsedContexts.remove(context) } else { model.collapsedContexts.insert(context) }
                }
            }
            if !finished.isEmpty {
                Button("Close Finished Sessions (\(finished.count))") {
                    Task { await model.closeSessions(finished.map(\.id)) }
                }
            }
            Button("Close All Sessions (\(sessions.count))…", role: .destructive, action: closeAll)
        }
        if let directory = model.directory(of: context) {
            Divider()
            Button("Copy Path") { copy(directory.path) }
        }
    }

    private func start(_ agent: AgentKind) {
        Task { await model.runtimes.start(in: context, agent: agent, accountID: nil, prompt: nil) }
    }
}

/// Context-menu items of one session (its sidebar row and its tab): another like it, start an ended one again, copy
/// where it runs, and close it or the others beside it.
struct SessionMenuItems: View {
    @Environment(AppModel.self) private var model
    let session: AgentSessionRecord

    var body: some View {
        let context = model.context(of: session)
        let ended = model.runtimes.runtime(for: session.id) == nil || model.runtimes.activity(of: session).isEnded
        Button("New Session Like This") {
            Task { await model.runtimes.start(in: context, agent: session.agent, accountID: session.accountID, prompt: nil) }
        }
        if ended {
            if model.canResume(session) {
                Button("Resume Session") { Task { await model.resume(session) } }
            }
            Button("Start Again") { Task { await model.startAgain(session) } }
        }
        Button("Copy Working Directory") { copy(session.cwd) }
        Divider()
        let layout = model.layout(containing: session.id)
        PaneMenuItems(session: session.id, layout: layout)
        if layout == nil { Divider() }
        let others = model.tabSessions(in: context).filter { $0.id != session.id }
        if !others.isEmpty {
            Button("Close Other Sessions (\(others.count))") { Task { await model.closeSessions(others.map(\.id)) } }
        }
        // A split tab closes with all its panes, as its close button does; Close Pane above closes this one.
        Button("Close Tab", role: .destructive) { model.requestCloseTab(model.tab(of: session.id)) }
    }
}

/// Context-menu items of a pane (its header) or of a session that can become one (its tab, its sidebar row): split
/// beside it, then, in a split tab, zoom, equalize, take it out to a tab of its own and close it. The shortcuts shown
/// are those of the Session menu commands, which act on the focused pane.
struct PaneMenuItems: View {
    @Environment(AppModel.self) private var model
    let session: UUID
    /// The split tab the session is a pane of; nil for a plain tab.
    let layout: PaneLayout?

    var body: some View {
        let canAdd = model.canAddPane(beside: session)
        Button("Split Right") { model.split(beside: session, edge: .right) }
            .keyboardShortcut(ShortcutCatalog.splitRight.shortcut)
            .disabled(!canAdd)
        Button("Split Down") { model.split(beside: session, edge: .bottom) }
            .keyboardShortcut(ShortcutCatalog.splitDown.shortcut)
            .disabled(!canAdd)
        if let layout {
            Divider()
            Button(layout.zoomed == session ? "Show All Panes" : "Zoom Pane") { model.toggleZoom(session) }
                .keyboardShortcut(ShortcutCatalog.zoomPane.shortcut)
            Button("Equalize Panes") { model.equalizePanes(layout.id) }
                .keyboardShortcut(ShortcutCatalog.equalizePanes.shortcut)
            Button("Move Pane to New Tab") { model.movePaneToNewTab(session) }
            Divider()
            Button("Close Pane", role: .destructive) { model.requestClose(session) }
                .keyboardShortcut(ShortcutCatalog.closeTab.shortcut)
        }
    }
}

/// Asks before closing every session of a context when agents in it are still working.
struct CloseAllConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    let context: SessionContext
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        let sessions = model.tabSessions(in: context)
        let busy = sessions.filter { model.runtimes.displayAgent(of: $0) != .shell && !model.runtimes.activity(of: $0).isEnded }.count
        content.confirmationDialog(Text("Close all \(sessions.count) sessions?"), isPresented: $isPresented) {
            Button("Close All", role: .destructive) { Task { await model.closeSessions(sessions.map(\.id)) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if busy > 0 {
                Text("\(busy) agents are still working; closing stops them.")
            } else {
                Text("Every session in this list ends and its tab closes.")
            }
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

extension SessionActivityDisplay {
    /// The session's process is gone.
    var isEnded: Bool { self == .exited || self == .failed }
}

extension AppModel {
    /// Closes several sessions, one after another (each stops its process first).
    func closeSessions(_ ids: [UUID]) async {
        for id in ids { await closeSession(id) }
    }

    /// Replaces an ended session with a new one of the same agent and account, in the same tab position's context.
    func startAgain(_ session: AgentSessionRecord) async {
        let context = context(of: session)
        await closeSession(session.id)
        await runtimes.start(in: context, agent: session.agent, accountID: session.accountID, prompt: nil)
    }

    /// Whether an ended session can continue its conversation: a Claude or Codex session whose conversation id Sevinda
    /// learned (from Claude's hooks or the hint the CLI printed as it exited).
    func canResume(_ session: AgentSessionRecord) -> Bool {
        session.agent != .shell && session.agentSessionID.flatMap(AgentResume.validSessionID) != nil
    }

    /// Relaunches an ended agent session with its conversation, in the same tab or pane.
    func resume(_ session: AgentSessionRecord) async {
        await runtimes.resume(session)
    }

    /// Whether `context` belongs to a git workspace (so it has changes to show).
    func isGitContext(_ context: SessionContext) -> Bool {
        workspaceID(of: context).flatMap(workspace)?.kind == .git
    }
}
