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

    public init(
        id: UUID = UUID(), workspaceID: UUID, worktreeID: UUID? = nil, agent: AgentKind, accountID: UUID? = nil,
        title: String, cwd: String, hostSessionID: String? = nil, state: SessionState = .starting,
        exitCode: Int32? = nil, createdAt: Date = Date(), endedAt: Date? = nil
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
    }
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
