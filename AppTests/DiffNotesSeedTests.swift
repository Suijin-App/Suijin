import Foundation
import SevindaCore
import SevindaDiff
import SevindaGit
import Testing
@testable import Sevinda

/// Builds a data root for looking at diff notes and the side-by-side diff in the real app:
/// `TEST_RUNNER_SEVINDA_NOTES_SEED_ROOT=<dir> xcodebuild test -only-testing:SevindaAppTests/DiffNotesSeedTests`, then
/// launch Sevinda with `SEVINDA_DATA_ROOT=<dir>/data -SevindaInitialTab changes`. It holds a git workspace with one
/// worktree whose changes carry line, range, file, sent and stale notes, and selects that worktree.
///
/// With `SEVINDA_NOTES_SEED_CLAUDE=1` it also starts the real `claude` in the worktree (no prompt, nothing is sent to a
/// model), pastes the unsent notes into its prompt the way "Send to agent" does, without pressing Return, and checks
/// the prompt took them as one paste; the session keeps running so the app attaches to it (see
/// `SEVINDA_NOTES_SEED_CLAUDE_DIR` below for Claude's folder trust). `SEVINDA_NOTES_SEED_CLEANUP=1`
/// ends the sessions of that data root again.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SEVINDA_NOTES_SEED_ROOT"] != nil))
struct DiffNotesSeedTests {
    private var base: URL {
        get throws {
            URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SEVINDA_NOTES_SEED_ROOT"]), isDirectory: true)
        }
    }

