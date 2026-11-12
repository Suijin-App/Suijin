import AppKit
import Foundation
import MercuryCore
import MercuryGit
import Observation

/// A place where sessions run: a folder workspace, the main checkout of a git workspace, or one of its worktrees.
enum SessionContext: Hashable {
    case workspace(UUID)
    case worktree(UUID)
}

extension SessionContext {
    /// `workspace:<uuid>` or `worktree:<uuid>`, for the settings table.
    var storageValue: String {
        switch self {
        case .workspace(let id): "workspace:\(id.uuidString)"
        case .worktree(let id): "worktree:\(id.uuidString)"
        }
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "workspace": self = .workspace(id)
        case "worktree": self = .worktree(id)
        default: return nil
        }
    }
}

/// An error shown to the user in an alert. The message is already localized.
struct PresentedError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Root state of the app: workspaces, worktrees, sessions and accounts, persisted through `MercuryStore`.
/// Lives on the main actor; database and git calls run off the main thread.
@Observable
@MainActor
final class AppModel {
    let store: MercuryStore
    let dataRoot: URL

    private(set) var workspaces: [Workspace] = []
    private(set) var worktrees: [UUID: [WorktreeRecord]] = [:]
    private(set) var sessions: [AgentSessionRecord] = []
    private(set) var accounts: [ManagedAccountRecord] = []

    var selection: SessionContext? {
        didSet { if selection != oldValue { setSetting(.lastSelection, selection?.storageValue) } }
    }
    /// The selected tab (a session id, or `nil` for the diff tab) per context.
    var selectedTab: [SessionContext: DetailTab] = [:]
    /// Split panes: the session a tab shows is the key, its second pane the value. Kept for the app's lifetime.
    var splits: [UUID: TerminalSplit] = [:]
    /// The pane with keyboard focus in each split tab (the tab's own session or its second pane).
    var focusedPane: [UUID: UUID] = [:]
    var presentedError: PresentedError?
    /// Files opened from terminal links, per context, in tab order. Kept for the app's lifetime.
    var openFiles: [SessionContext: [String]] = [:]
    /// The order the user dragged each context's session tabs into (`TabOrder.swift`); sessions not listed follow in
    /// the order they were created.
    var sessionOrder: [SessionContext: [UUID]] = AppModel.savedSessionOrder()
    /// A path the inspector's file tree should show (expand its folders, select, scroll to it); a new request id
    /// each time, so asking twice for the same path works.
    var fileTreeReveal: (path: String, request: UUID)?
    /// Folders the user expanded in each context's file tree, loaded from and saved to user defaults (see
    /// `expandedFolders(in:)`), so the tree reopens as it was left.
    var expandedFoldersCache: [SessionContext: Set<String>] = [:]
    /// Width of the detail column, so the title-bar tab group can size itself to the room the toolbar really has.
    var detailWidth: CGFloat = 900
    /// Sidebar rows the user folded; every other row with sessions shows them.
    var collapsedContexts: Set<SessionContext> = []
    /// A running agent whose tab the user asked to close; confirmed in the main window.
    var pendingClose: AgentSessionRecord?
    /// The Settings page shown over the main window; nil while the app itself is shown.
    var settingsPage: SettingsPage?
    /// The main window, so menu commands that act on sessions do nothing while Settings or another window is key.
    @ObservationIgnored weak var mainWindow: NSWindow?

    var isMainWindowKey: Bool { mainWindow != nil && NSApp.keyWindow === mainWindow }
    /// The workspace the "New Worktree" sheet is open for.
    var newWorktreeWorkspaceID: UUID?
    var isAddingWorkspace = false

    /// Runtime state of live sessions (terminal, status tracking); see `SessionRuntimeRegistry`.
    @ObservationIgnored lazy var runtimes = SessionRuntimeRegistry(model: self)
    /// Managed accounts at runtime (providers, usage, pointer files).
    @ObservationIgnored lazy var accountsController = AccountsController(model: self)
    /// Settings → Stats & Usage: one usage store for the app's lifetime, refreshed only while that page is shown.
    @ObservationIgnored lazy var usage = UsageController(model: self)

