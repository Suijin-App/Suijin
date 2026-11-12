import Foundation
import MercuryAccounts
import MercuryAgents
import MercuryCore
import Observation

/// Managed accounts at runtime: the two providers, usage of the managed accounts and of the user's own default
/// logins (polled with backoff), and the pointer files the terminal shell functions read. Usage errors are kept
/// quiet; they never block an agent.
@Observable
@MainActor
final class AccountsController {
    @ObservationIgnored private unowned let model: AppModel
    private(set) var usage: [UUID: UsageSnapshot] = [:]
    /// The last usage failure of each managed account; cleared by the next success.
    private(set) var usageFailures: [UUID: UsageFailure] = [:]
    /// Usage of the user's own login for providers without a managed default account. No entry = that login is
    /// signed out (or uses an API key), so the status bar shows nothing for it.
    private(set) var defaultLoginUsage: [AccountProvider: ProviderUsageState] = [:]
    /// True while any usage refresh runs.
    var isRefreshingUsage: Bool { refreshesInFlight > 0 }
    private var refreshesInFlight = 0
    /// Reads the default logins read-only; tokens never leave the request.
    @ObservationIgnored private let defaultLoginReader = DefaultLoginUsageReader()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var providers: [AccountProvider: any ManagedAccountProvider] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func provider(_ kind: AccountProvider) async -> any ManagedAccountProvider {
        if let existing = providers[kind] { return existing }
        let path = await AgentCatalog.loginShellPATH()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        let made: any ManagedAccountProvider = switch kind {
        case .claude:
            ClaudeAccountProvider(dataRoot: model.dataRoot, executable: AgentCatalog.resolveBinary(.claude, path: path),
                                  environment: environment)
        case .codex:
            CodexAccountProvider(dataRoot: model.dataRoot, executable: AgentCatalog.resolveBinary(.codex, path: path),
                                 environment: environment)
        }
        providers[kind] = made
        return made
    }

    /// The environment changes for a session of `kind` with `accountID` (nil = the provider's default account),
    /// after re-provisioning the account home so it sees the latest `~/.claude` / `~/.codex` content.
    func launchEnv(for kind: AgentKind, accountID: UUID?) async -> EnvPatch {
        guard let providerKind = kind.accountProvider else { return .empty }
        let provider = await provider(providerKind)
        let account = accountID.flatMap { id in model.accounts.first { $0.id == id } } ?? model.defaultAccount(for: providerKind)
        guard let account else { return provider.launchEnv(home: nil) }
        let home = URL(fileURLWithPath: account.homePath, isDirectory: true)
        try? await provider.prepareForLaunch(home: home)
        return provider.launchEnv(home: home)
    }

    /// Makes `accountID` (nil = the user's own login) the default for new sessions and for `claude`/`codex` typed in
    /// Mercury terminals.
    func setDefault(_ accountID: UUID?, for kind: AccountProvider) async {
        let key: SettingKey = kind == .claude ? .defaultClaudeAccount : .defaultCodexAccount
        model.setSetting(key, accountID?.uuidString)
        await writePointers()
        await refreshUsage()
    }

    /// Homes left by a first sign-in that never finished (the app quit while the sign-in sheet was open) have no
    /// record; they are signed out and deleted at launch.
    func removeAbandonedHomes() async {
        let folders: [AccountProvider: String] = [.claude: "claude-profiles", .codex: "codex-homes"]
        for (kind, folder) in folders {
            let parent = model.dataRoot.appendingPathComponent(folder, isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            let known = Set(model.accounts.map { URL(fileURLWithPath: $0.homePath).standardizedFileURL.path })
            for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
                let home = entry.appendingPathComponent("home", isDirectory: true)
                guard !known.contains(home.standardizedFileURL.path) else { continue }
                try? await provider(kind).removeHome(home)
            }
        }
    }

