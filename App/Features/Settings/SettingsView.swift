import MercuryAgents
import MercuryCore
import MercuryTerminal
import MercuryUI
import SwiftUI

/// The pages of Settings, in sidebar order.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, agents, accounts, terminal, stats

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .accounts: "Accounts"
        case .terminal: "Terminal"
        case .stats: "Stats & Usage"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .agents: "sparkle"
        case .accounts: "person.2"
        case .terminal: "terminal"
        case .stats: "chart.bar"
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .general: GeneralSettings()
        case .agents: AgentSettings()
        case .accounts: AccountsSettingsView()
        case .terminal: TerminalSettings()
        case .stats: StatsUsageSettings()
        }
    }
}

/// A Boolean setting stored as "true"/"false" with a default.
@MainActor
private func toggleBinding(_ model: AppModel, _ key: SettingKey, default value: Bool) -> Binding<Bool> {
    Binding(get: { model.setting(key).map { $0 == "true" } ?? value },
            set: { model.setSetting(key, $0 ? "true" : "false") })
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                AppearancePicker()
            } header: {
                Text("Appearance")
            } footer: {
                Text("Automatic follows the appearance set in System Settings. Terminals with the Automatic theme switch along.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Notify when an agent waits for input or finishes", isOn: toggleBinding(model, .notifyWhenWaiting, default: true))
            } header: {
                Text("Notifications")
            } footer: {
                Text("Banners appear while you look at another tab or app; clicking one opens that session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep sessions running after quitting Mercury", isOn: toggleBinding(model, .keepSessionsOnQuit, default: true))
                if let problem = model.runtimes.hostProblem {
                    Label {
                        Text("Sessions end with the app: the terminal host is unavailable (\(problem)). Allow Mercury in System Settings → General → Login Items.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(MercuryColor.warningText)
                    .font(.callout)
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text("Sessions run in a background helper, so closing or updating Mercury does not stop your agents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
    }
}

struct AgentSettings: View {
    @Environment(AppModel.self) private var model
    @State private var path: String?

    var body: some View {
        Form {
            Section {
                Picker("Default agent", selection: Binding(
                    get: { model.setting(.defaultAgent).flatMap(AgentKind.init(rawValue:)) ?? .claude },
                    set: { model.setSetting(.defaultAgent, $0.rawValue) }
                )) {
                    Text("Claude Code").tag(AgentKind.claude)
                    Text("Codex").tag(AgentKind.codex)
                    Text("Shell").tag(AgentKind.shell)
                }
                Picker("New pane runs", selection: Binding(
                    get: { model.newPaneAgent },
                    set: { model.setNewPaneAgent($0) }
                )) {
                    Text("Same as focused pane").tag(NewPaneAgent.sameAsFocused)
                    Divider()
                    Text("Shell").tag(NewPaneAgent.shell)
                    Text("Claude Code").tag(NewPaneAgent.claude)
                    Text("Codex").tag(NewPaneAgent.codex)
                }
                LabeledContent("Folder for new worktrees") {
                    HStack(spacing: MercurySpacing.s) {
                        Text(verbatim: model.setting(.worktreeRoot).map { ($0 as NSString).abbreviatingWithTildeInPath }
                             ?? String(localized: "Next to each repository"))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseRoot)
                        if model.setting(.worktreeRoot) != nil {
                            Button("Reset") { model.setSetting(.worktreeRoot, nil) }
                        }
                    }
                }
            } header: {
                Text("New Sessions")
            } footer: {
                Text("New tabs start the default agent. New panes (⌘D, ⇧⌘D, the split button) run the chosen agent; the split button's menu can pick another each time. New worktrees are created in the chosen folder, or next to their repository.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(AgentCatalog.all, id: \.kind) { agent in
                    InstalledAgentRow(agent: agent, path: path)
                }
            } header: {
                Text("Installed")
            } footer: {
                Text("Mercury finds agents on the PATH of your login shell.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Run without the shared background server (--no-daemon)", isOn: toggleBinding(model, .codexNoDaemon, default: false))
            } header: {
                Text("Codex")
            } footer: {
                Text("Each Codex session runs on its own. Turn this on if Codex reports that its daemon executable is missing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            OrchestrationSettingsSection()
            DiffNotesSettingsSection()
        }
        .formStyle(.grouped)
        .task { path = await AgentCatalog.loginShellPATH() }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { model.setSetting(.worktreeRoot, url.path) }
    }
}

/// An agent's logo and name, then where its binary is (green check) or that it is missing (warning).
private struct InstalledAgentRow: View {
    let agent: AgentDefinition
    /// The login shell's PATH; `nil` while it loads.
    let path: String?

    var body: some View {
        LabeledContent {
            if let path {
                if let binary = AgentCatalog.resolveBinary(agent.kind, path: path) {
                    HStack(spacing: MercurySpacing.xs) {
                        Text(verbatim: (binary.path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MercuryColor.ok)
                            .accessibilityLabel(Text("Installed"))
                    }
                    .help(Text(verbatim: binary.path))
                } else {
                    Label("Not found on PATH", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(MercuryColor.warningText)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            HStack(spacing: MercurySpacing.s) {
                AgentLogo(agent: agent.kind, size: 20)
                Text(verbatim: agent.displayName)
            }
        }
    }
}
