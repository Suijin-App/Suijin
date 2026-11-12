import Foundation
import MercuryAgents
import MercuryCore

/// Managed Claude Code accounts, one `CLAUDE_CONFIG_DIR` profile per account (Orca's mechanism).
/// The user's own `~/.claude`, `~/.claude.json` and default Keychain item are only ever read.
public struct ClaudeAccountProvider: ManagedAccountProvider {
    public let provider = AccountProvider.claude
    public let store: ClaudeProfileStore
    let keychain: ClaudeKeychainReader
    let usageClient: ClaudeUsageClient
    let runner: any CommandRunning
    let executable: URL?
    let environment: [String: String]

    /// - Parameters:
    ///   - userConfigDir: the user's own `CLAUDE_CONFIG_DIR` (from the login shell), if any.
    ///   - executable: the `claude` binary; located on PATH and the usual install folders when nil.
    ///   - environment: base environment for the CLI processes and the launch patch.
    ///   - runner: runs `security` and `claude auth logout`; tests inject a fake.
    public init(
        dataRoot: URL, realHome: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), userConfigDir: URL? = nil, executable: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: any CommandRunning = ProcessCommandRunner(),
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        store = ClaudeProfileStore(dataRoot: dataRoot, realHome: realHome, userConfigDir: userConfigDir)
        keychain = ClaudeKeychainReader(runner: runner, environment: environment)
        usageClient = ClaudeUsageClient(transport: transport)
        self.runner = runner
        self.executable = executable
        self.environment = environment
    }

    var provisioner: ClaudeProfileProvisioner { ClaudeProfileProvisioner(store: store) }

    /// Full setup: ownership checks, home (700), sharing, then the setup marker last so an interrupted setup reruns.
    @discardableResult
    public func setUpProfile(accountID: UUID) throws -> (home: URL, report: ProvisionReport) {
        let (home, markSetUp) = try store.prepareDirectory(accountID: accountID)
        let report = provisioner.provision(profileHome: home)
        try markSetUp()
        return (home, report)
    }

    public func createHome(accountID: UUID) throws -> URL {
        try setUpProfile(accountID: accountID).home
    }

    /// First use requires a complete setup; later launches refresh sharing, whose per-entry failures never block.
    public func prepareForLaunch(home: URL) async throws {
        try store.validate(home: home)
        guard let id = store.accountID(forHome: home) else { throw AccountsError.unsafePath(home.path) }
        if store.isSetUp(home: home) {
            _ = provisioner.provision(profileHome: home)
        } else {
            try setUpProfile(accountID: id)
        }
    }

    public func startLogin(home: URL) throws -> LoginSession {
        try store.validate(home: home)
        guard store.isSetUp(home: home) else { throw AccountsError.notOwned("Claude profile is not set up") }
        return try ClaudeLoginRunner(executable: try claudeExecutable(), baseEnvironment: environment).start(home: home)
    }

    public func identity(home: URL) async -> AccountIdentity? {
        guard (try? store.validate(home: home)) != nil else { return nil }
        return ClaudeStateCopy.identity(stateFile: ClaudeStateCopy.stateFile(configDir: home, realHome: store.realHome))
    }

    public func usage(home: URL) async throws -> UsageSnapshot {
        try store.validate(home: home)
        guard let token = try await keychain.accessToken(configDir: home) else { throw UsageError.notSignedIn }
        return try await usageClient.fetch(accessToken: token)
    }

    public func launchEnv(home: URL?) -> EnvPatch {
        ClaudeLaunchEnv.patch(home: home, inheritedEnv: environment)
    }

    public func writePointer(home: URL?) throws {
        if let home { try store.validate(home: home) }
        try PointerFile.write(home: home, to: store.pointerFile)
    }

    /// `claude auth logout` inside the profile (best effort), then the profile's own Keychain items, then the folder.
    public func removeHome(_ home: URL) async throws {
        try store.validate(home: home)
        if let executable = try? claudeExecutable(), (try? FileOps.lstatKind(home.path)) == .directory {
            let env = ClaudeLoginRunner(executable: executable, baseEnvironment: environment).environment(home: home)
            _ = try? await runner.run(executable, ["auth", "logout"], environment: env, timeout: 30)
        }
        await keychain.deleteItems(configDir: home.path, userHome: store.realHome.path)
        try store.removeProfile(home: home)
        if (try? FileOps.readData(store.pointerFile.path)) == Data(home.path.utf8) {
            try PointerFile.write(home: nil, to: store.pointerFile)
        }
    }

    func claudeExecutable() throws -> URL {
        if let executable { return executable }
        guard let found = CLIEnvironment.locate("claude", realHome: store.realHome, environment: environment) else {
            throw AccountsError.executableNotFound("claude")
        }
        return found
    }
}
