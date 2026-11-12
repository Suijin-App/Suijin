import MercuryCore
import MercuryUI
import SwiftUI

/// The main window: workspaces in the sidebar, the selected context's tabs in the detail area, facts about it in the
/// inspector, and the status bar along the bottom.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("inspector.shown") private var isInspectorShown = true

    /// "End Claude?" for one working agent, "End 2 sessions?" for several.
    private var pendingCloseTitle: Text {
        guard let pending = model.pendingClose else { return Text(verbatim: "") }
        if pending.busy.count == 1, let record = pending.busy.first { return Text("End \(record.title)?") }
        return Text("End \(pending.busy.count) sessions?")
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            // The status bar is part of the detail column's layout, not an overlay, so the terminal above it is
            // sized to the space left and its last row is never hidden.
            VStack(spacing: 0) {
                detailContent
                StatusBarView()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.detailWidth = $0 }
            // The title bar holds the session tabs instead of a title, as Safari does; the window still has a title
            // for the Window menu and Mission Control.
            .navigationTitle(title)
            .toolbar(removing: .title)
            .toolbar { MainToolbar(isInspectorShown: $isInspectorShown) }
        }
        .frame(minWidth: 760, minHeight: 480)
        // Settings cover the whole window (toolbar included) instead of opening a window of their own. The toolbar
        // goes at once rather than fading with the overlay, and the covered app leaves the accessibility tree.
        // The welcome tour covers the window the same way, and only one of the two shows at a time.
        .toolbarVisibility(model.settingsPage == nil && model.onboarding == nil ? .automatic : .hidden, for: .windowToolbar)
        .animation(nil, value: model.settingsPage == nil && model.onboarding == nil)
        .accessibilityHidden(model.settingsPage != nil || model.onboarding != nil)
        .overlay {
            if let page = model.settingsPage {
                SettingsOverlay(page: page)
                    .transition(.opacity)
            }
        }
        .overlay {
            if let tour = model.onboarding {
                OnboardingOverlay(tour: tour)
                    .transition(.opacity)
            }
        }
        .background(WindowReader { model.mainWindow = $0 })
        .onAppear { SidebarClickFocus.install(model: model) }
        .confirmationDialog(
            pendingCloseTitle,
            isPresented: Binding(get: { model.pendingClose != nil }, set: { if !$0 { model.pendingClose = nil } }),
            presenting: model.pendingClose
        ) { pending in
            Button(pending.busy.count == 1 ? "End Session" : "End Sessions", role: .destructive) {
                Task { await model.closeSessions(pending.sessions) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            if pending.busy.count == 1 {
                Text("The agent is still working. Closing the tab stops it.")
            } else {
                Text("\(pending.busy.count) agents are still working. Closing the tab stops them.")
            }
        }
        .sheet(item: Binding(
            get: { model.newWorktreeWorkspaceID.flatMap(model.workspace) },
            set: { model.newWorktreeWorkspaceID = $0?.id }
        )) { workspace in
            NewWorktreeSheet(workspace: workspace)
        }
        .alert(item: $model.presentedError) { error in
            Alert(title: Text(verbatim: error.title), message: Text(verbatim: error.message))
        }
        // Worktrees made or removed outside Mercury (an agent running `git worktree add`) show up when the user
        // comes back to the app or selects the repository.
        .onChange(of: model.selection) { _, context in
            guard let context, let id = model.workspaceID(of: context), let workspace = model.workspace(id) else { return }
            Task {
                await model.refreshKind(of: workspace)
                await model.refreshWorktrees(workspaceID: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { for workspace in model.workspaces where workspace.kind == .git { await model.refreshWorktrees(workspaceID: workspace.id) } }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let context = model.selection, model.directory(of: context) != nil {
            SessionTabsView(context: context)
                .id(context)
                .inspector(isPresented: $isInspectorShown) {
                    InspectorView(context: context)
                }
        } else {
            ContentUnavailableView {
                Label("No Workspace Selected", systemImage: "square.stack.3d.up")
            } description: {
                Text("Add a git repository or a folder, then start an agent in it.")
            } actions: {
                Button("Add Workspace…") { AddWorkspaceFlow.run(model: model) }
                    .glassProminentButtonStyle()
            }
        }
    }

    private var title: String {
        guard let context = model.selection else { return "Mercury" }
        switch context {
        case .workspace(let id): return model.workspace(id)?.name ?? "Mercury"
        case .worktree(let id): return model.worktree(id)?.branch ?? "Mercury"
        }
    }

}

/// Hands the hosting window to `onWindow` once the view is in one.
private struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.window != nil { onWindow(view.window) }
    }
}