    init(store: MercuryStore, dataRoot: URL) {
        self.store = store
        self.dataRoot = dataRoot
    }

    /// The live app model on the user's data root.
    static func live() -> AppModel {
        let root = MercuryPaths.dataRoot
        do {
            let store = try MercuryStore(url: MercuryPaths.database(in: root))
            return AppModel(store: store, dataRoot: root)
        } catch {
            // The database could not be opened (disk full, permissions). Run on an in-memory store and tell the user.
            let model = AppModel(store: try! MercuryStore.inMemory(), dataRoot: root)
            model.presentedError = PresentedError(
                title: String(localized: "Mercury could not open its database"),
                message: error.localizedDescription
            )
            return model
        }
    }

    // MARK: Loading

    func load() async {
        await perform(String(localized: "Could not load workspaces")) {
            let store = self.store
            let (workspaces, sessions, accounts) = try await Task.detached {
                (try store.workspaces(), try store.sessions(), try store.accounts())
            }.value
            self.workspaces = workspaces.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
            self.sessions = sessions
            self.accounts = accounts
            for workspace in workspaces {
                self.worktrees[workspace.id] = try await Task.detached { try store.worktrees(workspaceID: workspace.id) }.value
            }
        }
        // Git checks run beside the session restore instead of ahead of it: the stored worktrees are enough to show
        // the window and attach the sessions.
        Task {
            for workspace in workspaces { await refreshKind(of: workspace) }
            for workspace in self.workspaces where workspace.kind == .git { await refreshWorktrees(workspaceID: workspace.id) }
        }
        if selection == nil {
            selection = restoredSelection() ?? workspaces.first.map { .workspace($0.id) }
        }
        #if DEBUG
        // Screenshot runs open a tab directly: `-MercuryInitialTab changes`.
        if UserDefaults.standard.string(forKey: "MercuryInitialTab") == "changes", let selection { selectedTab[selection] = .changes }
        // `-MercuryInitialSettings terminal` shows that Settings page.
        if let page = UserDefaults.standard.string(forKey: "MercuryInitialSettings").flatMap(SettingsPage.init(rawValue:)) { settingsPage = page }
        // `-MercuryOpenFile <path>` handles a path as a ⌘-clicked terminal link does (file tab or file-tree reveal).
        if let file = UserDefaults.standard.string(forKey: "MercuryOpenFile"), let selection {
            _ = openTerminalLink(file, in: selection, relativeTo: nil)
        }
        #endif
    }

    /// The context selected when the app last quit, if it still exists.
    private func restoredSelection() -> SessionContext? {
        guard let context = setting(.lastSelection).flatMap(SessionContext.init(storageValue:)) else { return nil }
        return directory(of: context) == nil ? nil : context
    }

    // MARK: Workspaces

    func workspace(_ id: UUID) -> Workspace? { workspaces.first { $0.id == id } }

    func worktree(_ id: UUID) -> WorktreeRecord? {
        for list in worktrees.values { if let match = list.first(where: { $0.id == id }) { return match } }
        return nil
    }

    /// Adds the chosen folder: a git workspace rooted at the repository toplevel when it is inside a repository,
    /// a plain folder workspace otherwise. Adding a folder that is already a workspace selects it.
    func addWorkspace(at url: URL) async {
        await perform(String(localized: "Could not add the workspace")) {
            let toplevel = await GitRepository.toplevel(of: url)
            let root = (toplevel ?? url).standardizedFileURL
            if let existing = self.workspaces.first(where: { $0.path == root.path }) {
                self.selection = .workspace(existing.id)
                return
            }
            let workspace = Workspace(
                name: root.lastPathComponent, path: root.path, kind: toplevel == nil ? .folder : .git,
                sortOrder: (self.workspaces.map(\.sortOrder).max() ?? -1) + 1
            )
            try await self.io { [workspace] in try $0.save(workspace) }
            self.workspaces.append(workspace)
            self.worktrees[workspace.id] = []
            self.selection = .workspace(workspace.id)
            if workspace.kind == .git { await self.refreshWorktrees(workspaceID: workspace.id) }
        }
    }

