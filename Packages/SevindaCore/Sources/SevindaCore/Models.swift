import Foundation

/// Where Sevinda keeps its state. Tests and isolated runs point `dataRoot` elsewhere.
public enum SevindaPaths {
    public static var dataRoot: URL {
        if let override = ProcessInfo.processInfo.environment["SEVINDA_DATA_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Sevinda", isDirectory: true)
    }

    public static func database(in root: URL) -> URL {
        root.appendingPathComponent("sevinda.sqlite")
    }
}

/// A git repository (worktrees and diffs available) or a plain folder (agents run straight in it).
public enum WorkspaceKind: String, Codable, Sendable, CaseIterable {
    case git, folder
}

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude, codex, shell
}

/// How much an agent session may do without asking: the CLI's own permission prompts (`ask`, no flag), something in
/// between, or no checks at all (`bypass`). Claude Code offers `ask`, `acceptEdits`, `plan` and `bypass`; Codex offers
/// `ask`, `auto`, `readOnly` and `bypass`. `AgentLaunchSpecBuilder.permissionArguments` turns a mode into flags.
public enum AgentPermissionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The CLI's default: it asks before acting (no flag, so the user's own CLI settings still apply).
    case ask
    /// Claude: file edits are accepted without asking.
    case acceptEdits
    /// Claude: plan only, nothing is changed.
    case plan
    /// Codex: works in the folder on its own, asks for anything beyond it.
    case auto
    /// Codex: may read but not change files or run commands that write.
    case readOnly
    /// No permission checks and, for Codex, no sandbox.
    case bypass

    public var id: Self { self }

    /// The modes `agent` offers, in menu order; none for a shell.
    public static func modes(for agent: AgentKind) -> [AgentPermissionMode] {
        switch agent {
        case .claude: [.ask, .acceptEdits, .plan, .bypass]
        case .codex: [.ask, .auto, .readOnly, .bypass]
        case .shell: []
        }
    }

    /// Whether `agent` offers this mode.
    public func applies(to agent: AgentKind) -> Bool {
        Self.modes(for: agent).contains(self)
    }

    /// The agent acts without any permission check.
    public var isDangerous: Bool { self == .bypass }

    /// The mode a new `agent` session starts with: `choice` when one was made for this session (a menu item, the
    /// session repeated), else the stored default `setting` (an `AgentPermissionMode` raw value). A value `agent` does
    /// not offer, or none at all, means `ask`.
    public static func resolve(choice: AgentPermissionMode?, setting: String?, for agent: AgentKind) -> AgentPermissionMode {
        if let choice { return choice.applies(to: agent) ? choice : .ask }
        guard let stored = setting.flatMap(Self.init(rawValue:)), stored.applies(to: agent) else { return .ask }
        return stored
    }
}

public enum AccountProvider: String, Codable, Sendable, CaseIterable {
    case claude, codex
}

/// Persisted lifecycle state of a session; the live activity comes from `AgentStatusTracker`.
public enum SessionState: String, Codable, Sendable {
    case starting, running, waitingForInput, idle, exited, failed
}

/// How a workspace looks in the sidebar. `nil` on the workspace means the default monogram.
public enum WorkspaceIcon: Codable, Hashable, Sendable {
    /// An SF Symbol name.
    case symbol(String)
    case emoji(String)
    /// A PNG in `<dataRoot>/workspace-icons/`, by file name (an uploaded picture or the GitHub owner's avatar).
    case image(String)
}

public struct Workspace: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// The folder root; for a git workspace, the repository toplevel.
    public var path: String
    public var kind: WorkspaceKind
    public var sortOrder: Int
    public var createdAt: Date
    public var icon: WorkspaceIcon?
    /// Glyph tint as a system color name (`blue`, `teal`, …); `nil` uses the secondary label color.
    public var color: String?

    public init(
        id: UUID = UUID(), name: String, path: String, kind: WorkspaceKind, sortOrder: Int = 0, createdAt: Date = Date(),
        icon: WorkspaceIcon? = nil, color: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.icon = icon
        self.color = color
    }
}

public struct WorktreeRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var workspaceID: UUID
    public var path: String
    public var branch: String
    public var baseBranch: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), workspaceID: UUID, path: String, branch: String, baseBranch: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.workspaceID = workspaceID
        self.path = path
        self.branch = branch
        self.baseBranch = baseBranch
        self.createdAt = createdAt
    }
}

public struct AgentSessionRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var workspaceID: UUID
    /// Nil for folder workspaces and for sessions in the repository's main checkout.
    public var worktreeID: UUID?
    public var agent: AgentKind
    public var accountID: UUID?
    public var title: String
    public var cwd: String
    /// Session id inside the PTY host helper, used to attach again after the app restarts.
    public var hostSessionID: String?
    public var state: SessionState
    public var exitCode: Int32?
    public var createdAt: Date
    public var endedAt: Date?
    /// The agent's own id for its conversation (Claude Code's session id, Codex's thread id), so an ended session can
    /// be resumed. Nil for shells and until the agent reported it.
    public var agentSessionID: String?
    /// The permission mode the agent was started with; nil means `ask` (sessions stored before modes existed, shells).
    /// Resuming or repeating the session uses it again.
    public var permissionMode: AgentPermissionMode?

    public init(
        id: UUID = UUID(), workspaceID: UUID, worktreeID: UUID? = nil, agent: AgentKind, accountID: UUID? = nil,
        title: String, cwd: String, hostSessionID: String? = nil, state: SessionState = .starting,
        exitCode: Int32? = nil, createdAt: Date = Date(), endedAt: Date? = nil, agentSessionID: String? = nil,
        permissionMode: AgentPermissionMode? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.worktreeID = worktreeID
        self.agent = agent
        self.accountID = accountID
        self.title = title
        self.cwd = cwd
        self.hostSessionID = hostSessionID
        self.state = state
        self.exitCode = exitCode
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.agentSessionID = agentSessionID
        self.permissionMode = permissionMode
    }

    /// The mode the session runs with: `ask` when none is stored or the agent does not offer the stored one.
    public var effectivePermissionMode: AgentPermissionMode {
        guard let permissionMode, permissionMode.applies(to: agent) else { return .ask }
        return permissionMode
    }

    /// The agent was started without permission checks, so its tab, pane and sidebar row carry a warning. An agent a
    /// user starts by hand in a shell never counts: Sevinda does not know its flags.
    public var skipsPermissions: Bool { effectivePermissionMode.isDangerous }
}

public struct ManagedAccountRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var provider: AccountProvider
    public var label: String
    public var email: String?
    public var organization: String?
    /// `CLAUDE_CONFIG_DIR` or `CODEX_HOME` of this account.
    public var homePath: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(), provider: AccountProvider, label: String, email: String? = nil,
        organization: String? = nil, homePath: String, createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.email = email
        self.organization = organization
        self.homePath = homePath
        self.createdAt = createdAt
    }
}
