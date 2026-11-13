import SuijinGit
import SuijinUI
import SwiftUI

/// Which part of a checkout's changes a file entry belongs to.
enum ChangeGroup: Hashable {
    /// In the working tree, not committed yet (untracked files included).
    case uncommitted
    /// In commits on this branch that the base branch does not have.
    case committed
}

/// A file entry of the list; the same path can appear in both groups.
struct ChangeSelection: Hashable {
    let group: ChangeGroup
    let path: String
}

/// One group of the list with its heading.
struct ChangeSection: Identifiable {
    let group: ChangeGroup
    let title: Text
    let detail: Text
    let files: [ChangedFile]
    /// The commits behind the committed group, newest first.
    var commits: [CommitSummary] = []
    var id: ChangeGroup { group }
}

/// The changed files, split into what is not committed yet and what is committed but not on the base branch, each
/// under a heading that says so. A status letter colored by kind leads each file.
struct ChangedFilesList: View {
    let sections: [ChangeSection]
    @Binding var selection: ChangeSelection?
    let isLoading: Bool
    let error: String?
    /// Shown when both groups are empty.
    let emptyDescription: Text
    /// Notes per path, shown as a count next to the file.
    var noteCounts: [String: Int] = [:]
    /// The list only holds files with unsent notes.
    var isFilteredToUnsent = false
    /// The commit the committed group is narrowed to; nil shows every commit's changes.
    @Binding var selectedCommit: String?
    @State private var showsAllCommits = false

    /// Commits listed before "Show more".
    static let collapsedCommitCount = 5

    var body: some View {
        List(selection: $selection) {
            ForEach(sections.filter { !$0.files.isEmpty || !$0.commits.isEmpty }) { section in
                Section {
                    if !section.commits.isEmpty {
                        commitRows(section.commits)
                        filesCaption(section.commits)
                    }
                    ForEach(section.files, id: \.path) { file in
                        row(file).tag(ChangeSelection(group: section.group, path: file.path))
                    }
                } header: {
                    // One line: section headers of a list keep a single line's height.
                    HStack(spacing: SuijinSpacing.s) {
                        section.title.font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Spacer(minLength: SuijinSpacing.xs)
                        section.detail.font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .textCase(nil)
                }
            }
        }
        .overlay {
            if let error {
                ContentUnavailableView("Cannot Read Changes", systemImage: "exclamationmark.triangle", description: Text(verbatim: error))
            } else if isLoading {
                ProgressView()
            } else if sections.allSatisfy(\.files.isEmpty), isFilteredToUnsent {
                ContentUnavailableView("No Unsent Notes", systemImage: "text.bubble", description: Text("Every note was sent. Turn off “Show Only Unsent Notes” to see all files."))
            } else if sections.allSatisfy(\.files.isEmpty) {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: emptyDescription)
            }
        }
    }

    /// "All commits" and one row per commit (subject, short hash, age; author in the tooltip). Choosing a commit narrows the files
    /// below and their diffs to that commit. Buttons, not list selection: the selection is the file.
    @ViewBuilder
    private func commitRows(_ commits: [CommitSummary]) -> some View {
        commitButton(isChosen: selectedCommit == nil, action: { selectedCommit = nil }) {
            Image(systemName: "square.stack.3d.up").frame(width: 14).foregroundStyle(.secondary)
            Text(commits.count == 1 ? "The commit" : "All \(commits.count) commits").lineLimit(1)
            Spacer(minLength: 0)
        }
        let shown = showsAllCommits ? commits : Array(commits.prefix(Self.collapsedCommitCount))
        ForEach(shown) { commit in
            commitButton(isChosen: selectedCommit == commit.sha, action: { selectedCommit = commit.sha }) {
                Image(systemName: "smallcircle.filled.circle").font(.caption).frame(width: 14).foregroundStyle(.secondary)
                Text(verbatim: commit.subject).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: SuijinSpacing.xs)
                Text(verbatim: commit.shortSHA).font(SuijinFont.monoSmall).foregroundStyle(.secondary)
                Text(commit.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .help(Text(verbatim: "\(commit.shortSHA) · \(commit.author)\n\(commit.subject)"))
        }
        if commits.count > Self.collapsedCommitCount {
            Button(showsAllCommits ? "Show Fewer" : "Show \(commits.count - Self.collapsedCommitCount) More") {
                withAnimation(.snappy(duration: 0.2)) { showsAllCommits.toggle() }
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.leading, 28)
            .listRowSeparator(.hidden)
        }
    }

    /// Says whose files follow: all commits', or the chosen commit's.
    private func filesCaption(_ commits: [CommitSummary]) -> some View {
        let chosen = commits.first { $0.sha == selectedCommit }
        return Group {
            if let chosen {
                Text("Files in \(chosen.shortSHA)")
            } else {
                Text("Files in all commits")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.top, SuijinSpacing.s)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }

    private func commitButton<Label: View>(isChosen: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: SuijinSpacing.s) { label() }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(isChosen ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func row(_ file: ChangedFile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SuijinSpacing.s) {
            ChangeStatusBadge(letter: file.kind.letter, color: file.kind.color)
                .accessibilityLabel(file.kind.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: (file.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                let folder = (file.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(verbatim: folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if let count = noteCounts[file.path], count > 0 {
                Label("\(count)", systemImage: "text.bubble")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel(Text("\(count) notes"))
            }
        }
        .help(Text(verbatim: file.path))
    }
}

extension FileChangeKind {
    var letter: String {
        switch self {
        case .added: "A"
        case .deleted: "D"
        case .modified: "M"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .unmerged: "U"
        }
    }

    var label: Text {
        switch self {
        case .added: Text("Added")
        case .deleted: Text("Deleted")
        case .modified: Text("Modified")
        case .renamed(let from): Text("Renamed from \(from)")
        case .copied(let from): Text("Copied from \(from)")
        case .typeChanged: Text("Type changed")
        case .unmerged: Text("Unmerged")
        }
    }

    /// The badge fill; the same colors as the Source Control panel's letters.
    var color: Color {
        switch self {
        case .added: SuijinColor.ok
        case .deleted, .unmerged: SuijinColor.error
        case .renamed, .copied: Color.accentColor
        default: SuijinColor.warning
        }
    }
}