    /// Saves a changed workspace (name, icon, color) and shows it.
    func update(_ workspace: Workspace) async {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index] = workspace
        try? await io { [workspace] in try $0.save(workspace) }
    }

    /// Stops the workspace's sessions and forgets it. Files on disk (worktrees included) are left alone.
    func removeWorkspace(_ id: UUID) async {
        for session in sessions where session.workspaceID == id { await closeSession(session.id) }
        await perform(String(localized: "Could not remove the workspace")) {
            try await self.io { try $0.deleteWorkspace(id: id) }
            self.workspaces.removeAll { $0.id == id }
            let removedTrees = Set((self.worktrees[id] ?? []).map(\.id))
            self.worktrees[id] = nil
            self.sessions.removeAll { $0.workspaceID == id }
            self.selectedTab = self.selectedTab.filter { context, _ in
                if case .workspace(let workspace) = context { return workspace != id }
                if case .worktree(let tree) = context { return !removedTrees.contains(tree) }
                return true
            }
            if let selection = self.selection, self.directory(of: selection) == nil {
                self.selection = self.workspaces.first.map { .workspace($0.id) }
            }
        }
    }

    /// A folder that became a repository (`git init`) turns into a git workspace; a repository whose `.git` is gone
    /// becomes a folder. Checked on launch and whenever the workspace is selected.
    func refreshKind(of workspace: Workspace) async {
        let url = URL(fileURLWithPath: workspace.path, isDirectory: true)
        // A folder that is missing right now (unmounted volume) keeps its kind until it is back.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let isGit = await GitRepository.toplevel(of: url) != nil
        let kind: WorkspaceKind = isGit ? .git : .folder
        guard kind != workspace.kind, let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        var updated = workspace
        updated.kind = kind
        try? await io { [updated] in try $0.save(updated) }
        workspaces[index] = updated
        if kind == .git { await refreshWorktrees(workspaceID: workspace.id) }
    }

    // MARK: Worktrees

    /// Reconciles stored worktrees with `git worktree list`: worktrees made outside Mercury appear, removed ones go.
    func refreshWorktrees(workspaceID: UUID) async {
        guard let workspace = workspace(workspaceID), workspace.kind == .git else { return }
        let service = WorktreeService(repository: URL(fileURLWithPath: workspace.path, isDirectory: true))
        guard let live = try? await service.list() else { return }
        let existing = worktrees[workspaceID] ?? []
        var result: [WorktreeRecord] = []
        for tree in live where !tree.isMain {
            let path = tree.path.standardizedFileURL.path
            if let known = existing.first(where: { $0.path == path }) {
                var record = known
                if let branch = tree.branch, branch != known.branch {
                    record.branch = branch
                    try? await io { [record] in try $0.save(record) }
                }
                result.append(record)
            } else {
                let record = WorktreeRecord(workspaceID: workspaceID, path: path, branch: tree.branch ?? tree.path.lastPathComponent)
                try? await io { [record] in try $0.save(record) }
                result.append(record)
            }
        }
        for gone in existing where !result.contains(where: { $0.id == gone.id }) {
            if sessions.contains(where: { $0.worktreeID == gone.id && runtimes.runtime(for: $0.id) != nil }) {
                result.append(gone) // Keep a worktree whose agent still runs; it disappears once the session ends.
            } else {
                try? await io { try $0.deleteWorktree(id: gone.id) }
                sessions.removeAll { $0.worktreeID == gone.id }
            }
        }
        // Assigned only when something changed: every view that resolves a context's directory reads `worktrees`.
        let sorted = result.sorted { $0.createdAt < $1.createdAt }
        if worktrees[workspaceID] != sorted { worktrees[workspaceID] = sorted }
        if let selection, directory(of: selection) == nil { self.selection = .workspace(workspaceID) }
    }

    func createWorktree(workspaceID: UUID, branch: String, base: String, path: URL) async throws -> WorktreeRecord {
        guard let workspace = workspace(workspaceID) else { throw CocoaError(.fileNoSuchFile) }
        let service = WorktreeService(repository: URL(fileURLWithPath: workspace.path, isDirectory: true))
        // Checked before any folder is made, so a name git refuses leaves nothing behind.
        guard await service.validateBranchName(branch) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: String(localized: "“\(branch)” is not a valid branch name.")])
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await service.add(branch: branch, at: path, base: base)
        let record = WorktreeRecord(workspaceID: workspaceID, path: path.standardizedFileURL.path, branch: branch, baseBranch: base)
        try await io { [record] in try $0.save(record) }
        worktrees[workspaceID, default: []].append(record)
        selection = .worktree(record.id)
        return record
    }

    /// Stops the worktree's sessions first, then removes the worktree directory through git.
    func removeWorktree(_ id: UUID, force: Bool) async {
        guard let record = worktree(id), let workspace = workspace(record.workspaceID) else { return }
        for session in sessions where session.worktreeID == id { await closeSession(session.id) }
        await perform(String(localized: "Could not remove the worktree")) {
            let service = WorktreeService(repository: URL(fileURLWithPath: workspace.path, isDirectory: true))
            try await service.remove(at: URL(fileURLWithPath: record.path), force: force)
            try? await service.prune()
            try await self.io { try $0.deleteWorktree(id: id) }
            self.worktrees[workspace.id]?.removeAll { $0.id == id }
            self.sessions.removeAll { $0.worktreeID == id }
            if self.selection == .worktree(id) { self.selection = .workspace(workspace.id) }
        }
    }

    // MARK: Contexts

    func workspaceID(of context: SessionContext) -> UUID? {
        switch context {
        case .workspace(let id): id
        case .worktree(let id): worktree(id)?.workspaceID
        }
    }

    /// The directory sessions of this context run in.
    func directory(of context: SessionContext) -> URL? {
        switch context {
        case .workspace(let id): workspace(id).map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        case .worktree(let id): worktree(id).map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        }
    }

    func sessions(in context: SessionContext) -> [AgentSessionRecord] {
        let inContext = switch context {
        case .workspace(let id): sessions.filter { $0.workspaceID == id && $0.worktreeID == nil }
        case .worktree(let id): sessions.filter { $0.worktreeID == id }
        }
        guard let order = sessionOrder[context], !order.isEmpty else { return inContext }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return inContext.enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element.id], rank[rhs.element.id]) {
            case let (l?, r?): l < r
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    func context(of session: AgentSessionRecord) -> SessionContext {
        session.worktreeID.map { .worktree($0) } ?? .workspace(session.workspaceID)
    }

    // MARK: Sessions

    func upsert(_ session: AgentSessionRecord) async {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session } else { sessions.append(session) }
        try? await io { [session] in try $0.save(session) }
    }

    /// Ends the session's processes and forgets the tab.
    func closeSession(_ id: UUID) async {
        await runtimes.terminate(id)
        // Closing a split's first pane leaves the second as a tab of its own; closing the second unsplits.
        splits[id] = nil
        focusedPane[id] = nil
        for (primary, split) in splits where split.secondary == id {
            splits[primary] = nil
            focusedPane[primary] = nil
        }
        sessions.removeAll { $0.id == id }
        try? await io { try $0.deleteSession(id: id) }
        for (context, tab) in selectedTab where tab == .session(id) { selectedTab[context] = nil }
    }

    // MARK: Accounts

    func upsert(_ account: ManagedAccountRecord) async {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account } else { accounts.append(account) }
        try? await io { [account] in try $0.save(account) }
    }

    func deleteAccountRecord(_ id: UUID) async {
        accounts.removeAll { $0.id == id }
        try? await io { try $0.deleteAccount(id: id) }
    }

    /// The account new sessions of this provider use when none is chosen; `nil` means the user's own login.
    func defaultAccount(for provider: AccountProvider) -> ManagedAccountRecord? {
        let key: SettingKey = provider == .claude ? .defaultClaudeAccount : .defaultCodexAccount
        guard let raw = setting(key), let id = UUID(uuidString: raw) else { return nil }
        return accounts.first { $0.id == id && $0.provider == provider }
    }

    func setting(_ key: SettingKey) -> String? { settingsCache[key.rawValue] ?? nil }

    /// Bumped when a terminal theme or font setting changes, so visible terminals restyle.
    private(set) var terminalStyleRevision = 0

    func setSetting(_ key: SettingKey, _ value: String?) {
        settingsCache[key.rawValue] = value
        if [.terminalTheme, .terminalFontFamily, .terminalFontSize, .terminalGPURendering].contains(key) { terminalStyleRevision += 1 }
        let store = store
        Task.detached { try? store.setSetting(key.rawValue, value) }
    }

    /// Settings read once at launch (`loadSettings`) and written through.
    private var settingsCache: [String: String?] = [:]

    func loadSettings() async {
        let store = store
        let values = await Task.detached {
            SettingKey.allCases.map { key in (key.rawValue, (try? store.setting(key.rawValue)) ?? nil) }
        }.value
        for (key, value) in values { settingsCache[key] = value }
    }

    // MARK: Helpers

    /// Runs a database call off the main thread.
    func io<T: Sendable>(_ work: @escaping @Sendable (MercuryStore) throws -> T) async throws -> T {
        let store = store
        return try await Task.detached { try work(store) }.value
    }

    /// Runs `work` and shows any error in an alert titled `title`.
    func perform(_ title: String, _ work: () async throws -> Void) async {
        do { try await work() } catch {
            presentedError = PresentedError(title: title, message: error.localizedDescription)
        }
    }
}

