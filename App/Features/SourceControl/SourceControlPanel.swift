import SevindaGit
import SevindaUI
import SwiftUI

/// The inspector's source control sections: branch and push, the branch's pull request and checks, the commit message,
/// and staged and unstaged files with checkboxes.
struct SourceControlPanel: View {
    @Bindable var state: SourceControlState

    var body: some View {
        Section {
            if let status = state.status {
                // A worktree's branch is already in the inspector's Worktree section; a detached HEAD is worth repeating.
                if state.showsBranchRow {
                    LabeledContent("Branch") {
                        if let branch = status.branch { Text(verbatim: branch).lineLimit(1).truncationMode(.middle) } else {
                            Text("Detached HEAD").foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Upstream") {
                    if let upstream = status.upstream {
                        Text(verbatim: upstream).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("Not published").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    AheadBehindLabel(status: status)
                    Spacer()
                    PushButton(state: state, surface: .inspector)
                }
            } else if let error = state.statusError {
                Label { Text(verbatim: error).textSelection(.enabled) } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(SevindaColor.warningText)
                }
                .font(.callout)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            if let success = state.lastSuccess {
                Label { Text(verbatim: success).lineLimit(2) } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(SevindaColor.ok)
                }
                .font(.callout)
            }
        } header: {
            HStack {
                Text("Source Control")
                Spacer()
                Button { Task { await state.refreshStatus() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(Text("Refresh the file status"))
            }
        }
        PullRequestStatusSection(state: state)
        if let status = state.status {
            Section("Commit") {
                CommitComposer(state: state, surface: .inspector)
            }
            SourceControlFileSections(state: state, status: status, surface: .inspector)
        }
    }
}

/// The Staged and Changes sections; a checked box means the file's change is staged. A file with both staged and
/// unstaged changes appears in both, as in `git status`.
struct SourceControlFileSections: View {
    let state: SourceControlState
    let status: RepositoryStatus
    let surface: SourceControlSurface
    /// Rows shown per section; the rest are summarized so a huge change set stays responsive.
    static let rowLimit = 300

    var body: some View {
        let staged = status.staged
        let unstaged = status.unstaged
        if staged.isEmpty && unstaged.isEmpty {
            Section {
                Label("No changes", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
        } else {
            if !staged.isEmpty {
                Section {
                    rows(staged, staged: true)
                } header: {
                    header(Text("Staged (\(staged.count))"), action: Text("Unstage All")) {
                        Task { await state.setStaged(staged, staged: false, from: surface) }
                    }
                }
            }
            if !unstaged.isEmpty {
                Section {
                    rows(unstaged, staged: false)
                } header: {
                    header(Text("Changes (\(unstaged.count))"), action: Text("Stage All")) {
                        Task { await state.setStaged(unstaged, staged: true, from: surface) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ entries: [StatusEntry], staged: Bool) -> some View {
        ForEach(entries.prefix(Self.rowLimit)) { entry in
            FileStatusRow(entry: entry, staged: staged, isPending: state.pendingPaths.contains(entry.path)) { newValue in
                Task { await state.setStaged([entry], staged: newValue, from: surface) }
            }
        }
        if entries.count > Self.rowLimit {
            Text("\(entries.count - Self.rowLimit) more files").foregroundStyle(.secondary).font(.callout)
        }
    }

    private func header(_ title: Text, action: Text, perform: @escaping () -> Void) -> some View {
        HStack {
            title
            Spacer()
            Button(action: perform) { action }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}

/// One changed file with its staging checkbox, name, folder and status letter.
private struct FileStatusRow: View {
    let entry: StatusEntry
    let staged: Bool
    let isPending: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        let code = FileStatusCode(entry: entry, staged: staged)
        HStack(alignment: .firstTextBaseline, spacing: SevindaSpacing.xs) {
            Toggle(isOn: Binding(get: { staged }, set: { onToggle($0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isPending)
                .accessibilityLabel(staged ? Text("Unstage \(entry.path)") : Text("Stage \(entry.path)"))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: (entry.path as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let folder = (entry.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(verbatim: folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: SevindaSpacing.xs)
            ChangeStatusBadge(letter: code.letter, color: code.color)
                .help(code.description)
                .accessibilityLabel(code.description)
        }
        .help(Text(verbatim: entry.originalPath.map { "\($0) → \(entry.path)" } ?? entry.path))
    }
}

/// The letter, color and name of a file's change on one side (index for staged rows, working tree otherwise).
struct FileStatusCode {
    let letter: String
    let color: Color
    let description: Text

    init(entry: StatusEntry, staged: Bool) {
        if entry.isConflicted {
            (letter, color, description) = ("!", SevindaColor.error, Text("Conflict"))
            return
        }
        if entry.isUntracked {
            (letter, color, description) = ("U", SevindaColor.ok, Text("Untracked"))
            return
        }
        switch staged ? entry.index : entry.worktree {
        case .added: (letter, color, description) = ("A", SevindaColor.ok, Text("Added"))
        case .deleted: (letter, color, description) = ("D", SevindaColor.error, Text("Deleted"))
        case .renamed: (letter, color, description) = ("R", Color.accentColor, Text("Renamed"))
        case .copied: (letter, color, description) = ("C", Color.accentColor, Text("Copied"))
        case .typeChanged: (letter, color, description) = ("T", SevindaColor.warning, Text("Type changed"))
        default: (letter, color, description) = ("M", SevindaColor.warning, Text("Modified"))
        }
    }
}

/// Commits ahead of and behind the upstream, or a note that the branch is not published.
struct AheadBehindLabel: View {
    let status: RepositoryStatus

    var body: some View {
        if status.upstream == nil {
            EmptyView() // The Upstream row already says "Not published".
        } else if status.ahead == 0 && status.behind == 0 {
            Label("Up to date", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
        } else {
            HStack(spacing: SevindaSpacing.s) {
                if status.ahead > 0 {
                    Label { Text("\(status.ahead) to push") } icon: { Image(systemName: "arrow.up") }
                }
                if status.behind > 0 {
                    Label { Text("\(status.behind) behind") } icon: { Image(systemName: "arrow.down") }
                        .foregroundStyle(SevindaColor.warningText)
                }
            }
            .font(.callout)
            .monospacedDigit()
        }
    }
}
