import AppKit
import Foundation
import SevindaAgents
import SevindaCore
import SevindaGit
import Observation
import os

private let statsLogger = Logger(subsystem: "com.tekmium.mercury", category: "stats")

/// Source control state of every git context, kept for the app's lifetime so a draft commit message survives the
/// inspector closing or another worktree being selected. One store per `AppModel`.
@MainActor
final class SourceControlStore {
    private static var stores: [ObjectIdentifier: SourceControlStore] = [:]

    static func shared(for model: AppModel) -> SourceControlStore {
        let key = ObjectIdentifier(model)
        if let store = stores[key] { return store }
        let store = SourceControlStore(model: model)
        stores[key] = store
        return store
    }

    private unowned let model: AppModel
    private var states: [SessionContext: SourceControlState] = [:]
    /// `gh` on the login shell `PATH`, looked up once.
    private var ghLookup: Task<URL?, Never>?

    private init(model: AppModel) {
        self.model = model
    }

    func state(for context: SessionContext) -> SourceControlState {
        if let state = states[context] { return state }
        let state = SourceControlState(context: context, model: model, store: self)
        states[context] = state
        return state
    }

    func gitHubCLI() async -> GitHubCLI? {
        #if DEBUG
        // Screenshot runs point at a fake `gh` (`MERCURY_GH_PATH`), so no real GitHub repository is involved.
        if let path = ProcessInfo.processInfo.environment["MERCURY_GH_PATH"] {
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return GitHubCLI(executable: URL(fileURLWithPath: path))
        }
        #endif
        let lookup = ghLookup ?? Task {
            GitHubCLI.locate(path: await AgentCatalog.loginShellPATH())
        }
        ghLookup = lookup
        guard let executable = await lookup.value else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = await AgentCatalog.loginShellPATH()
        return GitHubCLI(executable: executable, environment: environment)
    }

    /// Looks for `gh` again (after the user installed it) and forgets cached sign-in states.
    func forgetGitHubCLI() {
        ghLookup = nil
        authCache = [:]
    }

    /// `gh auth status` per host, kept five minutes: every worktree of a repository asks for the same host.
    private var authCache: [String: (status: GitHubAuthStatus, at: Date)] = [:]

    func authStatus(_ cli: GitHubCLI, host: String) async throws -> GitHubAuthStatus {
        if let cached = authCache[host], Date().timeIntervalSince(cached.at) < 300 { return cached.status }
        let status = try await cli.authStatus(host: host)
        authCache[host] = (status, Date())
        return status
    }
}

/// Where a source control action started, so its failure sheet is presented by that view.
enum SourceControlSurface: Hashable {
    case inspector, toolbar
}

/// What the app knows about pull requests for a context's branch.
enum PullRequestAvailability: Equatable {
    case unknown
    case checking
    /// `gh` is not on the login shell `PATH`.
    case ghMissing
    case notLoggedIn(host: String)
    /// The push remote is not on GitHub (or there is none).
    case notGitHub(remoteURL: String?)
    /// HEAD is detached: there is no branch to open a pull request for.
    case noBranch
    case ready(PullRequest?)
    case failed(String)
}

/// A git failure whose full output the user should read (hook report, rejected push).
struct GitOutputReport: Identifiable {
    let id = UUID()
    let title: String
    let output: String
    let surface: SourceControlSurface
}

/// Source control of one git context: status, staging, the commit message being written, push, and the branch's pull
/// request with its checks.
@Observable
@MainActor
final class SourceControlState {
    let context: SessionContext
    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private unowned let store: SourceControlStore

    private(set) var status: RepositoryStatus?
    private(set) var statusError: String?
    var draftMessage = ""
    private(set) var isGenerating = false
    private(set) var generationError: String?
    private(set) var isCommitting = false
    private(set) var isPushing = false
    /// Paths being staged or unstaged right now, so their checkboxes do not flicker.
    private(set) var pendingPaths: Set<String> = []
    /// The latest failure with git's full output; shown in a sheet that leaves the draft alone.
    var outputReport: GitOutputReport?
    /// A short confirmation after a commit or push.
    private(set) var lastSuccess: String?

    private(set) var pullRequest: PullRequestAvailability = .unknown
    private(set) var checks: [PullRequestCheck] = []
    private(set) var checksError: String?
    private(set) var pullRequestCheckedAt: Date?
    var isCreatingPullRequest = false
    /// The view presenting the Create Pull Request sheet, if it is open.
    var createPullRequestSurface: SourceControlSurface?

    @ObservationIgnored private var generation: Task<Void, Never>?
    /// Identifies the latest generation, so a cancelled one finishing late does not reset the state of the next.
    @ObservationIgnored private var generationToken = UUID()
    @ObservationIgnored private var isRefreshingStatus = false
    @ObservationIgnored private var isRefreshingPullRequest = false

