import Foundation
import SuijinCore

/// Usage of the user's own default Claude and Codex logins (the ones `claude` / `codex` use without Suijin).
///
/// Strictly read-only: the default Keychain item, `~/.claude` (or the user's `CLAUDE_CONFIG_DIR`), `~/.claude.json`
/// and `~/.codex` (or `CODEX_HOME`) are only read, and tokens stay in memory for the one request.
public struct DefaultLoginUsageReader: Sendable {
    let realHome: URL
    let environment: [String: String]
    let keychain: ClaudeKeychainReader
    let claudeClient: ClaudeUsageClient
    let codexClient: CodexUsageClient

    /// - Parameters:
    ///   - environment: where `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `USER` are looked up.
    ///   - runner: runs `/usr/bin/security`; tests inject a fake.
    public init(
        realHome: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: any CommandRunning = ProcessCommandRunner(),
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.realHome = realHome
        self.environment = environment
        keychain = ClaudeKeychainReader(runner: runner, environment: environment)
        claudeClient = ClaudeUsageClient(transport: transport)
        codexClient = CodexUsageClient(transport: transport)
    }

    var claudeConfigDir: URL? { ClaudeKeychainReader.defaultLoginConfigDir(environment: environment, realHome: realHome) }
    var codexHome: URL { CodexIdentity.defaultLoginHome(environment: environment, realHome: realHome) }

    /// The default login's usage; nil when the provider has no subscription login there (signed out or API key),
    /// so the caller shows nothing. Request and Keychain failures throw `UsageError`.
    public func usage(_ provider: AccountProvider) async throws -> UsageSnapshot? {
        switch provider {
        case .claude:
            guard let token = try await keychain.defaultLoginAccessToken(configDir: claudeConfigDir, realHome: realHome)
            else { return nil }
            return try await claudeClient.fetch(accessToken: token)
        case .codex:
            guard let credentials = codexCredentials() else { return nil }
            return try await codexClient.fetch(accessToken: credentials.accessToken, accountID: credentials.accountID)
        }
    }

    /// Who the default login is signed in as, for labels only.
    public func identity(_ provider: AccountProvider) -> AccountIdentity? {
        switch provider {
        case .claude:
            return ClaudeStateCopy.identity(stateFile: ClaudeStateCopy.stateFile(configDir: claudeConfigDir, realHome: realHome))
        case .codex:
            guard let data = try? FileOps.readData(codexHome.appendingPathComponent("auth.json").path),
                  let parsed = CodexIdentity.parse(data), !parsed.isAPIKey
            else { return nil }
            return AccountIdentity(email: parsed.email, organization: parsed.workspaceLabel, accountID: parsed.providerAccountID)
        }
    }

    func codexCredentials() -> (accessToken: String, accountID: String?)? {
        guard let data = try? FileOps.readData(codexHome.appendingPathComponent("auth.json").path) else { return nil }
        return CodexIdentity.backendCredentials(data)
    }
}
