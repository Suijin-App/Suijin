# Contracts between packages (implementation wave 1)

Every package agent implements its own package against these contracts. Names and signatures here are binding;
add helpers freely, but do not rename or drop what is listed. A change that breaks a contract must be reported
back to the controller rather than made silently.

Common rules: Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete` (packages use `swiftLanguageModes: [.v6]`),
macOS 15 deployment, all comments in English, no UI text in packages except MercuryUI/MercuryDiff (English,
`String(localized:bundle:.module)`). Never print, log or persist tokens. Data root is
`~/Library/Application Support/Mercury` (`MercuryPaths.dataRoot`), overridable for tests.

## Package graph

```
MercuryUI            (no deps)
MercuryCore          GRDB
MercuryGit           (no deps)
MercuryPTYProtocol   (no deps)            products: MercuryPTYProtocol, MercuryPTYHostKit
MercuryTerminal      SwiftTerm, MercuryPTYProtocol
MercuryAgents        MercuryCore
MercuryAccounts      MercuryCore, MercuryAgents
MercuryDiff          MercuryGit, MercuryUI, tree-sitter packages
App (Mercury)        all of the above
Helper MercuryPTYHost  MercuryPTYHostKit, MercuryPTYProtocol
```

## MercuryCore

```swift
public enum MercuryPaths { static var dataRoot: URL; static func database(in root: URL) -> URL /* mercury.sqlite */ }
public enum WorkspaceKind: String, Codable, Sendable, CaseIterable { case git, folder }
public enum AgentKind: String, Codable, Sendable, CaseIterable { case claude, codex, shell }
public enum AccountProvider: String, Codable, Sendable, CaseIterable { case claude, codex }
public enum SessionState: String, Codable, Sendable { case starting, running, waitingForInput, idle, exited, failed }

public struct Workspace: Identifiable, Codable, Hashable, Sendable   // id: UUID, name, path (root; repo toplevel for git),
                                                                     // kind, sortOrder: Int, createdAt: Date
public struct WorktreeRecord: Identifiable, Codable, Hashable, Sendable // id, workspaceID, path, branch, baseBranch: String?, createdAt
public struct AgentSessionRecord: Identifiable, Codable, Hashable, Sendable
    // id, workspaceID, worktreeID: UUID? (nil for folder workspaces and the main checkout), agent: AgentKind,
    // accountID: UUID?, title, cwd, hostSessionID: String? (PTY host session id), state: SessionState,
    // exitCode: Int32?, createdAt, endedAt: Date?
public struct ManagedAccountRecord: Identifiable, Codable, Hashable, Sendable
    // id, provider, label, email: String?, organization: String?, homePath (CLAUDE_CONFIG_DIR / CODEX_HOME), createdAt