/// A tab in the detail area: one session's terminal, the worktree's changes, or a file opened from a terminal link.
enum DetailTab: Hashable {
    case session(UUID)
    case changes
    /// An absolute file path.
    case file(String)
}

/// The second pane of a split tab.
struct TerminalSplit: Hashable {
    enum Axis: Hashable { case sideBySide, stacked }
    let secondary: UUID
    let axis: Axis
}

/// Keys of the `setting` table.
enum SettingKey: String, CaseIterable {
    case defaultClaudeAccount = "accounts.claude.default"
    case defaultCodexAccount = "accounts.codex.default"
    case worktreeRoot = "worktrees.root"
    case defaultAgent = "agents.default"
    case keepSessionsOnQuit = "terminal.keepSessionsOnQuit"
    case terminalTheme = "terminal.theme"
    case terminalFontFamily = "terminal.fontFamily"
    case terminalFontSize = "terminal.fontSize"
    /// "false" draws terminals with CoreGraphics; missing or "true" uses the Metal renderer.
    case terminalGPURendering = "terminal.gpuRendering"
    case notifyWhenWaiting = "notifications.waiting"
    case lastSelection = "ui.lastSelection"
    case codexNoDaemon = "agents.codex.noDaemon"
    /// `AppAppearance` raw value; missing means follow the system.
    case appearance = "ui.appearance"
}

/// The app-wide appearance chosen in Settings → General.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    /// The stored setting; unknown or missing values mean `.system`.
    init(setting: String?) {
        self = setting.flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// `nil` lets the app follow the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension AppModel {
    var appearance: AppAppearance { AppAppearance(setting: setting(.appearance)) }

    /// Stores the appearance and applies it to every window right away.
    func setAppearance(_ appearance: AppAppearance) {
        setSetting(.appearance, appearance == .system ? nil : appearance.rawValue)
        applyAppearance()
    }

    /// Sets `NSApp.appearance` from the setting. In debug builds the `-MercuryAppearance` launch argument (screenshot
    /// runs) wins over the setting.
    func applyAppearance() {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "MercuryAppearance") != nil { return }
        #endif
        NSApp?.appearance = appearance.nsAppearance
    }
}
