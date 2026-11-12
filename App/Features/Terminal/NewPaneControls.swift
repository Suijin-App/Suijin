import AppKit
import MercuryCore
import SwiftUI

/// What a new pane runs when no agent is picked for it: Settings → Agents → New pane runs. ⌘D, ⇧⌘D, the title-bar
/// split button and the context menus use it; the split button's menu can pick another agent each time.
enum NewPaneAgent: String, CaseIterable, Identifiable {
    /// The agent of the pane it is added beside, with the same account.
    case sameAsFocused = "same"
    case shell, claude, codex

    var id: Self { self }

    /// The stored setting; unknown or missing values mean `.sameAsFocused`.
    init(setting: String?) {
        self = setting.flatMap(Self.init(rawValue:)) ?? .sameAsFocused
    }

    /// The agent to start; nil means the target pane's agent and account (`AppModel.newPane`).
    var agent: AgentKind? {
        switch self {
        case .sameAsFocused: nil
        case .shell: .shell
        case .claude: .claude
        case .codex: .codex
        }
    }

    /// The agent a pane added beside one running `target` starts.
    func resolved(beside target: AgentKind) -> AgentKind {
        agent ?? target
    }

    var title: LocalizedStringKey {
        switch self {
        case .sameAsFocused: "Same as Focused Pane"
        case .shell: "Shell"
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

extension AppModel {
    var newPaneAgent: NewPaneAgent { NewPaneAgent(setting: setting(.newPaneAgent)) }

    /// Stores what new panes run; the default (the focused pane's agent) is stored as no value.
    func setNewPaneAgent(_ choice: NewPaneAgent) {
        setSetting(.newPaneAgent, choice == .sameAsFocused ? nil : choice.rawValue)
    }

    /// Adds a pane beside the selected tab's focused pane on the side `axis` names (right for `.sideBySide`, below
    /// for `.stacked`), running `agent` (the New pane runs setting when nil) with `accountID` (the agent's default
    /// account when nil). Returns the new session, nil when nothing started.
    @discardableResult
    func addPane(in context: SessionContext, axis: PaneAxis, agent: NewPaneAgent? = nil,
                 accountID: UUID? = nil) async -> UUID? {
        await newPane(in: context, edge: axis.newPaneEdge, agent: (agent ?? newPaneAgent).agent, accountID: accountID)
    }

    /// Adds a pane beside `session` (any session, not only the focused pane) on `edge` with the New pane runs
    /// setting, and shows its context. For context menus of panes, tabs and sidebar rows.
    func split(beside session: UUID, edge: PaneEdge) {
        guard let record = sessions.first(where: { $0.id == session }) else { return }
        let context = context(of: record)
        selection = context
        Task { await newPane(in: context, beside: session, edge: edge, agent: newPaneAgent.agent) }
    }

    /// Why the selected tab of `context` cannot take another pane, or nil when it can.
    func addPaneUnavailableReason(in context: SessionContext) -> LocalizedStringKey? {
        guard let target = activeSession(in: context) else { return "Select a session tab to split it" }
        return canAddPane(beside: target) ? nil : "A tab holds up to \(PaneLayout.maxPanes) panes"
    }
}

extension PaneAxis {
    /// Where a split along this axis puts the new pane: on the right side by side, below when stacked.
    var newPaneEdge: PaneEdge { self == .sideBySide ? .right : .bottom }
}

/// The title-bar split button: a click adds a pane on the right running the New pane runs setting (⌘D); its menu
/// splits right or down, with that setting or with an agent (and account) picked for this pane only. A native toolbar
/// `Menu` with a primary action, so it takes the toolbar's Liquid Glass and its pull-down indicator.
struct SplitPaneButton: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext

    var body: some View {
        let reason = model.addPaneUnavailableReason(in: context)
        Menu {
            Button("Split Right") { add(.sideBySide) }
                .keyboardShortcut("d")
            Button("Split Down") { add(.stacked) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Menu("Split Right With") { agentChoices(.sideBySide) }
            Menu("Split Down With") { agentChoices(.stacked) }
        } label: {
            Label("Split Pane", systemImage: "rectangle.split.2x1")
        } primaryAction: {
            add(.sideBySide)
        }
        .disabled(reason != nil)
        .help(reason.map { Text($0) } ?? Text("Split right: the new pane runs \(defaultDescription) (⌘D). The arrow shows more choices."))
        .accessibilityLabel(Text("Split pane"))
    }

    /// What a click starts, for the tooltip.
    private var defaultDescription: String {
        switch model.newPaneAgent {
        case .sameAsFocused: String(localized: "the same agent as the focused pane")
        case .shell: String(localized: "a shell")
        case .claude: NewSessionMenu.name(of: .claude)
        case .codex: NewSessionMenu.name(of: .codex)
        }
    }

    /// Every agent a new pane can run: the focused pane's, then each agent (with its accounts when there are several,
    /// as in `NewSessionMenu`) and a shell.
    @ViewBuilder
    private func agentChoices(_ axis: PaneAxis) -> some View {
        Button("Same as Focused Pane") { add(axis, agent: .sameAsFocused) }
        Divider()
        agentItem(.claude, axis: axis)
        agentItem(.codex, axis: axis)
        Button { add(axis, agent: .shell) } label: {
            Label { Text("Shell") } icon: { Image(systemName: "terminal") }
        }
    }

    @ViewBuilder
    private func agentItem(_ choice: NewPaneAgent, axis: PaneAxis) -> some View {
        let agent = choice.agent ?? .shell
        let provider = agent.accountProvider ?? .claude
        let accounts = model.accounts.filter { $0.provider == provider }
        if accounts.isEmpty {
            Button { add(axis, agent: choice) } label: {
                Label { Text(choice.title) } icon: { Image(nsImage: NewSessionMenu.menuIcon(agent)) }
            }
        } else {
            Menu {
                // The default account is passed on: no account would mean the focused pane's when it runs this agent.
                let fallback = model.defaultAccount(for: provider)
                Button { add(axis, agent: choice, accountID: fallback?.id) } label: {
                    Text("Default (\(fallback?.displayName ?? String(localized: "your own login")))")
                }
                Divider()
                ForEach(accounts) { account in
                    Button(account.displayName) { add(axis, agent: choice, accountID: account.id) }
                }
            } label: {
                Label { Text(choice.title) } icon: { Image(nsImage: NewSessionMenu.menuIcon(agent)) }
            }
        }
    }

    private func add(_ axis: PaneAxis, agent: NewPaneAgent? = nil, accountID: UUID? = nil) {
        Task { await model.addPane(in: context, axis: axis, agent: agent, accountID: accountID) }
    }
}