    init(context: SessionContext, model: AppModel, store: SourceControlStore) {
        self.context = context
        self.model = model
        self.store = store
    }

    var directory: URL? { model.directory(of: context) }

    /// The main checkout has no Worktree section naming its branch; a worktree shows it there unless HEAD is detached.
    var showsBranchRow: Bool {
        if case .workspace = context { return true }
        return status?.branch == nil
    }
    private var service: SourceControlService? { directory.map { SourceControlService(worktree: $0) } }

    // MARK: Status

    func refreshStatus() async {
        guard let service, !isRefreshingStatus else { return }
        isRefreshingStatus = true
        defer { isRefreshingStatus = false }
        do {
            let fresh = try await service.status()
            if fresh != status { status = fresh }
            if statusError != nil { statusError = nil }
        } catch {
            statusError = (error as? GitError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription
        }
    }

    func setStaged(_ entries: [StatusEntry], staged: Bool, from surface: SourceControlSurface) async {
        guard let service, !entries.isEmpty else { return }
        var paths = entries.map(\.path)
        if !staged { paths += entries.compactMap(\.originalPath) }
        pendingPaths.formUnion(entries.map(\.path))
        defer { pendingPaths.subtract(entries.map(\.path)) }
        do {
            if staged { try await service.stage(paths) } else { try await service.unstage(paths) }
        } catch {
            report(staged ? String(localized: "Could not stage the files") : String(localized: "Could not unstage the files"), error,
                   surface)
        }
        await refreshStatus()
    }

    // MARK: Commit

    var canCommit: Bool {
        !(status?.staged.isEmpty ?? true) && !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCommitting && (status?.conflicted.isEmpty ?? true)
    }

    func commit(from surface: SourceControlSurface) async {
        guard let service, canCommit else { return }
        isCommitting = true
        lastSuccess = nil
        defer { isCommitting = false }
        do {
            let result = try await service.commit(message: draftMessage)
            draftMessage = ""
            lastSuccess = String(localized: "Committed “\(result.summary)”")
        } catch {
            // The draft stays as it is, so fixing the hook's complaint and committing again needs no retyping.
            report(String(localized: "Commit failed"), error, surface)
        }
        await refreshStatus()
    }

    // MARK: Generation

    /// The agent that writes commit and pull request text by default: the app's default agent.
    var defaultGenerator: AgentKind {
        let agent = model.defaultAgent
        return agent == .shell ? .claude : agent
    }

    /// Writes a commit message for the staged changes with `agent`, read-only, with the context's account.
    func generateCommitMessage(with agent: AgentKind) {
        guard let service, !isGenerating else { return }
        generate(with: agent) {
            let diff = try await service.stagedDiff()
            guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SourceControlMessage(String(localized: "Stage some changes first; the message is written from the staged diff."))
            }
            let subjects = try await service.recentCommitSubjects(limit: 10)
            return CommitMessagePrompt.make(stagedDiff: diff, recentSubjects: subjects)
        } apply: { [weak self] text in
            self?.draftMessage = text
        }
    }

