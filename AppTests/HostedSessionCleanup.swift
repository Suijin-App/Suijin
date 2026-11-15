import Foundation
import SuijinPTYProtocol
import SuijinTerminal
import Testing

/// Ends what a test left in the PTY host. App tests share this Mac's registered helper with the installed app, and
/// the helper keeps a session nobody ended (its process, and its scrollback for a day), so every suite that starts
/// hosted sessions carries this trait: `@Suite(.endsHostedSessions, …)`.
///
/// After each test, also a failed one, it ends the host sessions whose owner is gone: a session belongs to the data
/// root it was started for (or, started without one, to its working directory), and a test's data root is a temporary
/// folder the test removes as it returns. A session whose temporary owner no longer exists is therefore a finished
/// test's, never a running test's (its folder still exists) and never the user's (their data root is not temporary).
struct HostedSessionCleanup: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        do {
            try await function()
        } catch {
            await Self.endAbandonedSessions()
            throw error
        }
        await Self.endAbandonedSessions()
    }

    @MainActor
    static func endAbandonedSessions() async {
        guard let sessions = try? await PTYHostClient.shared.listSessions() else { return }
        let temporary = FileManager.default.temporaryDirectory.path
        for session in sessions where isAbandoned(session, temporaryDirectory: temporary,
                                                  exists: { FileManager.default.fileExists(atPath: $0) }) {
            PTYHostClient.shared.terminate(session.id)
        }
    }

    /// Whether `session` was started for a temporary folder that is gone.
    static func isAbandoned(_ session: PTYSessionInfo, temporaryDirectory: String, exists: (String) -> Bool) -> Bool {
        let owner = session.metadata["suijin.dataRoot"] ?? session.cwd
        return isInside(owner, directory: temporaryDirectory) && !exists(owner)
    }

    /// Path containment that treats `/private/var/…` and `/var/…` as the same place.
    private static func isInside(_ path: String, directory: String) -> Bool {
        func normalized(_ path: String) -> String {
            let standard = (path as NSString).standardizingPath
            return standard.hasPrefix("/private/") ? String(standard.dropFirst("/private".count)) : standard
        }
        let directory = normalized(directory)
        return normalized(path).hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }
}

extension Trait where Self == HostedSessionCleanup {
    /// Ends the hosted sessions a test leaves behind (see `HostedSessionCleanup`).
    static var endsHostedSessions: Self { Self() }
}
