import Foundation
import SevindaCore
import SevindaGit
import Testing
@testable import Sevinda

/// A repository the active `gh` account cannot see is read with another account `gh` is signed in to, which is then
/// remembered for that remote. A stand-in `gh` plays both accounts: it sees the repository only with the other
/// account's token.
@MainActor
struct RepositoryAccountTests {
    private func fakeGH() throws -> (GitHubCLI, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-gh-acct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("gh")
        try #"""
        #!/bin/sh
        here="$(dirname "$0")"
        if [ "$1 $2" = "auth status" ]; then
          echo '{"hosts":{"github.com":[{"state":"success","active":true,"login":"main"},{"state":"success","active":false,"login":"other"}]}}'
          exit 0
        fi
        if [ "$1 $2" = "auth token" ]; then echo "token-of-$6"; exit 0; fi
        echo "${GH_TOKEN:-none}" >> "$here/calls"
        if [ "$GH_TOKEN" = "token-of-other" ]; then
          echo '{"number":7,"url":"https://github.com/o/r/pull/7","title":"t","state":"OPEN","isDraft":false}'
          exit 0
        fi
        echo "GraphQL: Could not resolve to a Repository with the name 'o/r'. (repository)" >&2
        exit 1
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (GitHubCLI(executable: script, environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(5)), dir)
    }

    private func calls(_ dir: URL) -> [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    @Test func anotherSignedInAccountReadsTheRepositoryAndIsRemembered() async throws {
        let (cli, dir) = try fakeGH()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: dir.appendingPathComponent("data"))
        let store = SourceControlStore.shared(for: model)
        let remote = "https://github.com/o/r.git"

        let (pr, used) = try await store.withRepositoryAccount(cli, host: "github.com", remoteURL: remote) {
            try await $0.pullRequest(branch: "feature", in: dir)
        }
        #expect(pr?.number == 7)
        #expect(calls(dir) == ["none", "token-of-other"])
        #expect(cli.environment["GH_TOKEN"] == nil && used.environment["GH_TOKEN"] != nil)

        // Next time the remembered account goes first.
        _ = try await store.withRepositoryAccount(cli, host: "github.com", remoteURL: remote) {
            try await $0.pullRequest(branch: "feature", in: dir)
        }
        #expect(calls(dir) == ["none", "token-of-other", "token-of-other"])
        store.forgetGitHubCLI()
    }

    @Test func noAccountThatCanSeeItNamesTheAccountsTried() async throws {
        let (cli, dir) = try fakeGH()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The other account's token is refused too.
        let script = dir.appendingPathComponent("gh")
        let text = try String(contentsOf: script, encoding: .utf8).replacingOccurrences(of: "token-of-other\" ]", with: "nobody\" ]")
        try text.write(to: script, atomically: true, encoding: .utf8)
        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: dir.appendingPathComponent("data"))
        let store = SourceControlStore.shared(for: model)

        do {
            _ = try await store.withRepositoryAccount(cli, host: "github.com", remoteURL: "https://github.com/o/x.git") {
                try await $0.pullRequest(branch: "feature", in: dir)
            }
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("main, other"))
        }
    }
}
