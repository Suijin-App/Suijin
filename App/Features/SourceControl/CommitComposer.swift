import SuijinCore
import SuijinUI
import SwiftUI

/// The commit message editor with Generate (an agent writes the message from the staged diff, read-only) and Commit.
/// The draft lives in `SourceControlState`, so a failed commit or a closed inspector never loses it.
struct CommitComposer: View {
    @Bindable var state: SourceControlState
    let surface: SourceControlSurface

    var body: some View {
        VStack(alignment: .leading, spacing: SuijinSpacing.s) {
            TextEditor(text: $state.draftMessage)
                .font(.body)
                .frame(minHeight: 64, maxHeight: 180)
                .scrollContentBackground(.hidden)
                .disabled(state.isGenerating)
                .overlay(alignment: .topLeading) {
                    if state.draftMessage.isEmpty {
                        Text(state.isGenerating ? "Writing the message…" : "Commit message")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(Text("Commit message"))

            if let error = state.generationError {
                HStack(alignment: .top, spacing: SuijinSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(SuijinColor.warningText)
                    ScrollView {
                        Text(verbatim: error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 80)
                    .fixedSize(horizontal: false, vertical: true)
                    Button { state.clearGenerationError() } label: { Label("Dismiss", systemImage: "xmark") }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .font(.callout)
            }

            HStack(spacing: SuijinSpacing.s) {
                if state.isGenerating {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { state.cancelGeneration() }
                } else {
                    GenerateMenu(defaultAgent: state.defaultGenerator) { state.generateCommitMessage(with: $0) }
                        .disabled(state.status?.staged.isEmpty ?? true)
                        .help(Text("An agent writes the message from the staged changes. It runs read-only and cannot change files."))
                }
                Spacer(minLength: 0)
                Button {
                    Task { await state.commit(from: surface) }
                } label: {
                    if state.isCommitting { ProgressView().controlSize(.small) } else { Text("Commit") }
                }
                .glassProminentButtonStyle()
                .keyboardShortcut(ShortcutCatalog.commit.shortcut)
                .disabled(!state.canCommit)
                .help(commitHelp)
            }
        }
    }

    private var commitHelp: Text {
        if !(state.status?.conflicted.isEmpty ?? true) { return Text("Resolve the conflicts first") }
        if state.status?.staged.isEmpty ?? true { return Text("Stage changes to commit them") }
        return Text("Commit the staged changes (⌘↩)")
    }
}

/// "Generate" with the default agent, and a menu to pick Claude Code or Codex for this run.
struct GenerateMenu: View {
    let defaultAgent: AgentKind
    let generate: (AgentKind) -> Void

    var body: some View {
        Menu {
            Button("Generate with Claude Code") { generate(.claude) }
            Button("Generate with Codex") { generate(.codex) }
        } label: {
            Label("Generate", systemImage: "sparkles")
        } primaryAction: {
            generate(defaultAgent)
        }
        .fixedSize()
    }
}
