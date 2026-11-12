import MercuryCore
import MercuryUI
import SwiftUI

/// Facts about the selected context in the inspector: path, branch, base, sessions.
struct WorktreeInspector: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext

    var body: some View {
        Form {
            switch context {
            case .workspace(let id):
                if let workspace = model.workspace(id) {
                    Section("Workspace") {
                        LabeledContent("Name") { Text(verbatim: workspace.name) }
                        LabeledContent("Kind") { workspace.kind == .git ? Text("Git repository") : Text("Folder") }
                        LabeledContent("Path") { pathText(workspace.path) }
                    }
                    if workspace.kind == .folder {
                        Section {
                            Label("Agents in a folder share the same files. Run them on separate tasks, or use a git repository for isolated worktrees.",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(MercuryColor.warningText)
                                .font(.callout)
                        }
                    }
                }
            case .worktree(let id):
                if let worktree = model.worktree(id) {
                    Section("Worktree") {
                        LabeledContent("Branch") { Text(verbatim: worktree.branch) }
                        if let base = worktree.baseBranch { LabeledContent("Base") { Text(verbatim: base) } }
                        LabeledContent("Path") { pathText(worktree.path) }
                        LabeledContent("Created") { Text(worktree.createdAt, style: .date) }
                    }
                }
            }
            if let id = model.workspaceID(of: context), model.workspace(id)?.kind == .git {
                SourceControlSection(context: context)
            }
            OrchestrationInspectorSection(context: context)
            Section("Sessions") {
                let sessions = model.sessions(in: context)
                if sessions.isEmpty {
                    Text("No sessions").foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    let activity = model.runtimes.activity(of: session)
                    LabeledContent {
                        Label { activity.label } icon: { Image(systemName: activity.systemImage).foregroundStyle(activity.color) }
                    } label: {
                        Text(verbatim: session.title)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
    }

    private func pathText(_ path: String) -> some View {
        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}
