import Foundation
import SuijinPTYProtocol
import Testing
@testable import Suijin

/// Which host sessions the test cleanup ends: only those started for a temporary folder that is gone.
struct HostedSessionCleanupTests {
    private let temporary = "/var/folders/ab/T/"

    private func session(dataRoot: String?, cwd: String = "/Users/someone/project") -> PTYSessionInfo {
        PTYSessionInfo(id: UUID().uuidString, pid: 1, executable: "/bin/zsh", cwd: cwd, startedAt: Date(),
                       isRunning: true, exitStatus: nil, metadata: dataRoot.map { ["suijin.dataRoot": $0] } ?? [:])
    }

    private func isAbandoned(_ info: PTYSessionInfo, existing: Set<String> = []) -> Bool {
        HostedSessionCleanup.isAbandoned(info, temporaryDirectory: temporary, exists: { existing.contains($0) })
    }

    @Test func aFinishedTestsSessionIsAbandoned() {
        #expect(isAbandoned(session(dataRoot: "/var/folders/ab/T/suijin-load-1/data")))
        #expect(isAbandoned(session(dataRoot: "/private/var/folders/ab/T/suijin-load-1/data")), "the same place by its other name")
    }

    @Test func aRunningTestsSessionIsKept() {
        let root = "/var/folders/ab/T/suijin-load-2/data"
        #expect(!isAbandoned(session(dataRoot: root), existing: [root]))
    }

    @Test func theUsersSessionsAreNeverTouched() {
        #expect(!isAbandoned(session(dataRoot: "/Users/someone/Library/Application Support/Suijin")))
        // Their shell may sit in a temporary folder that was deleted; the data root decides.
        #expect(!isAbandoned(session(dataRoot: "/Users/someone/Library/Application Support/Suijin",
                                     cwd: "/var/folders/ab/T/gone")))
        #expect(!isAbandoned(session(dataRoot: "/var/folders/ab/Tools/data")), "a sibling of the temporary folder")
    }

    @Test func aSessionStartedWithoutADataRootBelongsToItsWorkingDirectory() {
        #expect(isAbandoned(session(dataRoot: nil, cwd: "/var/folders/ab/T/suijin-term-3")))
        #expect(!isAbandoned(session(dataRoot: nil, cwd: "/var/folders/ab/T/suijin-term-3"),
                             existing: ["/var/folders/ab/T/suijin-term-3"]))
        #expect(!isAbandoned(session(dataRoot: nil)))
    }
}
