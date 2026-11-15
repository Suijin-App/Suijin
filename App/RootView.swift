import SuijinCore
import SuijinUI
import SwiftUI

/// The main window: workspaces in the sidebar, the selected context's tabs in the detail area, facts about it in the
/// inspector, and the status bar along the bottom.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("inspector.shown") private var isInspectorShown = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            // The status bar is part of the detail column's layout, not an overlay, so the terminal above it is
            // sized to the space left and its last row is never hidden.
            VStack(spacing: 0) {
                // Every state fills the column, so the status bar stays on the bottom edge: an empty state only
                // asks for its own ideal height, and the column would center the stack.
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBarView()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.detailWidth = $0 }
            // The title bar holds the session tabs instead of a title, as Safari does; the window still has a title
            // for the Window menu and Mission Control.
            .navigationTitle(title)
            .toolbar(removing: .title)
            .toolbar { MainToolbar(isInspectorShown: $isInspectorShown) }
        }
        // The smallest window that still fits the sidebar, a readable terminal and the toolbar's buttons without
        // squeezing them: below this the toolbar overflowed and panes, the diff and the overlays lost their layout.
        .frame(minWidth: 1000, minHeight: 640)
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
        // Each dialog with a "Don't ask again" box sits on a view of its own, so the boxes stay separate.
        .background { Color.clear.modifier(CloseConfirmationDialog()) }
        .background { Color.clear.modifier(UnsavedFileCloseDialog()) }
        .sheet(item: Binding(
            get: { model.newWorktreeWorkspaceID.flatMap(model.workspace) },
            set: { model.newWorktreeWorkspaceID = $0?.id }
        )) { workspace in
            NewWorktreeSheet(workspace: workspace)
        }
        .background { Color.clear.modifier(PermissionConfirmationAlert()) }
        .alert(item: $model.presentedError) { error in
            Alert(title: Text(verbatim: error.title), message: Text(verbatim: error.message))
        }
        // Worktrees made or removed outside Suijin (an agent running `git worktree add`) show up when the user
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
            // A login changed in another app shows on the sessions that use it.
            Task { await model.accountsController.refreshIdentities() }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.detailState {
        case .loading:
            // A blank column for the moment the stored state takes to load, instead of an empty state that would only
            // flash by before the restored context replaces it.
            Color.clear
                .accessibilityHidden(true)
        case .context(let context):
            SessionTabsView(context: context)
                .id(context)
                .inspector(isPresented: $isInspectorShown) {
                    InspectorView(context: context)
                }
        case .firstWorkspace:
            FirstWorkspaceView()
        case .noSelection:
            ContentUnavailableView {
                Label("No Workspace Selected", systemImage: "square.stack.3d.up")
            } description: {
                Text("Choose a workspace or worktree in the sidebar.")
            }
        }
    }

    private var title: String {
        guard let context = model.selection else { return "Suijin" }
        switch context {
        case .workspace(let id): return model.workspace(id)?.name ?? "Suijin"
        case .worktree(let id): return model.worktree(id)?.branch ?? "Suijin"
        }
    }

}

/// What the main window's detail column shows.
enum DetailState: Hashable {
    /// The stored state is still loading at launch.
    case loading
    case context(SessionContext)
    /// No workspace exists yet.
    case firstWorkspace
    case noSelection
}

extension AppModel {
    var detailState: DetailState {
        guard isLoaded else { return .loading }
        if let context = selection, directory(of: context) != nil { return .context(context) }
        return workspaces.isEmpty ? .firstWorkspace : .noSelection
    }
}

/// The detail area before any workspace exists: the app icon, what a workspace is, and the two ways to start.
private struct FirstWorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: SuijinSpacing.l) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Add your first workspace")
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
            }
        } description: {
            Text("Add a git repository to give each agent its own worktree, or a plain folder to run agents straight in it.")
                .frame(maxWidth: 440)
        } actions: {
            VStack(spacing: SuijinSpacing.m) {
                GlassGroup {
                    HStack(spacing: SuijinSpacing.m) {
                        Button { AddWorkspaceFlow.run(model: model) } label: {
                            Label("Add Workspace…", systemImage: "plus")
                        }
                        .glassProminentButtonStyle()
                        .help(Text("Add a git repository or a folder (⇧⌘O)"))
                        Button { model.showOnboarding() } label: {
                            Label("Show Welcome Tour", systemImage: "sparkles")
                        }
                        .glassButtonStyle()
                    }
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }
                Text("or press ⇧⌘O")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(Text("Keyboard shortcut: Shift Command O"))
            }
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
