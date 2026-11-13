import Foundation
import SuijinAgents
import SuijinCore

/// Managed Codex accounts, one `CODEX_HOME` per account with its own `auth.json` (Orca's mechanism).
/// The user's own `~/.codex` is only ever read.
public struct CodexAccountProvider: ManagedAccountProvider {
    public let provider = AccountProvider.codex
    public let store: CodexHomeStore
    let usageClient: CodexUsageClient
    let runner: any CommandRunning
    let executable: URL?
    let environment: [String: String]
    /// Link session rollouts between `~/.codex` and account homes so `codex resume` sees every account's history.
    let shareSessions: Bool
    let deviceAuth: Bool

    public init(
        dataRoot: URL, realHome: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
        shareSessions: Bool = true, deviceAuth: Bool = false,
        runner: any CommandRunning = ProcessCommandRunner(),
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        store = CodexHomeStore(dataRoot: dataRoot, realHome: realHome)
        usageClient = CodexUsageClient(transport: transport)
        self.runner = runner
        self.executable = executable
        self.environment = environment
        self.shareSessions = shareSessions
        self.deviceAuth = deviceAuth
    }

    var mirror: CodexConfigMirror { CodexConfigMirror(store: store) }
    var resources: CodexSharedResources { CodexSharedResources(store: store) }

    /// Creates the home and seeds config before login, so forced-workspace and credential-store settings apply.
    public func createHome(accountID: UUID) throws -> URL {
        try mirror.assertOAuthAccountAllowed()
        let home = try store.create(accountID: accountID)
        try mirror.sync(home: home)
        return home
    }

    public func prepareForLaunch(home: URL) async throws {
        try store.verify(home: home)
        resources.linkResources(into: home)
        resources.syncRules(into: home)
        try mirror.sync(home: home)
        guard shareSessions else { return }
        // History scans can be large; they never delay the launch.
        let sources = sessionSources(for: home)
        let resources = resources
        Task.detached(priority: .utility) {
            _ = resources.shareSessions(into: home, from: sources)
        }
    }

    /// Links missing rollouts now; `prepareForLaunch` runs the same pass in the background.
    @discardableResult
    func shareSessionsNow(into home: URL) throws -> CodexSharedResources.LinkPass {
        try store.verify(home: home)
        return resources.shareSessions(into: home, from: sessionSources(for: home))
    }

    /// `~/.codex` first, then sibling account homes, so switching accounts never hides earlier conversations.
    private func sessionSources(for home: URL) -> [URL] {
        [store.systemHome] + store.ownedHomes().filter { $0.path != home.path }
    }

    public func startLogin(home: URL) throws -> LoginSession {
        try store.verify(home: home)
        return try CodexLoginRunner(
            executable: try codexExecutable(), baseEnvironment: environment, deviceAuth: deviceAuth
        ).start(home: home)
    }

    public func identity(home: URL) async -> AccountIdentity? {
        guard (try? store.verify(home: home)) != nil,
              let data = try? FileOps.readData(home.appendingPathComponent("auth.json").path),
              let parsed = CodexIdentity.parse(data)
        else { return nil }
        return AccountIdentity(
            email: parsed.email, organization: parsed.workspaceLabel, accountID: parsed.providerAccountID)
    }

    public func usage(home: URL) async throws -> UsageSnapshot {
        try store.verify(home: home)
        guard let data = try? FileOps.readData(home.appendingPathComponent("auth.json").path),
              let credentials = CodexIdentity.backendCredentials(data)
        else { throw UsageError.notSignedIn }
        return try await usageClient.fetch(accessToken: credentials.accessToken, accountID: credentials.accountID)
    }

    public func launchEnv(home: URL?) -> EnvPatch {
        CodexLaunchEnv.patch(home: home, inheritedEnv: environment)
    }

    public func writePointer(home: URL?) throws {
        if let home { try store.verify(home: home) }
        try PointerFile.write(home: home, to: store.pointerFile)
    }

    /// `codex logout` inside the home (best effort), then the account folder.
    public func removeHome(_ home: URL) async throws {
        try store.verify(home: home)
        if let executable = try? codexExecutable(),
           (try? FileOps.lstatKind(home.appendingPathComponent("auth.json").path)) == .file {
            let env = CodexLoginRunner(executable: executable, baseEnvironment: environment).environment(home: home)
            _ = try? await runner.run(executable, ["logout"], environment: env, timeout: 30)
        }
        try store.remove(home: home)
        if (try? FileOps.readData(store.pointerFile.path)) == Data(home.path.utf8) {
            try PointerFile.write(home: nil, to: store.pointerFile)
        }
    }

    func codexExecutable() throws -> URL {
        if let executable { return executable }
        guard let found = CLIEnvironment.locate("codex", realHome: store.realHome, environment: environment) else {
            throw AccountsError.executableNotFound("codex")
        }
        return found
    }
}
