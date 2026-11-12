import Foundation
import MercuryCore
import MercuryGit
import MercuryPTYProtocol

/// Executes the broker's `worker start`: picks the place (the coordinator's own folder or worktree, or a new worktree
/// of the same repository), the account, and starts the agent with the worker prompt like any other session.
@MainActor
struct WorkerLauncher {
    unowned let model: AppModel

    func launch(_ request: WorkerLaunchRequest) async -> WorkerLaunchResult {
        do {
            let (context, directory) = try await place(for: request)
            let agent: AgentKind = request.agent == .claude ? .claude : .codex
            let accountID = try account(request.accountID, for: agent)
            // Starting a session selects its tab; a worker must not pull the user away from what they look at.
            let selection = model.selection
            let tabs = model.selectedTab
            let shownError = model.presentedError
            let orchestration = model.runtimes.orchestration
            orchestration.launchingWorkerPrompts.insert(request.prompt)
            defer { orchestration.launchingWorkerPrompts.remove(request.prompt) }
            let id = await model.runtimes.start(in: context, agent: agent, accountID: accountID, prompt: request.prompt)
            model.selection = selection
            model.selectedTab = tabs
            guard let id else {
                let reason = model.presentedError?.message ?? String(localized: "Mercury could not start the agent.")
                model.presentedError = shownError // reported to the coordinator instead of an alert
                return WorkerLaunchResult(dispatchID: request.dispatchID, workerSessionID: nil, error: reason)
            }
            if var record = model.sessions.first(where: { $0.id == id }) {
                record.title = "\(record.title) · \(request.name)"
                await model.upsert(record)
            }
            return WorkerLaunchResult(dispatchID: request.dispatchID, workerSessionID: id.uuidString, directory: directory.path)
        } catch {
            return WorkerLaunchResult(dispatchID: request.dispatchID, workerSessionID: nil, error: error.localizedDescription)
        }
    }

    private func place(for request: WorkerLaunchRequest) async throws -> (SessionContext, URL) {
        guard let coordinatorID = UUID(uuidString: request.coordinatorSessionID),
              let coordinator = model.sessions.first(where: { $0.id == coordinatorID }) else {
            throw WorkerLaunchError.coordinatorGone
        }
        let context = model.context(of: coordinator)
        guard request.worktree == .new else {
            guard let directory = model.directory(of: context) else { throw WorkerLaunchError.coordinatorGone }
            return (context, directory)
        }
        guard let workspaceID = model.workspaceID(of: context), let workspace = model.workspace(workspaceID) else {
            throw WorkerLaunchError.coordinatorGone
        }
        guard workspace.kind == .git else { throw WorkerLaunchError.notGit(workspace.name) }
        let repository = URL(fileURLWithPath: workspace.path, isDirectory: true)
        let service = WorktreeService(repository: repository)
        // The worker branches off what the coordinator has checked out.
        let base: String
        if case .worktree(let id) = context, let tree = model.worktree(id) {
            base = tree.branch
        } else if let current = try? await service.currentBranch() {
            base = current
        } else {
            base = try await service.defaultBaseBranch()
        }
        let existing = Set((try? await service.localBranches()) ?? [])
        var branch = request.name
        var suffix = 2
        while existing.contains(branch) || FileManager.default.fileExists(atPath: destination(workspace, branch).path) {
            branch = "\(request.name)-\(suffix)"
            suffix += 1
        }
        let selection = model.selection
        let record = try await model.createWorktree(workspaceID: workspace.id, branch: branch, base: base,
                                                    path: destination(workspace, branch))
        model.selection = selection
        return (.worktree(record.id), URL(fileURLWithPath: record.path, isDirectory: true))
    }

    /// The same place the New Worktree sheet uses: the worktree folder from Settings, else next to the repository.
    private func destination(_ workspace: Workspace, _ branch: String) -> URL {
        if let root = model.setting(.worktreeRoot), !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(workspace.name, isDirectory: true)
                .appendingPathComponent(branch, isDirectory: true)
        }
        return WorktreeService.defaultPath(repository: URL(fileURLWithPath: workspace.path, isDirectory: true), branch: branch)
    }

    /// `--account` by id (or its first characters), label or email, among the agent's provider's accounts.
    private func account(_ requested: String?, for agent: AgentKind) throws -> UUID? {
        guard let requested = requested?.trimmingCharacters(in: .whitespaces), !requested.isEmpty else { return nil }
        guard let provider = agent.accountProvider else { return nil }
        let candidates = model.accounts.filter { $0.provider == provider }
        let needle = requested.lowercased()
        let matches = candidates.filter { account in
            account.id.uuidString.lowercased().hasPrefix(needle) || account.label.lowercased() == needle
                || account.email?.lowercased() == needle
        }
        guard matches.count == 1, let match = matches.first else {
            let known = candidates.map { "\($0.label) (\($0.id.uuidString.prefix(8)))" }.joined(separator: ", ")
            throw WorkerLaunchError.account(requested, known: known)
        }
        return match.id
    }
}

enum WorkerLaunchError: LocalizedError {
    case coordinatorGone
    case notGit(String)
    case account(String, known: String)

    var errorDescription: String? {
        switch self {
        case .coordinatorGone:
            String(localized: "The coordinator's session is no longer open in Mercury.")
        case .notGit(let name):
            String(localized: "“\(name)” is a plain folder, so there is no new worktree to make. Use --worktree current.")
        case .account(let requested, let known):
            known.isEmpty
                ? String(localized: "No Mercury account matches “\(requested)” for this agent; omit --account to use the default.")
                : String(localized: "No single Mercury account matches “\(requested)” for this agent. Accounts: \(known).")
        }
    }
}
