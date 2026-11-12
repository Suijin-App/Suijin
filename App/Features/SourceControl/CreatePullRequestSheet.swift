import SevindaAgents
import SevindaGit
import SevindaUI
import SwiftUI

/// Creates a GitHub pull request for the context's branch with the user's `gh`: base branch, title and body (an
/// agent can write them read-only), draft or ready. The branch is pushed first when the remote does not have it yet.
/// When gh is missing, not signed in, the remote is not GitHub, or a pull request already exists, the sheet says so.
struct CreatePullRequestSheet: View {
    let state: SourceControlState
    @Environment(\.dismiss) private var dismiss
    @State private var base = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var isDraft = false
    @State private var branches: [String] = []
    @State private var error: String?
    @State private var created: URL?
    /// True while a generation this sheet started may still run; it is cancelled when the sheet closes.
    @State private var startedGeneration = false

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer.padding(MercurySpacing.l)
        }
        .frame(width: 560)
        .frame(minHeight: 300)
        .onDisappear { if startedGeneration { state.cancelGeneration() } }
        .task {
            state.clearGenerationError()
            if state.isPullRequestStale || state.pullRequest == .unknown { await state.refreshPullRequest() }
            if base.isEmpty { base = await state.defaultPullRequestBase() }
            branches = await state.localBranches().filter { $0 != state.status?.branch }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let created {
            ContentUnavailableView {
                Label("Pull Request Created", systemImage: "checkmark.circle")
            } description: {
                Text(verbatim: created.absoluteString).textSelection(.enabled)
            } actions: {
                Button("Open in Browser") { NSWorkspace.shared.open(created) }
                    .glassProminentButtonStyle()
            }
            .frame(minHeight: 260)
        } else {
            switch state.pullRequest {
            case .unknown, .checking:
                ProgressView("Checking GitHub…").frame(maxWidth: .infinity, minHeight: 260)
            case .ready(let existing?) where existing.state == .open:
                ContentUnavailableView {
                    Label("A Pull Request Already Exists", systemImage: "arrow.triangle.pull")
                } description: {
                    Text("“\(existing.title)” (#\(existing.number)) is already open for this branch. New commits you push appear in it.")
                } actions: {
                    Button("Open Pull Request") { NSWorkspace.shared.open(existing.url) }
                        .glassProminentButtonStyle()
                }
                .frame(minHeight: 260)
            case .ready:
                form
            default:
                Form { Section { PullRequestUnavailableNote(state: state) } }
                    .formStyle(.grouped)
                    .frame(minHeight: 220)
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent("From") {
                    Text(verbatim: state.status?.branch ?? "").lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    TextField("Into", text: $base, prompt: Text(verbatim: "main"))
                    Menu {
                        ForEach(branches, id: \.self) { branch in
                            Button { base = branch } label: { Text(verbatim: branch) }
                        }
                    } label: {
                        Label("Branches", systemImage: "arrow.triangle.branch")
                    }
                    .labelStyle(.iconOnly)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(branches.isEmpty)
                    .help(Text("Choose the base branch"))
                }
                Toggle("Create as draft", isOn: $isDraft)
            }
            Section {
                TextField("Title", text: $title, prompt: Text("Required"))
                TextEditor(text: $bodyText)
                    .font(.body)
                    .frame(minHeight: 150, maxHeight: 260)
                    .scrollContentBackground(.hidden)
                    .disabled(state.isGenerating)
                    .overlay(alignment: .topLeading) {
                        if bodyText.isEmpty {
                            Text(state.isGenerating ? "Writing the description…" : "Description (Markdown)")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel(Text("Description"))
            } header: {
                HStack {
                    Text("Title and Description")
                    Spacer()
                    if state.isGenerating {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { state.cancelGeneration() }.buttonStyle(.borderless)
                    } else {
                        GenerateMenu(defaultAgent: state.defaultGenerator) { agent in
                            startedGeneration = true
                            state.generatePullRequestText(base: base.trimmed, with: agent) { draft in
                                title = draft.title
                                bodyText = draft.body
                            }
                        }
                        .disabled(base.trimmed.isEmpty)
                        .help(Text("An agent writes the title and description from the branch's commits and diff. It runs read-only."))
                    }
                }
            }
            if let message = error ?? state.generationError {
                Section {
                    ScrollView {
                        Text(verbatim: message)
                            .font(.callout)
                            .foregroundStyle(MercuryColor.errorText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            if state.isCreatingPullRequest {
                ProgressView().controlSize(.small)
                Text("Pushing and creating the pull request…").foregroundStyle(.secondary).font(.callout)
            } else if let status = state.status, case .ready(nil) = state.pullRequest, status.upstream == nil || status.ahead > 0 {
                Text("The branch is pushed first.").foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            if created != nil || !isFormShown {
                // The content above holds the prominent action (open the pull request); Done stays plain.
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel") {
                    state.cancelGeneration()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Create Pull Request") { Task { await create() } }
                    .glassProminentButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmed.isEmpty || base.trimmed.isEmpty || state.isCreatingPullRequest || state.isGenerating)
            }
        }
    }

    private var isFormShown: Bool {
        if case .ready(let pr) = state.pullRequest { return pr == nil || pr?.state != .open }
        return false
    }

    private func create() async {
        error = nil
        do {
            created = try await state.createPullRequest(title: title.trimmed, body: bodyText, base: base.trimmed, draft: isDraft)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
