import Foundation
import SuijinAccounts
import SuijinCore
import Testing
@testable import Suijin

/// Which account a session's tab, row and the status bar name: a managed account stays fixed (and follows its new email
/// when it signs in to another account), the user's own login is read live, so a `/login` elsewhere shows on the
/// sessions that use it. Logins are fake `.claude.json` / `auth.json` files in a temporary home; nothing real is read.
@MainActor
@Suite(.serialized)
struct SessionAccountTests {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-acct-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    }

    private func makeModel() async throws -> (AppModel, UUID) {
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        model.accountsController.defaultLoginReader = DefaultLoginUsageReader(realHome: home, environment: [:])
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await model.addWorkspace(at: folder)
        return (model, try #require(model.workspaces.first).id)
    }

    /// Signs the fake own Claude login in as `email`, as `/login` rewrites `~/.claude.json`.
    private func signInClaude(_ email: String) throws {
        let state = ["oauthAccount": ["emailAddress": email, "organizationName": "Org"]]
        try JSONSerialization.data(withJSONObject: state).write(to: home.appendingPathComponent(".claude.json"))
    }

    /// Signs the fake own Codex login in as `email` (an unsigned id token carries the email, as `codex login` writes).
    private func signInCodex(_ email: String) throws {
        let payload = try JSONSerialization.data(withJSONObject: ["email": email])
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let auth: [String: Any] = ["tokens": ["id_token": "e30.\(payload).sig", "access_token": "a", "refresh_token": "r"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: home.appendingPathComponent(".codex/auth.json"))
    }

    @Test func ownLoginSessionFollowsTheLoginSignedInNow() async throws {
        let (model, workspace) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = AgentSessionRecord(workspaceID: workspace, agent: .claude, title: "Claude", cwd: root.path)
        await model.upsert(session)
        #expect(model.runtimes.displayTitle(of: session) == "Claude")
        #expect(model.sessionAccount(of: session)?.line == "Your own login")

        try signInClaude("first@example.com")
        await model.accountsController.refreshIdentities()
        #expect(model.runtimes.displayTitle(of: session) == "Claude · first@example.com")
        #expect(model.sessionTooltip(of: session) == "Claude · first@example.com\nfirst@example.com · Your own login")

        // `/login` to another account: the same running session now names it, without a restart.
        try signInClaude("second@example.com")
        await model.accountsController.refreshIdentities()
        #expect(model.runtimes.displayTitle(of: session) == "Claude · second@example.com")
        #expect(model.sessionAccount(of: session)?.isManaged == false)
    }

    @Test func ownCodexLoginIsReadLiveToo() async throws {
        let (model, workspace) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = AgentSessionRecord(workspaceID: workspace, agent: .codex, title: "Codex · reviewer", cwd: root.path)
        await model.upsert(worker)
        try signInCodex("codex@example.com")
        await model.accountsController.refreshIdentities()
        // A worker's title names its task; the account is in its tooltip.
        #expect(model.runtimes.displayTitle(of: worker) == "Codex · reviewer")
        #expect(model.sessionTooltip(of: worker) == "Codex · reviewer\ncodex@example.com · Your own login")
        let plain = AgentSessionRecord(workspaceID: workspace, agent: .codex, title: "Codex", cwd: root.path)
        #expect(model.runtimes.displayTitle(of: plain) == "Codex · codex@example.com")
    }

    @Test func managedSessionKeepsItsAccountAndFollowsItsNewEmail() async throws {
        let (model, workspace) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        try signInClaude("own@example.com")
        await model.accountsController.refreshIdentities()
        var account = ManagedAccountRecord(provider: .claude, label: "Claude", email: "work@example.com", homePath: root.path)
        await model.upsert(account)
        let session = AgentSessionRecord(workspaceID: workspace, agent: .claude, accountID: account.id,
                                         title: "Claude · work@example.com · planner", cwd: root.path)
        await model.upsert(session)
        // The own login is someone else; the managed session still names its own account.
        #expect(model.runtimes.displayTitle(of: session) == "Claude · work@example.com · planner")
        #expect(model.sessionAccount(of: session)?.line == "work@example.com · Suijin account")

        // The managed home signed in to another account (a `/login` inside one of its sessions).
        account.email = "new-work@example.com"
        await model.upsert(account)
        let renamed = try #require(model.sessions.first { $0.id == session.id })
        #expect(renamed.title == "Claude · new-work@example.com · planner")
        #expect(model.sessionAccount(of: renamed)?.name == "new-work@example.com")
    }

    @Test func aLoginChangedSinceLaunchIsExplained() {
        let session = AgentSessionRecord(workspaceID: UUID(), agent: .claude, title: "Claude", cwd: "/")
        let claude = SessionAccount.resolve(session: session, accounts: [], defaultLogin: "b@example.com",
                                            launchLogin: "a@example.com")
        #expect(claude?.name == "b@example.com")
        #expect(claude?.hint == "Signed in as b@example.com now; this session started as a@example.com.")
        // Codex refuses to reload another account's credentials, so the session still runs as the first one.
        let codexSession = AgentSessionRecord(workspaceID: UUID(), agent: .codex, title: "Codex", cwd: "/")
        let codex = SessionAccount.resolve(session: codexSession, accounts: [], defaultLogin: "b@example.com",
                                           launchLogin: "a@example.com")
        #expect(codex?.name == "a@example.com")
        #expect(codex?.hint?.contains("keeps it") == true)
        let unchanged = SessionAccount.resolve(session: session, accounts: [], defaultLogin: "A@example.com",
                                               launchLogin: "a@example.com")
        #expect(unchanged?.hint == nil)
        #expect(SessionAccount.resolve(session: AgentSessionRecord(workspaceID: UUID(), agent: .shell, title: "Shell", cwd: "/"),
                                       accounts: [], defaultLogin: "b@example.com", launchLogin: nil) == nil)
    }

    @Test func statusBarSaysWhenTheFocusedSessionUsesAnotherAccount() throws {
        let now = Date()
        let own = ProviderUsageState(snapshot: nil, failure: nil, accountName: "own@example.com", isManaged: false)
        let managedID = UUID()
        let managed = SessionAccount(provider: .claude, managedID: managedID, name: "work@example.com",
                                     signedInNow: nil, startedAs: nil)
        let usage = UsageSnapshot(fiveHour: UsageWindow(usedFraction: 0.42, resetsAt: now.addingTimeInterval(3 * 3600 + 90)), sevenDay: nil,
                                  fetchedAt: now)
        let note = try #require(UsageDescription.sessionNote(managed, state: own, usage: usage, now: now))
        #expect(note == "This session uses work@example.com · Suijin account (42% used 3h 1m). The bar shows the account new sessions use.")
        #expect(UsageDescription.tooltip(provider: .claude, state: own, sections: [], sessionNote: note, now: now)
            == "Claude — own@example.com · Your own login\n\(note)")

        // The bar already shows the session's account: nothing to add.
        let shown = ProviderUsageState(snapshot: nil, failure: nil, accountName: "work@example.com", isManaged: true, managedID: managedID)
        #expect(UsageDescription.sessionNote(managed, state: shown, usage: usage, now: now) == nil)
        let ownSession = SessionAccount(provider: .claude, managedID: nil, name: "own@example.com", signedInNow: nil, startedAs: nil)
        #expect(UsageDescription.sessionNote(ownSession, state: own, usage: nil, now: now) == nil)
        #expect(UsageDescription.sessionNote(ownSession, state: shown, usage: nil, now: now)
            == "This session uses own@example.com · Your own login. The bar shows the account new sessions use.")
        #expect(UsageDescription.sessionNote(nil, state: own, usage: nil, now: now) == nil)
    }
}