public final class MercuryStore: Sendable {            // GRDB DatabaseQueue, versioned migrations ("v1", ...)
    public init(url: URL) throws                       // creates the parent directory
    public static func inMemory() throws -> MercuryStore
    // Synchronous, thread-safe; callers run them off the main thread.
    func workspaces() throws -> [Workspace]; func save(_: Workspace) throws; func deleteWorkspace(id: UUID) throws
    func worktrees(workspaceID: UUID) throws -> [WorktreeRecord]; func save(_: WorktreeRecord) throws; func deleteWorktree(id: UUID) throws
    func sessions() throws -> [AgentSessionRecord]; func save(_: AgentSessionRecord) throws; func deleteSession(id: UUID) throws
    func accounts() throws -> [ManagedAccountRecord]; func save(_: ManagedAccountRecord) throws; func deleteAccount(id: UUID) throws
    func setting(_ key: String) throws -> String?; func setSetting(_ key: String, _ value: String?) throws
}
```
Deleting a workspace cascades to its worktrees and sessions (foreign keys).

## MercuryGit

```swift
public struct GitRunner: Sendable { init(executable: URL = /usr/bin/git); func run(_ args: [String], in dir: URL) async throws -> Data }
public struct GitError: Error, LocalizedError { args, exitCode, stderr }
public enum GitRepository { static func toplevel(of dir: URL, runner: GitRunner = .init()) async -> URL? }   // nil = not git
public struct Worktree: Hashable, Sendable { path: URL, head: String?, branch: String? /* short name */, isMain, isDetached, isLocked, isPrunable }
public struct WorktreeService: Sendable {
    init(repository: URL, runner: GitRunner = .init())
    func list() async throws -> [Worktree]                                  // `worktree list --porcelain -z`
    func add(branch: String, at path: URL, base: String) async throws        // `worktree add -b`
    func remove(at path: URL, force: Bool) async throws; func prune() async throws
    func hasUncommittedChanges(at path: URL) async throws -> Bool            // `status --porcelain -z`
    static func defaultPath(repository: URL, branch: String) -> URL          // <repo>/../<repo>-worktrees/<branch>
    func localBranches() async throws -> [String]; func currentBranch() async throws -> String?
    func defaultBaseBranch() async throws -> String                          // origin/HEAD, else main/master, else current
}
// Diff (phase 8)
public enum FileChangeKind: Sendable { case added, deleted, modified, renamed(from: String), copied(from: String), typeChanged, unmerged }
public struct ChangedFile: Hashable, Sendable { path: String, kind: FileChangeKind }
public enum DiffLineKind: Sendable { case context, added, deleted, noNewlineMarker }
public struct DiffLine: Hashable, Sendable { kind, text: String, oldLine: Int?, newLine: Int? }
public struct DiffHunk: Hashable, Sendable { header: String, oldStart, oldCount, newStart, newCount, lines: [DiffLine] }
public struct FileDiff: Hashable, Sendable { oldPath: String?, newPath: String?, isBinary: Bool, hunks: [DiffHunk] }
public enum DiffParser { static func parse(_ unifiedDiff: String) -> [FileDiff] }
public enum DiffScope: Sendable { case againstBase(String) /* base...HEAD + working tree */, case uncommitted }
public struct DiffService: Sendable {
    init(worktree: URL, runner: GitRunner = .init())
    func changedFiles(_ scope: DiffScope) async throws -> [ChangedFile]     // --name-status -z
    func diff(for path: String, scope: DiffScope) async throws -> FileDiff  // --no-color --unified=3
}
```

## MercuryPTYProtocol / MercuryPTYHostKit

```swift
public enum PTYHostConstants { machServiceName = "com.tekmium.mercury.ptyhost"; launchAgentPlist = "com.tekmium.mercury.ptyhost.plist";
                               protocolVersion: Int = 1 }
public struct PTYSpawnRequest: Codable, Sendable { executable: String, arguments: [String], environment: [String: String],
                                                   cwd: String, cols: Int, rows: Int, metadata: [String: String] }
public struct PTYSessionInfo: Codable, Sendable { id: String, pid: Int32, executable: String, cwd: String, startedAt: Date,
                                                  isRunning: Bool, exitStatus: Int32?, metadata: [String: String] }
@objc public protocol PTYHostXPC {          // exported by the helper; all payloads JSON Data for forward compatibility
    func handshake(clientProtocolVersion: Int, reply: @escaping @Sendable (_ hostProtocolVersion: Int, _ hostBuild: String) -> Void)
    func listSessions(reply: @escaping @Sendable (Data) -> Void)                       // [PTYSessionInfo]
    func spawn(_ request: Data, reply: @escaping @Sendable (_ sessionID: String?, _ error: String?) -> Void)
    func attach(_ sessionID: String, reply: @escaping @Sendable (_ scrollback: Data?, _ info: Data?) -> Void) // then output streams
    func detach(_ sessionID: String)
    func write(_ sessionID: String, data: Data)
    func resize(_ sessionID: String, cols: Int, rows: Int)
    func terminate(_ sessionID: String)     // SIGHUP, wait 2s, SIGKILL the process group
    func shutdownIfIdle()
}
@objc public protocol PTYClientXPC {        // exported by the app on the same connection
    func output(_ sessionID: String, data: Data)
    func exited(_ sessionID: String, status: Int32)
}
public enum PTYXPCInterfaces { static func host() -> NSXPCInterface; static func client() -> NSXPCInterface }
```
HostKit: `ScrollbackBuffer` (byte ring buffer, cap in bytes, default 8 MB), `PTYSession` (forkpty/posix_spawn with
setsid + controlling tty, nonblocking read source, batches output ≥ every 8 ms or 64 KB), `SessionManager`
(sessions by id, attached clients, reaping exited sessions after N hours, idle exit callback), `PTYHostService`
(the `PTYHostXPC` implementation, works on any `NSXPCListener`, including `.anonymous()` for tests).

## MercuryTerminal

```swift
public struct TerminalSize: Sendable, Hashable { cols: Int, rows: Int }
public struct TerminalLaunch: Sendable, Hashable { executable: String, arguments: [String], environment: [String: String],
                                                    cwd: String, metadata: [String: String] }
