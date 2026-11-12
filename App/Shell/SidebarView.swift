import SevindaCore
import SevindaUI
import SwiftUI

/// A selectable sidebar row: a context (folder, main checkout, worktree) or one session in it.
enum SidebarItem: Hashable {
    case context(SessionContext)
    case session(UUID)
    /// The row of a split tab, above its panes.
    case paneTab(UUID)
}

/// Workspaces in the sidebar: each has a header with its badge and name; a git workspace lists its main checkout and
/// its worktrees, a folder workspace a single row. Rows show how many sessions run there and whether one waits.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
            ForEach(model.workspaces) { workspace in
                Section {
                    WorkspaceContextRow(context: .workspace(workspace.id), title: rootTitle(workspace),
                                        systemImage: workspace.kind == .git ? "house" : "terminal")
                    SidebarSessionRows(context: .workspace(workspace.id))
                    ForEach(model.worktrees[workspace.id] ?? []) { worktree in
                        WorktreeRow(worktree: worktree)
                        SidebarSessionRows(context: .worktree(worktree.id))
                    }
                } header: {
                    WorkspaceHeader(workspace: workspace)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            // A quiet line, as an empty list in Mail or Notes shows: the detail area already explains workspaces
            // and offers the actions, so the sidebar does not repeat a second large empty state.
            if model.isLoaded, model.workspaces.isEmpty {
                Text("No Workspaces")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AddWorkspaceButton()
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
    }

    /// The selected row: the open session's own row when its context is selected and expanded, else the context.
    /// Exactly one row is selected at a time.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                guard let context = model.selection else { return nil }
                if let id = model.activeSession(in: context), !model.collapsedContexts.contains(context),
                   model.sidebarSessions(in: context).contains(where: { $0.id == id }) {
                    return .session(id)
                }
                return .context(context)
            },
            set: { item in
                switch item {
                case .context(let context)?:
                    model.selection = context
                case .session(let id)?:
                    guard let record = model.sessions.first(where: { $0.id == id }) else { return }
                    let context = model.context(of: record)
                    model.selection = context
                    // A pane's session selects its split tab and focuses the pane.
                    model.selectedTab[context] = .session(id)
                case .paneTab(let id)?:
                    guard let pane = model.paneLayouts[id]?.focused,
                          let record = model.sessions.first(where: { $0.id == pane }) else { return }
                    let context = model.context(of: record)
                    model.selection = context
                    model.selectedTab[context] = .panes(id)
                case nil:
                    break
                }
            }
        )
    }

    private func rootTitle(_ workspace: Workspace) -> Text {
        workspace.kind == .git ? Text("Main checkout") : Text("Sessions")
    }
}

/// The sidebar's main action: a full-width prominent Liquid Glass button in the system accent color (a bordered
/// prominent button before macOS 26).
private struct AddWorkspaceButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassGroup {
            Button { AddWorkspaceFlow.run(model: model) } label: {
                Label("Add Workspace", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .glassProminentButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .help(Text("Add a git repository or a folder (⇧⌘O)"))
        }
        .padding(.horizontal, SevindaSpacing.m)
        .padding(.top, SevindaSpacing.s)
        .padding(.bottom, SevindaSpacing.m)
    }
}

/// A workspace's section header: badge, name, kind, and on hover the new-worktree button and the actions menu.
private struct WorkspaceHeader: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    @State private var isConfirmingRemoval = false
    @State private var isEditingIcon = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: SevindaSpacing.s) {
            Button { isEditingIcon = true } label: {
                WorkspaceBadge(workspace: workspace, imageDirectory: model.workspaceIconDirectory, size: 22)
            }
            .buttonStyle(.plain)
            .help(Text("Change icon and color"))
            .popover(isPresented: $isEditingIcon, arrowEdge: .trailing) {
                WorkspaceIconEditor(workspaceID: workspace.id)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: workspace.name)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(workspace.kind == .git ? "Git repository" : "Folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: SevindaSpacing.xs)
            HStack(spacing: 2) {
                if workspace.kind == .git {
                    Button { model.newWorktreeWorkspaceID = workspace.id } label: {
                        Image(systemName: "plus").imageScale(.medium)
                    }
                    .help(Text("New worktree (⌘N)"))
                    .accessibilityLabel(Text("New worktree in \(workspace.name)"))
                }
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis").imageScale(.medium)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Actions for \(workspace.name)"))
            }
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .opacity(isHovered || isEditingIcon ? 1 : 0)
        }
        .textCase(nil)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu { menuItems }
        .help(Text(verbatim: workspace.path))
        .confirmationDialog(Text("Remove “\(workspace.name)” from Sevinda?"), isPresented: $isConfirmingRemoval) {
            Button("Remove", role: .destructive) { Task { await model.removeWorkspace(workspace.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            let running = model.sessions.filter { $0.workspaceID == workspace.id && model.runtimes.runtime(for: $0.id) != nil }.count
            if running > 0 {
                Text("\(running) running sessions are stopped. Files and worktrees on disk are kept.")
            } else {
                Text("Files and worktrees on disk are kept.")
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if workspace.kind == .git {
            Button("New Worktree…") { model.newWorktreeWorkspaceID = workspace.id }
        }
        Button("Change Icon…") { isEditingIcon = true }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace.path)]) }
        Divider()
        Button("Remove Workspace…", role: .destructive) { isConfirmingRemoval = true }
    }
}

