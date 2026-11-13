import SuijinCore
import SuijinGit
import SuijinUI
import SwiftUI

/// Creates a worktree on a new branch and optionally starts an agent in it with a first prompt.
struct NewWorktreeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace

    @State private var branch = ""
    @State private var base = ""
    @State private var branches: [String] = []
    @State private var agent: AgentKind = .claude
    @State private var accountID: UUID?
    @State private var prompt = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var isBranchNameValid = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Branch", text: $branch, prompt: Text("feature/my-change"))
                        .onSubmit(create)
                    if !isBranchNameValid {
                        Text("Not a valid branch name.").font(.caption).foregroundStyle(SuijinColor.errorText)
                    } else if branches.contains(trimmedBranch) {
                        Text("A branch with this name already exists.").font(.caption).foregroundStyle(SuijinColor.errorText)
                    }
                    Picker("Base", selection: $base) {
                        ForEach(branches, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .disabled(branches.isEmpty)
                    LabeledContent("Folder") {
                        Text(verbatim: (destination.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Agent") {
                    AgentLaunchFields(agent: $agent, accountID: $accountID, prompt: $prompt, allowsShell: true)
                }
                if let error {
                    Section {
                        Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                            .foregroundStyle(SuijinColor.errorText)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: create) {
                    if isWorking { ProgressView().controlSize(.small) } else { Text("Create") }
                }
                .glassProminentButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isWorking)
            }
            .padding(SuijinSpacing.l)
        }
        .frame(width: 520)
        .navigationTitle(Text("New Worktree in \(workspace.name)"))
        .task { await loadBranches() }
        // git's own rules (`check-ref-format --branch`), checked as the user types so no folder is made for a name
        // git would refuse.
        .task(id: trimmedBranch) {
            let name = trimmedBranch
            guard !name.isEmpty else { isBranchNameValid = true; return }
            let service = WorktreeService(repository: URL(fileURLWithPath: workspace.path, isDirectory: true))
            let valid = await service.validateBranchName(name)
            if name == trimmedBranch { isBranchNameValid = valid }
        }
    }

    private var trimmedBranch: String { branch.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isValid: Bool {
        !trimmedBranch.isEmpty && !base.isEmpty && isBranchNameValid && !branches.contains(trimmedBranch)
    }

    private var destination: URL {
        let repository = URL(fileURLWithPath: workspace.path, isDirectory: true)
        let name = trimmedBranch.isEmpty ? "branch" : trimmedBranch
        if let root = model.setting(.worktreeRoot), !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(workspace.name, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
        }
        return WorktreeService.defaultPath(repository: repository, branch: name)
    }

    private func loadBranches() async {
        let service = WorktreeService(repository: URL(fileURLWithPath: workspace.path, isDirectory: true))
        branches = (try? await service.localBranches()) ?? []
        let preferred = (try? await service.defaultBaseBranch()) ?? branches.first ?? ""
        if !branches.contains(preferred), !preferred.isEmpty { branches.insert(preferred, at: 0) }
        base = preferred
        if let raw = model.setting(.defaultAgent), let kind = AgentKind(rawValue: raw) { agent = kind }
    }

    private func create() {
        guard isValid, !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                let worktree = try await model.createWorktree(workspaceID: workspace.id, branch: trimmedBranch, base: base, path: destination)
                await model.runtimes.start(in: .worktree(worktree.id), agent: agent, accountID: accountID,
                                           prompt: agent == .shell ? nil : prompt)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Agent, account and first prompt, shared by the new-worktree and new-session sheets.
struct AgentLaunchFields: View {
    @Environment(AppModel.self) private var model
    @Binding var agent: AgentKind
    @Binding var accountID: UUID?
    @Binding var prompt: String
    let allowsShell: Bool

    var body: some View {
        Picker("Run", selection: $agent) {
            Text("Claude Code").tag(AgentKind.claude)
            Text("Codex").tag(AgentKind.codex)
            if allowsShell { Text("Shell only").tag(AgentKind.shell) }
        }
        if let provider = agent.accountProvider {
            Picker("Account", selection: $accountID) {
                Text("Default (\(defaultAccountName(provider)))").tag(UUID?.none)
                ForEach(model.accounts.filter { $0.provider == provider }) { account in
                    Text(verbatim: account.displayName).tag(Optional(account.id))
                }
            }
            .onChange(of: agent) { accountID = nil }
            TextField("First prompt", text: $prompt, prompt: Text("Optional"), axis: .vertical)
                .lineLimit(3...6)
        }
    }

    private func defaultAccountName(_ provider: AccountProvider) -> String {
        model.defaultAccount(for: provider)?.displayName ?? String(localized: "your own login")
    }
}

extension AgentKind {
    var accountProvider: AccountProvider? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .shell: nil
        }
    }
}

extension ManagedAccountRecord {
    var displayName: String { email ?? label }
}
