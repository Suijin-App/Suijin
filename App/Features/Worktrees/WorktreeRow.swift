import SuijinCore
import SuijinGit
import SwiftUI

/// A worktree in the sidebar: its branch, the most urgent session activity, and the context menu of every session row
/// plus Show in Finder and removal.
struct WorktreeRow: View {
    @Environment(AppModel.self) private var model
    let worktree: WorktreeRecord
    @State private var pendingRemoval: RemovalRequest?

    var body: some View {
        WorkspaceContextRow(context: .worktree(worktree.id), title: Text(verbatim: worktree.branch),
                            systemImage: "arrow.triangle.branch", accessory: AnyView(PullRequestBadge(worktreeID: worktree.id)),
                            extraMenuItems: AnyView(Group {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)]) }
                                Button("Remove Worktree…", role: .destructive) { Task { await requestRemoval() } }
                            }))
            .help(Text(verbatim: worktree.path))
            .confirmationDialog(
                Text("Remove the worktree “\(worktree.branch)”?"),
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                presenting: pendingRemoval
            ) { request in
                Button(request.isDirty ? "Remove and Discard Changes" : "Remove", role: .destructive) {
                    Task { await model.removeWorktree(worktree.id, force: request.isDirty) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                if request.isDirty {
                    Text("This worktree has uncommitted changes. They will be lost. Running sessions in it are stopped first.")
                } else {
                    Text("The folder is deleted and running sessions in it are stopped. The branch is kept.")
                }
            }
    }

    private func requestRemoval() async {
        guard let workspace = model.workspace(worktree.workspaceID) else { return }
        let service = WorktreeService(repository: URL(fileURLWithPath: workspace.path, isDirectory: true))
        let dirty = (try? await service.hasUncommittedChanges(at: URL(fileURLWithPath: worktree.path))) ?? true
        pendingRemoval = RemovalRequest(isDirty: dirty)
    }

    private struct RemovalRequest {
        let isDirty: Bool
    }
}