@MainActor public protocol TerminalEngine: AnyObject {
    var onOutput: (@MainActor (ArraySlice<UInt8>) -> Void)? { get set }
    var onExit: (@MainActor (Int32?) -> Void)? { get set }
    var sessionID: String? { get }                     // PTY host id for hosted engines, nil in-process
    func start(_ launch: TerminalLaunch, size: TerminalSize) async throws
    func write(_ bytes: ArraySlice<UInt8>)
    func resize(_ size: TerminalSize)
    func terminate() async                             // SIGHUP → wait → SIGKILL; no orphan processes
}
public final class SwiftTermEngine: TerminalEngine     // in-process LocalProcess
public final class HostedTerminalEngine: TerminalEngine { init(client: PTYHostClient); func attach(sessionID:) async throws -> [UInt8] /* scrollback */ }
@MainActor public final class PTYHostClient {          // owns the NSXPCConnection (Mach service or an injected endpoint)
    public static let shared: PTYHostClient
    init(connectionFactory: @escaping () -> NSXPCConnection)
    func register() throws                              // SMAppService.agent(plistName:) registration
    func listSessions() async throws -> [PTYSessionInfo]
}
@MainActor open class MercuryTerminalView: SwiftTerm.TerminalView  // display + input only (no process); paste guard hooks
@MainActor public final class TerminalSession  // binds one TerminalEngine to one MercuryTerminalView (feed/send/resize)
public enum ShellLaunch {
    static func userShell() -> String                                     // pw_shell, fallback /bin/zsh
    static func interactiveShell(cwd: URL, environment: [String: String]) -> TerminalLaunch   // login shell + integration
    static func command(_ executable: String, _ args: [String], cwd: URL, environment: [String: String]) -> TerminalLaunch
        // runs through the login shell (`$SHELL -l -c 'exec "$0" "$@"'`) so PATH matches the user's terminal
    static func baseEnvironment() -> [String: String]                     // TERM=xterm-256color, COLORTERM, LANG, MERCURY_*
}
public enum ShellIntegration { static func install(in root: URL) throws -> URL }   // writes ZDOTDIR + bash rcfile, sources the
                                                                                    // user's files first, then Mercury's
                                                                                    // claude/codex shell functions
```
Shell functions read the pointer files `<dataRoot>/claude-profiles/selected-host` and `<dataRoot>/codex-homes/selected-host`
(content: absolute config dir path, empty/missing = default login). They respect a user-set `CLAUDE_CONFIG_DIR` /
`CODEX_HOME` and an existing user `claude`/`codex` function. Env var `MERCURY_DATA_ROOT` tells them the root.

## MercuryAgents

```swift
public struct EnvPatch: Sendable, Hashable { set: [String: String], unset: Set<String>;
                                             func applied(to: [String: String]) -> [String: String]; func merging(_: EnvPatch) -> EnvPatch }
public struct AgentDefinition: Sendable { kind: AgentKind, displayName, binaryName, systemImage }
public enum AgentCatalog { static let claude, codex: AgentDefinition; static let all;
                           static func resolveBinary(_ kind: AgentKind, path: String) -> URL?
                           static func loginShellPATH() async -> String /* cached; `$SHELL -l -c 'printf %s "$PATH"'` */ }