    private func eventually(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEVINDA_NOTES_SEED_CLEANUP"] != "1"))
    func seed() async throws {
        let base = try base
        try? FileManager.default.removeItem(at: base)
        let repo = base.appendingPathComponent("review-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = GitRunner()
        let identity = ["-c", "user.name=Sevinda Demo", "-c", "user.email=demo@example.invalid"]
        _ = try await git.run(["init", "-b", "main"], in: repo)
        // Listed first among the changes, so the Changes tab opens on it.
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("App"), withIntermediateDirectories: true)
        try Self.originalStore.write(to: repo.appendingPathComponent(Self.storePath), atomically: true, encoding: .utf8)
        try "# review-demo\n\nA small demo repository.\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: repo)
        _ = try await git.run(identity + ["commit", "-m", "initial"], in: repo)

        let dataRoot = base.appendingPathComponent("data", isDirectory: true)
        let store = try SevindaStore(url: SevindaPaths.database(in: dataRoot))
        let model = AppModel(store: store, dataRoot: dataRoot)
        await model.addWorkspace(at: repo)
        let workspaceID = try #require(model.workspaces.first).id
        let tree = try await model.createWorktree(workspaceID: workspaceID, branch: "feature/timeouts", base: "main",
                                                  path: WorktreeService.defaultPath(repository: repo, branch: "feature/timeouts"))
        let treeURL = URL(fileURLWithPath: tree.path, isDirectory: true)
        try Self.changedStore.write(to: treeURL.appendingPathComponent(Self.storePath), atomically: true, encoding: .utf8)
        try "# review-demo\n\nA small demo repository for reviewing agent changes.\n"
            .write(to: treeURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let diff = try await DiffService(worktree: treeURL).diff(for: Self.storePath, scope: .againstBase("main"))
        let lines = DiffNoteAnchoring.newSideLines(of: diff)
        func note(_ anchor: DiffNoteAnchor, _ body: String, file: String = Self.storePath, sent: Bool = false,
                  identity: String? = nil, offset: TimeInterval) -> DiffNote {
            DiffNote(workspaceID: workspaceID, worktreeID: tree.id, filePath: file, startLine: anchor.startLine,
                     lineNumber: anchor.lineNumber, body: body, createdAt: Date().addingTimeInterval(offset),
                     sentAt: sent ? Date() : nil, scope: .branch,
                     diffIdentity: identity ?? DiffNoteAnchoring.identity(of: anchor, in: lines))
        }
        let notes = [
            note(DiffNoteAnchor(lineNumber: 13), "Inject the clock so tests can control time.", offset: 0),
            note(DiffNoteAnchor(startLine: 19, lineNumber: 22), "This guard and the deadline belong together; extract a \"startSession\" helper.", offset: 1),
            note(.file, "Please add a short doc comment explaining the timeout policy.", offset: 2),
            note(DiffNoteAnchor(lineNumber: 12), "Keep the limit configurable.", sent: true, offset: 3),
            note(DiffNoteAnchor(lineNumber: 23), "Written against an older version of this line.", identity: "0", offset: 4),
            note(.file, "Mention the timeout in the README.", file: "README.md", offset: 5),
        ]
        for item in notes { try store.save(item) }
        try store.setSetting("ui.lastSelection", SessionContext.worktree(tree.id).storageValue)

        guard ProcessInfo.processInfo.environment["SEVINDA_NOTES_SEED_CLAUDE"] == "1" else { return }
        await model.runtimes.bootstrap()
        // Claude asks before working in a folder it has not been trusted with, and this test never answers that
        // dialog. `SEVINDA_NOTES_SEED_CLAUDE_DIR` names a folder Claude already trusts to run in instead (as a plain
        // folder workspace; nothing is submitted, so nothing there changes).
        var context = SessionContext.worktree(tree.id)
        if let trusted = ProcessInfo.processInfo.environment["SEVINDA_NOTES_SEED_CLAUDE_DIR"] {
            await model.addWorkspace(at: URL(fileURLWithPath: trusted, isDirectory: true))
            let folder = try #require(model.workspaces.first { $0.path == URL(fileURLWithPath: trusted).standardizedFileURL.path })
            context = .workspace(folder.id)
        }
        let id = try #require(await model.runtimes.start(in: context, agent: .claude, accountID: nil, prompt: nil))
        let runtime = try #require(model.runtimes.runtime(for: id))
        let ready = await eventually(.seconds(40)) { runtime.terminal.view.isBracketedPasteMode }
        #expect(ready, "claude turned bracketed paste on")
        try await Task.sleep(for: .seconds(2))
        // A folder Claude does not trust yet opens a trust dialog instead of the prompt; never answer it from here.
        let before = runtime.terminal.view.visibleText()
        guard !before.contains("trust this folder") else {
            Issue.record("claude asks to trust the folder; seed under a folder it already trusts")
            await model.runtimes.prepareForQuit()
            return
        }
        let unsent = notes.filter { $0.sentAt == nil }.sorted { ($0.filePath, $0.lineNumber) < ($1.filePath, $1.lineNumber) }
        try runtime.paste(DiffNoteFormatter.format(unsent), pressReturn: false)
        try await Task.sleep(for: .seconds(3))
        let screen = runtime.terminal.view.visibleText()
        // The screen is written to the seed folder only (it can show an account email), never printed.
        try screen.write(to: base.appendingPathComponent("claude-screen.txt"), atomically: true, encoding: .utf8)
        // Claude Code folds a multi-line paste into one "[Pasted text …]" chip in its prompt, so the notes did not
        // run line by line.
        #expect(screen.contains("Pasted text"), "the notes arrived as one paste")
        for item in unsent { var sent = item; sent.sentAt = Date(); try store.save(sent) }
        await model.runtimes.prepareForQuit()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEVINDA_NOTES_SEED_CLEANUP"] == "1"))
    func cleanup() async throws {
        let dataRoot = try base.appendingPathComponent("data", isDirectory: true)
        let model = AppModel(store: try SevindaStore(url: SevindaPaths.database(in: dataRoot)), dataRoot: dataRoot)
        await model.load()
        await model.runtimes.bootstrap()
        for session in model.sessions { await model.closeSession(session.id) }
        #expect(model.runtimes.liveCount == 0)
    }

    static let storePath = "App/SessionStore.swift"

    static let originalStore = """
    import Foundation

    /// Keeps the running sessions of each worktree.
    final class SessionStore {
        enum SessionError: Error {
            case tooMany(Int)
        }

        /// Sessions keyed by worktree path.
        private var sessions: [URL: Session] = [:]
        private let limit = 8

        init() {}

        func start(_ agent: Agent, in worktree: URL) async throws -> Session {
            guard sessions.count < limit else { throw SessionError.tooMany(limit) }
            let session = try await agent.launch(at: worktree)
            sessions[worktree] = session
            return session
        }

        func stop(_ worktree: URL) async {
            guard let session = sessions.removeValue(forKey: worktree) else { return }
            await session.terminate()
        }

        var summary: String { "\\(sessions.count) sessions" }
    }

    """

    static let changedStore = """
    import Foundation

    /// Keeps the running sessions of each worktree.
    final class SessionStore {
        enum SessionError: Error {
            case tooMany(Int)
            case timedOut(Duration)
        }

        /// Sessions keyed by worktree path.
        private var sessions: [URL: Session] = [:]
        private let limit: Int
        private let clock = ContinuousClock()

        init(limit: Int = 8) {
            self.limit = limit
        }

        func start(_ agent: Agent, in worktree: URL, environment: [String: String] = [:], timeout: Duration = .seconds(30)) async throws -> Session {
            guard sessions.count < limit else { throw SessionError.tooMany(limit) }
            let session = try await agent.launch(at: worktree, environment: environment)
            session.deadline = clock.now + timeout
            sessions[worktree] = session
            return session
        }

        func stop(_ worktree: URL) async {
            guard let session = sessions.removeValue(forKey: worktree) else { return }
            await session.terminate(gracePeriod: .seconds(2))
        }

        var summary: String { sessions.keys.map(\\.lastPathComponent).sorted().joined(separator: ", ") }
    }

    """
}
