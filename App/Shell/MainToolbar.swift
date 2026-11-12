import MercuryCore
import SwiftUI

/// Window toolbar: the context's session tabs in the middle (Safari-style compact tabs), then new session, split
/// pane, new worktree (git workspaces) and the inspector toggle.
struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Binding var isInspectorShown: Bool

    var body: some ToolbarContent {
        if let context = model.selection, model.directory(of: context) != nil {
            if #available(macOS 26.0, *) {
                // The tab group draws its own capsule; the toolbar's shared glass would stretch across the whole
                // title bar behind a compact single tab.
                ToolbarItem(placement: .principal) {
                    ToolbarTabBar(context: context)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) {
                    ToolbarTabBar(context: context)
                }
            }
            // Two controls, apart: which agent new sessions use (a menu that can also start any agent), and the plus
            // that starts one with it.
            ToolbarItem(placement: .primaryAction) {
                NewSessionMenu(context: context)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                NewSessionButton(context: context)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                SplitPaneButton(context: context)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
        }
        if let context = model.selection, selectedGitWorkspace != nil {
            ToolbarItem(placement: .primaryAction) {
                SourceControlToolbarItems(context: context)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let workspace = selectedGitWorkspace {
                Button { model.newWorktreeWorkspaceID = workspace.id } label: {
                    Label("New Worktree", systemImage: "arrow.triangle.branch")
                }
                .help(Text("New worktree with an agent (⌘N)"))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { isInspectorShown.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(Text("Show or hide the inspector (⌥⌘I)"))
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    private var selectedGitWorkspace: Workspace? {
        guard let context = model.selection, let id = model.workspaceID(of: context), let workspace = model.workspace(id),
              workspace.kind == .git else { return nil }
        return workspace
    }
}