public struct AgentLaunchSpec: Sendable { kind, binary: URL, arguments: [String], cwd: URL, env: EnvPatch, initialPrompt: String? }
public enum AgentLaunchSpecBuilder { static func make(kind:, binary:, cwd:, env:, initialPrompt:, hooks: ClaudeHooks.Installation?) -> AgentLaunchSpec }
public enum AgentActivity: Sendable, Equatable { case starting, running, waitingForInput, idle, exited(Int32), failed(String) }
@MainActor public final class AgentStatusTracker { // per session: feeds output timestamps, hook events and exit
    var activity: AgentActivity; var onChange: ((AgentActivity) -> Void)?
    func noteOutput(at: Date); func noteHookEvent(_ e: ClaudeHookEvent); func noteExit(_ code: Int32?); func tick(now: Date) }
public enum ClaudeHooks {
    // Writes `<dataRoot>/hooks/claude-settings.json` passed to claude via `--settings <file>` (never touches ~/.claude).
    // Hook command appends the hook JSON (stdin) as one line to "$MERCURY_HOOK_EVENTS".
    struct Installation: Sendable { settingsFile: URL; func eventsFile(sessionID: UUID) -> URL; func env(sessionID: UUID) -> EnvPatch }
    static func install(dataRoot: URL) throws -> Installation
    static func parseEvents(_ data: Data) -> [ClaudeHookEvent]
}
public struct ClaudeHookEvent: Sendable { name: String /* Notification, Stop, UserPromptSubmit, ... */, message: String? }
public final class HookEventWatcher  // DispatchSource on an events file, emits new ClaudeHookEvent lines
```

## MercuryAccounts

```swift
public struct AccountIdentity: Sendable, Hashable { email: String?, organization: String?, accountID: String? }
public struct UsageWindow: Sendable, Hashable { usedFraction: Double /* 0...1 */, resetsAt: Date? }
public struct UsageSnapshot: Sendable, Hashable { fiveHour: UsageWindow?, sevenDay: UsageWindow?, fetchedAt: Date }
public protocol LoginSession: AnyObject, Sendable { var output: AsyncStream<String> { get }  // lines; URLs detected by UI
                                                    func wait() async throws -> Void; func cancel() }
public protocol ManagedAccountProvider: Sendable {
    var provider: AccountProvider { get }
    func createHome(accountID: UUID) throws -> URL        // safe dir, 700, owner marker after successful setup
    func prepareForLaunch(home: URL) async throws          // Claude: provisioning sync; Codex: config mirror
    func startLogin(home: URL) throws -> LoginSession      // claude auth login --claudeai / codex login (10 min timeout)
    func identity(home: URL) async -> AccountIdentity?
    func usage(home: URL) async throws -> UsageSnapshot    // failures never block launching an agent
    func launchEnv(home: URL?) -> EnvPatch                 // nil = default login; strips API key env as Orca does
    func writePointer(home: URL?) throws                   // selected-host file for the shell functions
    func removeHome(_ home: URL) async throws              // logout first, then delete
}
public struct ClaudeAccountProvider: ManagedAccountProvider { init(dataRoot: URL, realHome: URL = NSHomeDirectory) }
public struct CodexAccountProvider: ManagedAccountProvider { init(dataRoot: URL, realHome: URL = NSHomeDirectory) }
```
Layout: `<dataRoot>/claude-profiles/<uuid>/home`, `<dataRoot>/claude-profiles/selected-host`,
`<dataRoot>/codex-homes/<uuid>/home`, `<dataRoot>/codex-homes/selected-host`.

## MercuryDiff

```swift
public struct DiffDocumentView: NSViewRepresentable { init(diff: FileDiff, language: String? /* from path extension */) }
public final class DiffTextView: NSView   // TextKit 2 (or STTextView), old/new line-number gutters, add/delete backgrounds
public enum SyntaxHighlighter { static func language(forPath: String) -> String?
                                static func highlight(_ text: String, language: String) async -> [HighlightSpan] }
public struct HighlightSpan: Sendable { range: NSRange, token: TokenKind }
```
