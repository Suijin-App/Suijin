import SevindaCore
import SevindaUI
import SwiftUI

/// Permission modes in the app: their names, the default of each agent (Settings → Agents), the confirmation before an
/// agent first starts without permission checks, the submenu that starts a session in a chosen mode, and the warning
/// badge of a session started that way. The flags themselves come from `AgentLaunchSpecBuilder.permissionArguments`.
extension AgentPermissionMode {
    var title: LocalizedStringKey {
        switch self {
        case .ask: "Ask"
        case .acceptEdits: "Auto-Accept Edits"
        case .plan: "Plan"
        case .auto: "Auto"
        case .readOnly: "Read-Only"
        case .bypass: "Skip All Permissions"
        }
    }

    /// The same name with "(Default)" after it, for the agent's default in a menu.
    var defaultTitle: LocalizedStringKey {
        switch self {
        case .ask: "Ask (Default)"
        case .acceptEdits: "Auto-Accept Edits (Default)"
        case .plan: "Plan (Default)"
        case .auto: "Auto (Default)"
        case .readOnly: "Read-Only (Default)"
        case .bypass: "Skip All Permissions (Default)"
        }
    }

    var systemImage: String {
        switch self {
        case .ask: "hand.raised"
        case .acceptEdits: "pencil"
        case .plan: "list.bullet.clipboard"
        case .auto: "bolt"
        case .readOnly: "eye"
        case .bypass: "exclamationmark.shield"
        }
    }
}

/// An agent start in a mode without permission checks, waiting for the user to confirm it.
struct PendingPermissionConfirmation: Identifiable {
    let id = UUID()
    let agent: AgentKind
    let mode: AgentPermissionMode
    let action: @MainActor () -> Void
}

extension AppModel {
    private static func permissionKey(for agent: AgentKind) -> SettingKey? {
        switch agent {
        case .claude: .claudePermissionMode
        case .codex: .codexPermissionMode
        case .shell: nil
        }
    }

    /// The mode new sessions of `agent` start with when none is chosen: Settings → Agents, `ask` when unset.
    func defaultPermissionMode(for agent: AgentKind) -> AgentPermissionMode {
        AgentPermissionMode.resolve(choice: nil, setting: Self.permissionKey(for: agent).flatMap(setting), for: agent)
    }

    /// Stores the default mode of `agent`; `ask` is stored as no value.
    func setDefaultPermissionMode(_ mode: AgentPermissionMode, for agent: AgentKind) {
        guard let key = Self.permissionKey(for: agent), mode.applies(to: agent) else { return }
        setSetting(key, mode == .ask ? nil : mode.rawValue)
    }

    /// The mode a new session of `agent` starts with: `choice` (a menu item, a repeated session) or the default.
    func permissionMode(for agent: AgentKind, choice: AgentPermissionMode?) -> AgentPermissionMode {
        AgentPermissionMode.resolve(choice: choice, setting: Self.permissionKey(for: agent).flatMap(setting), for: agent)
    }

    /// Runs `action` at once, unless `mode` skips every permission check and the user has not turned the confirmation
    /// off: then the main window asks first (`PermissionConfirmationAlert`) and runs it only once confirmed.
    func confirmPermissions(_ mode: AgentPermissionMode, for agent: AgentKind, then action: @escaping @MainActor () -> Void) {
        guard mode.isDangerous, setting(.skipPermissionsConfirmed) != "true" else {
            action()
            return
        }
        pendingPermissionConfirmation = PendingPermissionConfirmation(agent: agent, mode: mode, action: action)
    }

    /// The user confirmed the pending start; with `dontAskAgain` later ones start without asking.
    func confirmPendingPermissions(dontAskAgain: Bool) {
        guard let pending = pendingPermissionConfirmation else { return }
        pendingPermissionConfirmation = nil
        if dontAskAgain { setSetting(.skipPermissionsConfirmed, "true") }
        pending.action()
    }
}