    /// Runs one headless generation; `prompt` builds the prompt, `apply` receives the answer.
    func generate(with agent: AgentKind, prompt: @escaping @MainActor () async throws -> String,
                  apply: @escaping @MainActor (String) -> Void) {
        generation?.cancel()
        let token = UUID()
        generationToken = token
        isGenerating = true
        generationError = nil
        generation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generationToken == token { self.isGenerating = false } }
            do {
                let request = try await self.headlessRequest(agent: agent, prompt: try await prompt())
                let text = try await HeadlessTextGenerator.generate(request)
                guard !Task.isCancelled else { return }
                apply(text)
            } catch HeadlessGenerationError.cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.generationError = Self.describe(error, agent: agent)
            }
        }
    }

    func cancelGeneration() {
        generationToken = UUID()
        generation?.cancel()
        generation = nil
        isGenerating = false
    }

    func clearGenerationError() { generationError = nil }

    private func headlessRequest(agent: AgentKind, prompt: String) async throws -> HeadlessGenerationRequest {
        guard let directory else { throw SourceControlMessage(String(localized: "The folder is missing.")) }
        let path = await AgentCatalog.loginShellPATH()
        guard let binary = AgentCatalog.resolveBinary(agent, path: path) else {
            let name = AgentCatalog.definition(for: agent)?.binaryName ?? agent.rawValue
            throw SourceControlMessage(String(localized: "“\(name)” was not found on your PATH. Install it, then try again."))
        }
        // The account of the context's latest session of this agent, else the provider's default account.
        let accountID = model.sessions(in: context).last { $0.agent == agent }?.accountID
        let patch = await model.accountsController.launchEnv(for: agent, accountID: accountID)
            .merging(EnvPatch(set: ["PATH": path]))
        return HeadlessGenerationRequest(
            agent: agent, binary: binary, workingDirectory: directory,
            environment: patch.applied(to: ProcessInfo.processInfo.environment), prompt: prompt,
            codexNoDaemon: model.setting(.codexNoDaemon) == "true")
    }

    private static func describe(_ error: any Error, agent: AgentKind) -> String {
        let name = AgentCatalog.definition(for: agent)?.displayName ?? agent.rawValue
        switch error {
        case let message as SourceControlMessage: return message.text
        case let error as HeadlessGenerationError:
            switch error {
            case .timedOut: return String(localized: "\(name) did not answer within 3 minutes. Write the text yourself or try again.")
            case .emptyOutput: return String(localized: "\(name) returned no text.")
            case .launchFailed(let detail): return String(localized: "\(name) could not be started: \(detail)")
            case .failed(let code, let output):
                return output.isEmpty ? String(localized: "\(name) failed with exit code \(code).")
                    : String(localized: "\(name) failed: \(output)")
            case .unsupportedAgent, .cancelled: return error.localizedDescription
            }
        case let error as GitError: return error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return error.localizedDescription
        }
    }

    // MARK: Push

    func push(from surface: SourceControlSurface) async {
        do { try await performPush() } catch {
            report(String(localized: "Push failed"), error, surface)
        }
    }

    private func performPush() async throws {
        guard let service, !isPushing else { return }
        isPushing = true
        lastSuccess = nil
        defer { isPushing = false }
        do {
            let result = try await service.push()
            lastSuccess = result.setUpstream ? String(localized: "Published the branch to \(result.remote ?? "origin")")
                : String(localized: "Pushed")
            await refreshStatus()
        } catch {
            await refreshStatus()
            throw error
        }
    }

    /// Pushes when the branch has no upstream yet or has commits the upstream lacks. Throws git's output when the
    /// push fails.
    private func pushIfNeeded() async throws {
        await refreshStatus()
        guard let status else { throw SourceControlMessage(statusError ?? String(localized: "Could not read the branch status.")) }
        if status.upstream == nil || status.ahead > 0 { try await performPush() }
    }

    // MARK: Pull requests

    /// True when the pull request state is older than two minutes (or was never read).
    var isPullRequestStale: Bool {
        guard let checkedAt = pullRequestCheckedAt else { return true }
        return Date().timeIntervalSince(checkedAt) > 120
    }

    /// Reads the branch's pull request and its checks through `gh`. Called when the context is opened, from the
    /// Refresh button, and every two minutes for the visible context only.
    func refreshPullRequest() async {
        guard let service, !isRefreshingPullRequest else { return }
        isRefreshingPullRequest = true
        defer { isRefreshingPullRequest = false }
        if case .unknown = pullRequest { pullRequest = .checking }
        pullRequestCheckedAt = Date()

        if status == nil { await refreshStatus() }
        guard let branch = status?.branch else {
            pullRequest = .noBranch
            return
        }
        let remote = try? await service.pushRemote()
        let remoteURL: String? = if let remote { try? await service.remoteURL(remote) } else { nil }
        guard let remoteURL, let host = GitHubCLI.gitHubHost(ofRemoteURL: remoteURL) else {
            pullRequest = .notGitHub(remoteURL: remoteURL)
            return
        }
        guard let cli = await store.gitHubCLI() else {
            pullRequest = .ghMissing
            return
        }
        do {
            guard case .loggedIn = try await store.authStatus(cli, host: host) else {
                pullRequest = .notLoggedIn(host: host)
                return
            }
            let found = try await cli.pullRequest(branch: branch, in: service.worktree)
            pullRequest = .ready(found)
            if let found {
                do {
                    checks = try await cli.checks(pullRequest: found.number, in: service.worktree)
                    checksError = nil
                } catch {
                    checksError = error.localizedDescription
                }
            } else {
                checks = []
                checksError = nil
            }
        } catch {
            pullRequest = .failed(error.localizedDescription)
        }
    }

    /// Refreshes only when the state is stale, for views that appear often (sidebar badges).
    func refreshPullRequestIfStale() async {
        if isPullRequestStale { await refreshPullRequest() }
    }

    /// Looks for `gh` again and refreshes.
    func recheckGitHubCLI() async {
        store.forgetGitHubCLI()
        await refreshPullRequest()
    }

    var currentPullRequest: PullRequest? {
        if case .ready(let pr) = pullRequest { return pr }
        return nil
    }

    /// The branch a new pull request targets: the worktree's base without its remote prefix, else the repository's
    /// default branch.
    func defaultPullRequestBase() async -> String {
        if case .worktree(let id) = context, let base = model.worktree(id)?.baseBranch, !base.isEmpty, base != "HEAD" {
            return Self.stripRemote(base)
        }
        guard let id = model.workspaceID(of: context), let workspace = model.workspace(id) else { return "main" }
        let service = WorktreeService(repository: URL(fileURLWithPath: workspace.path, isDirectory: true))
        return Self.stripRemote((try? await service.defaultBaseBranch()) ?? "main")
    }

    /// Local branch names, for the base picker.
    func localBranches() async -> [String] {
        guard let id = model.workspaceID(of: context), let workspace = model.workspace(id) else { return [] }
        let service = WorktreeService(repository: URL(fileURLWithPath: workspace.path, isDirectory: true))
        return (try? await service.localBranches()) ?? []
    }

    private static func stripRemote(_ branch: String) -> String {
        for prefix in ["origin/", "upstream/"] where branch.hasPrefix(prefix) { return String(branch.dropFirst(prefix.count)) }
        return branch
    }

    /// Writes a pull request title and body for the branch against `base` with `agent`.
    func generatePullRequestText(base: String, with agent: AgentKind, apply: @escaping @MainActor (PullRequestPrompt.Draft) -> Void) {
        guard let service, let branch = status?.branch else { return }
        generate(with: agent) {
            // Compare with the remote's copy of the base when there is one: the local branch may be behind.
            let remote = (try? await service.pushRemote()) ?? nil
            var revision = base
            if let remote, await service.revisionExists("\(remote)/\(base)") { revision = "\(remote)/\(base)" }
            guard await service.revisionExists(revision) else {
                throw SourceControlMessage(String(localized: "The base branch “\(base)” does not exist."))
            }
            let commits = try await service.commitMessages(since: revision)
            let diff = try await service.diff(since: revision)
            guard !commits.isEmpty || !diff.isEmpty else {
                throw SourceControlMessage(String(localized: "“\(branch)” has no commits that “\(base)” lacks."))
            }
            return PullRequestPrompt.make(branch: branch, base: base, commits: commits, diff: diff)
        } apply: { text in
            if let draft = PullRequestPrompt.parse(text) { apply(draft) }
        }
    }

    /// Pushes if needed, then creates the pull request. Returns its URL; an existing pull request for the branch is
    /// returned instead of failing.
    func createPullRequest(title: String, body: String, base: String, draft: Bool) async throws -> URL {
        guard let service, let branch = status?.branch else { throw SourceControlMessage(String(localized: "Check out a branch first.")) }
        guard let cli = await store.gitHubCLI() else { throw SourceControlMessage(String(localized: "GitHub CLI (gh) is not installed.")) }
        isCreatingPullRequest = true
        defer { isCreatingPullRequest = false }
        do { try await pushIfNeeded() } catch {
            let output = (error as? GitError)?.stderr ?? error.localizedDescription
            throw SourceControlMessage(String(localized: "The branch could not be pushed, so the pull request was not created.\n\n\(output)"))
        }
        do {
            let url = try await cli.createPullRequest(title: title, body: body, base: base, head: branch, draft: draft,
                                                      in: service.worktree)
            await recordCreatedPullRequest(url)
            await refreshPullRequest()
            return url
        } catch let error as GitHubCLIError {
            if let existing = GitHubCLI.existingPullRequestURL(in: error) {
                await refreshPullRequest()
                return existing
            }
            throw SourceControlMessage(error.localizedDescription)
        }
    }

    /// Counts a pull request Mercury created (an already existing one is not counted). A failure to store the stat
    /// must not fail the pull request, so it is only logged.
    private func recordCreatedPullRequest(_ url: URL) async {
        let address = url.absoluteString
        do {
            _ = try await model.io { try $0.recordPullRequest(url: address, at: Date()) }
        } catch {
            statsLogger.error("Could not record the pull request stat: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens a shell tab in this context and types `gh auth login`, so signing in happens in the user's own `gh`.
    func openGitHubLogin(host: String) async {
        guard let id = await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil) else { return }
        model.selectedTab[context] = .session(id)
        let hostArgument = host == "github.com" ? "" : " --hostname \(host)"
        model.runtimes.runtime(for: id)?.terminal.send("gh auth login\(hostArgument)\n")
    }

    // MARK: Helpers

    func clearSuccess() { lastSuccess = nil }

    private func report(_ title: String, _ error: any Error, _ surface: SourceControlSurface) {
        let output = (error as? GitError)?.stderr ?? error.localizedDescription
        outputReport = GitOutputReport(title: title, output: output.isEmpty ? error.localizedDescription : output, surface: surface)
    }

    /// The report a view on `surface` presents.
    func outputReport(on surface: SourceControlSurface) -> GitOutputReport? {
        outputReport?.surface == surface ? outputReport : nil
    }
}

/// A user-facing, already localized message thrown inside source control flows.
struct SourceControlMessage: Error, LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
