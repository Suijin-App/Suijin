import MercuryGit
import MercuryUI
import SwiftUI

/// Pushes the branch, or publishes it (`--set-upstream`) when it has no upstream yet.
struct PushButton: View {
    let state: SourceControlState
    let surface: SourceControlSurface

    var body: some View {
        let status = state.status
        Button {
            Task { await state.push(from: surface) }
        } label: {
            if state.isPushing {
                ProgressView().controlSize(.small)
            } else if status?.upstream == nil {
                Label("Publish", systemImage: "icloud.and.arrow.up")
            } else {
                Label("Push", systemImage: "arrow.up")
            }
        }
        .disabled(!Self.canPush(status) || state.isPushing)
        .help(Self.help(status))
    }

    static func canPush(_ status: RepositoryStatus?) -> Bool {
        guard let status, status.branch != nil, status.hasCommits else { return false }
        return status.upstream == nil || status.ahead > 0
    }

    static func help(_ status: RepositoryStatus?) -> Text {
        guard let status else { return Text("Reading the branch status…") }
        guard status.branch != nil else { return Text("Check out a branch to push") }
        guard status.hasCommits else { return Text("Commit something first") }
        if status.upstream == nil { return Text("Push the branch and set its upstream") }
        if status.behind > 0 {
            return Text("The remote has \(status.behind) commits this branch lacks; git will reject the push until you pull them.")
        }
        return status.ahead > 0 ? Text("Push \(status.ahead) commits") : Text("Nothing to push")
    }
}

/// The toolbar's push button: an arrow with the number of commits to push (and to pull, if any).
struct ToolbarPushButton: View {
    let state: SourceControlState

    var body: some View {
        let status = state.status
        Button {
            Task { await state.push(from: .toolbar) }
        } label: {
            HStack(spacing: 3) {
                if state.isPushing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: status?.upstream == nil ? "icloud.and.arrow.up" : "arrow.up")
                }
                if let status, status.ahead > 0 { Text(verbatim: "\(status.ahead)").monospacedDigit() }
                if let status, status.behind > 0 {
                    Image(systemName: "arrow.down").foregroundStyle(MercuryColor.warningText)
                    Text(verbatim: "\(status.behind)").monospacedDigit().foregroundStyle(MercuryColor.warningText)
                }
            }
            .font(.callout)
        }
        .disabled(!PushButton.canPush(status) || state.isPushing)
        .help(PushButton.help(status))
        .accessibilityLabel(status?.upstream == nil ? Text("Publish Branch") : Text("Push"))
        .accessibilityValue(Text("\(status?.ahead ?? 0) to push, \(status?.behind ?? 0) behind"))
    }
}

/// Git's full output after a failed commit, push or staging, in a scrollable sheet. Closing it leaves the draft
/// message as it was.
struct GitOutputSheet: View {
    let report: GitOutputReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: MercurySpacing.m) {
            Label { Text(verbatim: report.title).font(.headline) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MercuryColor.warning)
            }
            Text("Git reported:").foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: report.output)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(MercurySpacing.s)
            }
            .frame(minHeight: 140, maxHeight: 360)
            .background(MercuryColor.codeBackground, in: RoundedRectangle(cornerRadius: MercuryRadius.control))
            HStack {
                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.output, forType: .string)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(MercurySpacing.l)
        .frame(width: 560)
    }
}