/// "Permissions" in the new-session menus (title bar, sidebar, split button): each agent's modes, the default marked;
/// picking one starts that agent in that mode with its default account, through `start`. A mode without permission
/// checks is confirmed first (`AppModel.confirmPermissions`).
struct PermissionModeMenu: View {
    @Environment(AppModel.self) private var model
    let start: @MainActor (AgentKind, AgentPermissionMode) -> Void

    var body: some View {
        Menu {
            ForEach([AgentKind.claude, .codex], id: \.self) { agent in
                Section(NewSessionMenu.name(of: agent)) {
                    let defaultMode = model.defaultPermissionMode(for: agent)
                    ForEach(AgentPermissionMode.modes(for: agent)) { mode in
                        Button {
                            model.confirmPermissions(mode, for: agent) { start(agent, mode) }
                        } label: {
                            Label { Text(mode == defaultMode ? mode.defaultTitle : mode.title) } icon: {
                                Image(systemName: mode.systemImage)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Permissions", systemImage: "lock.shield")
        }
    }
}

/// The warning on a session's tab, pane header and sidebar row when its agent was started without permission checks.
struct PermissionsSkippedBadge: View {
    let session: AgentSessionRecord

    var body: some View {
        if session.skipsPermissions {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(SevindaColor.warningText)
                .help(Text("Started with permission checks skipped"))
                .accessibilityLabel(Text("Permissions skipped"))
        }
    }
}

/// Asks before an agent starts without permission checks, with "Don't ask again". Attached to the main window.
struct PermissionConfirmationAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var dontAskAgain = false

    func body(content: Content) -> some View {
        let pending = model.pendingPermissionConfirmation
        content.alert(
            Text("Start \(NewSessionMenu.name(of: pending?.agent ?? .claude)) without permission checks?"),
            isPresented: Binding(get: { model.pendingPermissionConfirmation != nil },
                                 set: { if !$0 { model.pendingPermissionConfirmation = nil } }),
            presenting: pending
        ) { _ in
            Button("Start Anyway", role: .destructive) {
                let suppress = dontAskAgain
                dontAskAgain = false
                model.confirmPendingPermissions(dontAskAgain: suppress)
            }
            Button("Cancel", role: .cancel) { dontAskAgain = false }
        } message: { pending in
            if pending.agent == .codex {
                Text("Codex will run every command and change any file without asking, outside its sandbox. Use this only in a folder you can afford to lose, ideally an isolated machine.")
            } else {
                Text("Claude Code will run every command and change any file without asking. Use this only in a folder you can afford to lose, ideally an isolated machine.")
            }
        }
        .dialogSuppressionToggle("Don’t ask again", isSuppressed: $dontAskAgain)
    }
}

/// Settings → Agents: the mode new Claude Code and Codex sessions start with.
struct PermissionDefaultsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            picker(for: .claude)
            picker(for: .codex)
        } header: {
            Text("Permissions")
        } footer: {
            Text("New sessions, panes, ⌘T and ⌘D start with these modes; the Permissions menu picks another for one session. Resume Session, Start Again and New Session Like This keep the session’s mode. Skip All Permissions lets the agent change anything without asking.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func picker(for agent: AgentKind) -> some View {
        Picker(selection: Binding(
            get: { model.defaultPermissionMode(for: agent) },
            set: { mode in
                model.confirmPermissions(mode, for: agent) { model.setDefaultPermissionMode(mode, for: agent) }
            }
        )) {
            ForEach(AgentPermissionMode.modes(for: agent)) { mode in
                Text(mode.title).tag(mode)
            }
        } label: {
            Label {
                Text(verbatim: NewSessionMenu.name(of: agent))
            } icon: {
                AgentLogo(agent: agent, size: 16)
            }
        }
        .accessibilityLabel(Text("\(NewSessionMenu.name(of: agent)) permissions"))
    }
}