/// A sidebar row for a context: a fold chevron when it has sessions, its name and the most urgent activity of its
/// sessions. The sessions are rows of their own right below it (`SidebarSessionRows`), so the list keeps one flat,
/// stable set of rows: folding or the last session closing never swaps one kind of row for another, which the
/// outline view behind `List` draws badly (stale cells, two selected rows).
struct WorkspaceContextRow: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext
    let title: Text
    let systemImage: String
    /// Extra status next to the title (a worktree's pull request badge).
    var accessory: AnyView?
    /// Row-specific items appended to the context menu (a worktree's Finder, path and removal items).
    var extraMenuItems: AnyView?
    @State private var isConfirmingCloseAll = false

    var body: some View {
        let sessions = model.tabSessions(in: context)
        let isExpanded = !model.collapsedContexts.contains(context)
        HStack(spacing: 4) {
            // Custom on purpose: the native disclosure triangle comes only with `DisclosureGroup`/`OutlineGroup`,
            // whose row swapping is what breaks; this chevron toggles the same folded state.
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if isExpanded { model.collapsedContexts.insert(context) } else { model.collapsedContexts.remove(context) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(sessions.isEmpty ? 0 : 1)
            .disabled(sessions.isEmpty)
            .accessibilityLabel(isExpanded ? Text("Collapse sessions") : Text("Expand sessions"))
            Label {
                HStack {
                    title.lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: SevindaSpacing.xs)
                    accessory
                    ContextActivityBadge(sessions: sessions)
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .tag(SidebarItem.context(context))
        .contextMenu {
            ContextRowMenuItems(context: context) { isConfirmingCloseAll = true }
            if let extraMenuItems {
                Divider()
                extraMenuItems
            }
        }
        .modifier(CloseAllConfirmation(context: context, isPresented: $isConfirmingCloseAll))
    }
}

/// The sessions of a context as indented rows under it, while the context is expanded; orchestration workers follow
/// their coordinator.
struct SidebarSessionRows: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext

    var body: some View {
        if !model.collapsedContexts.contains(context) {
            ForEach(model.sidebarTabs(in: context), id: \.tab) { entry in
                if case .panes(let id) = entry.tab {
                    SidebarPaneTabRow(layoutID: id, sessions: entry.sessions)
                        .tag(SidebarItem.paneTab(id))
                }
                ForEach(entry.sessions) { session in
                    SidebarSessionRow(session: session, context: context, isPane: entry.sessions.count > 1 || entry.tab != .session(session.id))
                        .tag(SidebarItem.session(session.id))
                    WorkerTreeView(coordinator: session)
                }
            }
        }
    }
}

/// A tab as the sidebar lists it: a plain tab's session, or a split tab's panes under the tab's own row.
struct SidebarTabEntry {
    let tab: DetailTab
    let sessions: [AgentSessionRecord]
}

extension AppModel {
    /// Sessions listed under a context in the sidebar: every pane of its tabs, minus workers shown under their
    /// coordinator.
    func sidebarSessions(in context: SessionContext) -> [AgentSessionRecord] {
        sidebarTabs(in: context).flatMap(\.sessions)
    }

    /// The context's tabs as the sidebar groups them: a split tab's panes together under it.
    func sidebarTabs(in context: SessionContext) -> [SidebarTabEntry] {
        let records = Dictionary(sessions(in: context).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sessionTabs(in: context).compactMap { tab in
            let sessions = panes(of: tab).compactMap { records[$0] }.filter { !runtimes.orchestration.isNestedWorker($0, in: context) }
            return sessions.isEmpty ? nil : SidebarTabEntry(tab: tab, sessions: sessions)
        }
    }
}

/// The row of a split tab in the sidebar: the split symbol and how many panes it shows, with their most urgent
/// status. Its panes are the indented rows below it.
private struct SidebarPaneTabRow: View {
    let layoutID: UUID
    let sessions: [AgentSessionRecord]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.split.2x1")
                .foregroundStyle(.secondary)
            Text("Split tab")
                .lineLimit(1)
            Spacer(minLength: SevindaSpacing.xs)
            ContextActivityBadge(sessions: sessions)
        }
        .padding(.leading, 34)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Split tab, \(sessions.count) panes"))
    }
}

/// One session under its worktree or folder in the sidebar.
private struct SidebarSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: AgentSessionRecord
    let context: SessionContext
    /// A pane of a split tab: indented under the tab's row.
    var isPane = false

    var body: some View {
        let activity = model.runtimes.activity(of: session)
        HStack(spacing: 6) {
            SessionStatusGlyph(activity: activity)
            AgentLogo(agent: session.agent, size: 13)
                .opacity(activity == .exited || activity == .failed ? 0.5 : 1)
            Text(verbatim: model.runtimes.displayTitle(of: session))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: SevindaSpacing.xs)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(verbatim: Self.elapsed(from: session.createdAt, to: session.endedAt ?? context.date))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        // Under the context's title: past its chevron and icon; a pane one step further, under its tab's row.
        .padding(.leading, isPane ? 52 : 34)
        .help(Text(verbatim: session.title))
        .contextMenu { SessionMenuItems(session: session) }
    }

    /// "45s", "9m", "3h", "2d": how long the session has run (or ran).
    static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}

/// The most urgent activity among the sessions of a row (waiting for input first) and how many there are.
struct ContextActivityBadge: View {
    @Environment(AppModel.self) private var model
    let sessions: [AgentSessionRecord]

    var body: some View {
        if !sessions.isEmpty {
            let activity = sessions.map { model.runtimes.activity(of: $0) }.max(by: { $0.urgency < $1.urgency }) ?? .exited
            HStack(spacing: 4) {
                Image(systemName: activity.systemImage)
                    .foregroundStyle(activity.color)
                    .symbolEffect(.pulse, isActive: activity == .waitingForInput)
                Text(verbatim: "\(sessions.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(sessions.count) sessions, \(activity.label)"))
        }
    }
}