    func writePointers() async {
        for kind in AccountProvider.allCases {
            let provider = await provider(kind)
            let home = model.defaultAccount(for: kind).map { URL(fileURLWithPath: $0.homePath, isDirectory: true) }
            try? provider.writePointer(home: home)
        }
    }

    // MARK: Usage

    func startPolling() {
        pollTask?.cancel()
        #if DEBUG
        // `-MercuryPreviewUsage 1` (or `failed`) shows sample usage for screenshots, without any network request.
        if let preview = UserDefaults.standard.string(forKey: "MercuryPreviewUsage") {
            fillPreviewUsage(failedCodex: preview == "failed")
            return
        }
        #endif
        pollTask = Task { [weak self] in
            var delay: Duration = .seconds(300)
            while !Task.isCancelled {
                let ok = await self?.refreshUsage() ?? false
                delay = ok ? .seconds(300) : min(delay * 2, .seconds(1800))
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// What the status bar shows for `kind`: the managed default account's usage when one is selected, else the
    /// user's own login's; nil when neither is signed in.
    func statusUsage(for kind: AccountProvider) -> ProviderUsageState? {
        guard let account = model.defaultAccount(for: kind) else { return defaultLoginUsage[kind] }
        return ProviderUsageState(
            snapshot: usage[account.id], failure: usageFailures[account.id], accountName: account.displayName, isManaged: true)
    }

    /// The refresh button: fetches now, even while a server-requested wait is pending.
    func refreshUsageNow() async {
        await refreshUsage(manual: true)
    }

    /// Fetches usage of every managed account and of the default login of each provider that has no managed
    /// default; returns false when any request failed. Automated refreshes honor a pending `Retry-After`.
    @discardableResult
    func refreshUsage(manual: Bool = false) async -> Bool {
        refreshesInFlight += 1
        defer { refreshesInFlight -= 1 }
        var allOK = true
        for account in model.accounts {
            if !manual, let retryAt = usageFailures[account.id]?.retryAt, retryAt > .now { continue }
            let provider = await provider(account.provider)
            do {
                usage[account.id] = try await provider.usage(home: URL(fileURLWithPath: account.homePath, isDirectory: true))
                usageFailures[account.id] = nil
            } catch {
                usageFailures[account.id] = UsageFailure(error, provider: account.provider)
                allOK = false
            }
        }
        for kind in AccountProvider.allCases {
            guard model.defaultAccount(for: kind) == nil else {
                defaultLoginUsage[kind] = nil
                continue
            }
            if !manual, let retryAt = defaultLoginUsage[kind]?.failure?.retryAt, retryAt > .now { continue }
            if await !refreshDefaultLogin(kind) { allOK = false }
        }
        return allOK
    }

    /// One provider's default login. A failure keeps recent usage on screen (Orca's stale policy).
    private func refreshDefaultLogin(_ kind: AccountProvider) async -> Bool {
        let reader = defaultLoginReader
        let accountName = reader.identity(kind)?.email
        do {
            guard let snapshot = try await reader.usage(kind) else {
                defaultLoginUsage[kind] = nil
                return true
            }
            defaultLoginUsage[kind] = ProviderUsageState(
                snapshot: snapshot, failure: nil, accountName: accountName, isManaged: false)
            return true
        } catch {
            let failure = UsageFailure(error, provider: kind)
            defaultLoginUsage[kind] = ProviderUsageState(
                snapshot: ProviderUsagePolicy.retained(defaultLoginUsage[kind]?.snapshot, after: failure),
                failure: failure, accountName: accountName, isManaged: false)
            return false
        }
    }

    #if DEBUG
    /// Screenshot tests show usage without a network request.
    func setUsageForPreview(_ id: UUID, _ snapshot: UsageSnapshot) {
        usage[id] = snapshot
    }

    /// Sample default-login usage for both providers; `failedCodex` shows Codex in its failed state instead.
    func fillPreviewUsage(failedCodex: Bool = false, now: Date = .now) {
        let claude = UsageSnapshot(
            fiveHour: UsageWindow(usedFraction: 0.42, resetsAt: now.addingTimeInterval(3 * 3600 + 20 * 60)),
            sevenDay: UsageWindow(usedFraction: 0.87, resetsAt: now.addingTimeInterval(5 * 86400 + 12 * 3600 + 120)),
            modelWeekly: ModelUsageWindow(
                model: "Fable", window: UsageWindow(usedFraction: 0.14, resetsAt: now.addingTimeInterval(5 * 86400 + 12 * 3600))),
            fetchedAt: now)
        defaultLoginUsage[.claude] = ProviderUsageState(
            snapshot: claude, failure: nil, accountName: "preview@example.com", isManaged: false)
        let codex = UsageSnapshot(
            fiveHour: UsageWindow(usedFraction: 0.08, resetsAt: now.addingTimeInterval(4 * 3600 + 5 * 60)),
            sevenDay: UsageWindow(usedFraction: 0.31, resetsAt: now.addingTimeInterval(2 * 86400 + 3 * 3600 + 120)),
            fetchedAt: now)
        defaultLoginUsage[.codex] = failedCodex
            ? ProviderUsageState(snapshot: nil, failure: .failed, accountName: "preview@example.com", isManaged: false)
            : ProviderUsageState(snapshot: codex, failure: nil, accountName: "preview@example.com", isManaged: false)
    }
    #endif

    // MARK: Adding and removing

    /// Creates the home of a new account and starts the CLI login in it. The record is saved by `finishLogin`.
    func beginAdding(_ kind: AccountProvider) async throws -> PendingLogin {
        let provider = await provider(kind)
        let id = UUID()
        let home = try provider.createHome(accountID: id)
        let session = try provider.startLogin(home: home)
        return PendingLogin(id: id, provider: kind, home: home, session: session)
    }

    /// Re-runs the login of an existing account whose credentials expired.
    func beginRelogin(_ account: ManagedAccountRecord) async throws -> PendingLogin {
        let provider = await provider(account.provider)
        let home = URL(fileURLWithPath: account.homePath, isDirectory: true)
        let session = try provider.startLogin(home: home)
        return PendingLogin(id: account.id, provider: account.provider, home: home, session: session)
    }

    /// Saves the account once its login succeeded, with the identity the CLI stored.
    func finishLogin(_ pending: PendingLogin) async {
        let provider = await provider(pending.provider)
        let identity = await provider.identity(home: pending.home)
        var record = model.accounts.first { $0.id == pending.id }
            ?? ManagedAccountRecord(id: pending.id, provider: pending.provider,
                                    label: pending.provider == .claude ? "Claude" : "Codex", homePath: pending.home.path)
        record.email = identity?.email ?? record.email
        record.organization = identity?.organization ?? record.organization
        await model.upsert(record)
        await refreshUsage()
    }

    /// A cancelled first login leaves no account behind.
    func abandon(_ pending: PendingLogin) async {
        pending.session.cancel()
        guard !model.accounts.contains(where: { $0.id == pending.id }) else { return }
        let provider = await provider(pending.provider)
        try? await provider.removeHome(pending.home)
    }

    /// Stops the sessions using the account, signs it out, deletes its home and forgets it.
    func remove(_ account: ManagedAccountRecord) async {
        for session in model.sessions where session.accountID == account.id { await model.closeSession(session.id) }
        let provider = await provider(account.provider)
        await model.perform(String(localized: "Could not remove the account")) {
            try await provider.removeHome(URL(fileURLWithPath: account.homePath, isDirectory: true))
        }
        if model.defaultAccount(for: account.provider)?.id == account.id {
            await setDefault(nil, for: account.provider)
        }
        usage[account.id] = nil
        usageFailures[account.id] = nil
        await model.deleteAccountRecord(account.id)
    }
}

/// A login in progress for a new or existing account.
struct PendingLogin: Identifiable {
    let id: UUID
    let provider: AccountProvider
    let home: URL
    let session: any LoginSession
}
