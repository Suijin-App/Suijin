import Foundation
import SuijinAccounts
import SuijinCore

/// The account an agent session uses, as its tab, sidebar row and the status bar describe it.
///
/// A managed account is fixed for the life of the session: it runs in that account's own `CLAUDE_CONFIG_DIR` or
/// `CODEX_HOME`. A session on the user's own login shares `~/.claude` / `~/.codex` with every other `claude` or `codex`,
/// so signing in to another account there reaches it: Claude picks up the new login while it runs; Codex keeps the
/// account it started with until it has to sign in again.
struct SessionAccount: Equatable {
    let provider: AccountProvider
    /// The managed account's id; nil for the user's own login.
    let managedID: UUID?
    /// The email (or label) the session uses now; nil when the own login's email is not known.
    let name: String?
    /// Own login only, when the login changed while the session ran: who is signed in now and who the session started as.
    let signedInNow: String?
    let startedAs: String?

    var isManaged: Bool { managedID != nil }

    /// Resolves `session`'s account: its managed account, or the own login signed in now (`defaultLogin`) compared with
    /// the one it started with (`launchLogin`, known only for sessions started since the app launched). Nil for a shell.
    static func resolve(session: AgentSessionRecord, accounts: [ManagedAccountRecord], defaultLogin: String?,
                        launchLogin: String?) -> SessionAccount? {
        guard let provider = session.agent.accountProvider else { return nil }
        if let id = session.accountID, let account = accounts.first(where: { $0.id == id }) {
            return SessionAccount(provider: provider, managedID: id, name: account.displayName, signedInNow: nil, startedAs: nil)
        }
        guard let launchLogin, let defaultLogin, !Self.same(launchLogin, defaultLogin) else {
            return SessionAccount(provider: provider, managedID: nil, name: defaultLogin ?? launchLogin,
                                  signedInNow: nil, startedAs: nil)
        }
        // Claude reloads a login changed on disk; Codex refuses to reload another account's credentials.
        let current = provider == .claude ? defaultLogin : launchLogin
        return SessionAccount(provider: provider, managedID: nil, name: current, signedInNow: defaultLogin, startedAs: launchLogin)
    }

    static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        lhs?.lowercased() == rhs?.lowercased()
    }

    /// "someone@example.com · Suijin account" or "· Your own login".
    var line: String {
        let source = isManaged ? String(localized: "Suijin account") : String(localized: "Your own login")
        guard let name, !name.isEmpty else { return source }
        return "\(name) · \(source)"
    }

    /// Why the own login shown may not be the one the session started with.
    var hint: String? {
        guard let signedInNow, let startedAs else { return nil }
        return switch provider {
        case .claude: String(localized: "Signed in as \(signedInNow) now; this session started as \(startedAs).")
        case .codex: String(localized: "Signed in as \(signedInNow) now; this session started as \(startedAs) and keeps it until Codex asks to sign in again.")
        }
    }

    /// The tooltip of a session's tab or row: its title, then the account.
    func tooltip(title: String) -> String {
        ([title, line] + [hint].compactMap(\.self)).joined(separator: "\n")
    }

    /// The tab title of an own-login session with the email signed in now ("Claude" becomes "Claude · someone@example.com").
    /// Any other title is kept: a managed session's already names its account, and a worker's names its task.
    func title(stored: String, agentName: String) -> String {
        guard !isManaged, let name, !name.isEmpty, stored == agentName else { return stored }
        return "\(agentName) · \(name)"
    }
}

extension AgentKind {
    /// The name a new session of this agent is titled with.
    var sessionTitle: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .shell: String(localized: "Shell")
        }
    }
}

extension AppModel {
    /// The account `session` uses now, resolved live: observing views update when an account is renamed or the
    /// user's own login changes.
    func sessionAccount(of session: AgentSessionRecord) -> SessionAccount? {
        guard let provider = session.agent.accountProvider else { return nil }
        return SessionAccount.resolve(session: session, accounts: accounts,
                                      defaultLogin: accountsController.defaultLoginEmail[provider],
                                      launchLogin: runtimes.launchLogins[session.id])
    }

    /// The tooltip of a session's tab, sidebar row or pane header.
    func sessionTooltip(of session: AgentSessionRecord) -> String {
        let title = runtimes.displayTitle(of: session)
        return sessionAccount(of: session)?.tooltip(title: title) ?? title
    }

    /// The focused session of the selected tab when it runs `provider`'s agent, with its account.
    func focusedSessionAccount(for provider: AccountProvider) -> SessionAccount? {
        focusedSession(for: provider).flatMap(sessionAccount(of:))
    }
}
