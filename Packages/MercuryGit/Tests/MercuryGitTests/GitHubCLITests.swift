import Foundation
import Testing
@testable import MercuryGit

/// `gh` output is checked against hand-written fixtures, and the wrapper against a fake `gh` script, so no test talks
/// to GitHub.
@Suite struct GitHubCLIParsingTests {
    @Test func decodesPullRequest() throws {
        let json = """
        {"baseRefName":"main","headRefName":"feature/x","isDraft":true,"mergeStateStatus":"BLOCKED","number":42,
         "reviewDecision":"","state":"OPEN","title":"Add usage bar","url":"https://github.com/acme/app/pull/42"}
        """
        let pr = try GitHubCLI.decode(PullRequest.self, from: Data(json.utf8))
        #expect(pr.number == 42)
        #expect(pr.url.absoluteString == "https://github.com/acme/app/pull/42")
        #expect(pr.state == .open && pr.isDraft)
        #expect(pr.reviewDecision == nil)
        #expect(pr.mergeStateStatus == "BLOCKED")
        #expect(pr.headRefName == "feature/x" && pr.baseRefName == "main")
    }

    @Test func decodesMergedPullRequestWithMissingOptionalFields() throws {
        let json = #"{"number":7,"url":"https://github.com/a/b/pull/7","state":"MERGED","reviewDecision":"APPROVED"}"#
        let pr = try GitHubCLI.decode(PullRequest.self, from: Data(json.utf8))
        #expect(pr.state == .merged && !pr.isDraft && pr.title.isEmpty && pr.reviewDecision == "APPROVED")
    }

    @Test func decodesChecks() throws {
        let json = """
        [{"bucket":"pass","link":"https://github.com/a/b/actions/runs/1/job/2","name":"build","state":"SUCCESS","workflow":"CI"},
         {"bucket":"fail","link":"","name":"lint","state":"FAILURE","workflow":""},
         {"bucket":"pending","link":"https://ci.example/3","name":"deploy","state":"IN_PROGRESS","workflow":"CD"},
         {"bucket":"something-new","name":"future","state":"WAITING"}]
        """
        let checks = try GitHubCLI.decode([PullRequestCheck].self, from: Data(json.utf8))
        #expect(checks.map(\.bucket) == [.pass, .fail, .pending, .pending])
        #expect(checks[0].link?.absoluteString == "https://github.com/a/b/actions/runs/1/job/2")
        #expect(checks[1].link == nil && checks[1].workflow == nil)
        #expect(Set(checks.map(\.id)).count == 4)
    }

    @Test func invalidJSONThrows() {
        #expect(throws: GitHubCLIError.self) { _ = try GitHubCLI.decode(PullRequest.self, from: Data("not json".utf8)) }
    }

    @Test func parsesAuthStatus() throws {
        let loggedIn = """
        {"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"octo","tokenSource":"keyring",
         "scopes":"repo","gitProtocol":"https"}]}}
        """
        #expect(try GitHubCLI.parseAuthStatus(Data(loggedIn.utf8), host: "github.com") == .loggedIn(login: "octo"))
        let failed = #"{"hosts":{"github.com":[{"state":"error","active":true,"host":"github.com","login":"octo"}]}}"#
        #expect(try GitHubCLI.parseAuthStatus(Data(failed.utf8), host: "github.com") == .notLoggedIn)
        #expect(try GitHubCLI.parseAuthStatus(Data(#"{"hosts":{}}"#.utf8), host: "github.com") == .notLoggedIn)
    }

    @Test func recognizesGitHubRemotes() {
        #expect(GitHubCLI.gitHubHost(ofRemoteURL: "https://github.com/acme/app.git") == "github.com")
        #expect(GitHubCLI.gitHubHost(ofRemoteURL: "git@github.com:acme/app.git") == "github.com")
        #expect(GitHubCLI.gitHubHost(ofRemoteURL: "ssh://git@ssh.github.com:443/acme/app") == "github.com")
        #expect(GitHubCLI.gitHubHost(ofRemoteURL: "https://user@acme.ghe.com/acme/app") == "acme.ghe.com")
        #expect(GitHubCLI.gitHubHost(ofRemoteURL: "git@gitlab.com:acme/app.git") == nil)
        #expect(GitHubCLI.gitHubHost(ofRemoteURL: "/tmp/remote.git") == nil)
        #expect(GitHubCLI.gitHubHost(ofRemoteURL: "../remote.git") == nil)
        #expect(GitHubCLI.gitHubHost(ofRemoteURL: "x;touch y.ghe.com:a/b.git") == nil)
        #expect(GitHubCLI.gitHubHost(ofRemoteURL: "git@git.corp.example:a/b.git", knownHosts: ["git.corp.example"]) == "git.corp.example")
    }

    @Test func findsExistingPullRequestInRefusal() {
        let refusal = GitHubCLIError(kind: .failed(exitCode: 1), output: """
        a pull request for branch "feature/x" into branch "main" already exists:
        https://github.com/acme/app/pull/42
        """)
        #expect(GitHubCLI.existingPullRequestURL(in: refusal)?.absoluteString == "https://github.com/acme/app/pull/42")
        #expect(GitHubCLI.existingPullRequestURL(in: GitHubCLIError(kind: .failed(exitCode: 1), output: "HTTP 401")) == nil)
    }

    @Test func environmentDisablesPromptsAndRepositoryOverrides() {
        let env = GitHubCLI.environment(inheriting: ["PATH": "/bin", "GIT_DIR": "/x", "GH_FORCE_TTY": "1", "GH_TOKEN": "kept"])
        #expect(env["GIT_DIR"] == nil && env["GH_FORCE_TTY"] == nil)
        #expect(env["GH_PROMPT_DISABLED"] == "1" && env["NO_COLOR"] == "1" && env["PATH"] == "/bin")
        #expect(env["GH_TOKEN"] == "kept") // The user's own choice of credentials is left alone.
    }
}

@Suite struct GitHubCLIWrapperTests {
    /// A fake `gh` that answers from the arguments it receives and records them.
    private func fakeGH(_ body: String) throws -> (cli: GitHubCLI, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mercury-gh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("gh")
        try ("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(dir.path)/args\"\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (GitHubCLI(executable: script, environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(5)), dir)
    }

    private func recordedArgs(_ dir: URL) throws -> [String] {
        try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func noPullRequestIsNil() async throws {
        let (cli, dir) = try fakeGH("echo 'no pull requests found for branch \"feature/x\"' >&2\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await cli.pullRequest(branch: "feature/x", in: dir) == nil)
        #expect(try recordedArgs(dir) == ["pr", "view", "feature/x", "--json", GitHubCLI.pullRequestFields])
    }

    @Test func otherFailuresThrow() async throws {
        let (cli, dir) = try fakeGH("echo 'HTTP 502: bad gateway' >&2\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let error = await #expect(throws: GitHubCLIError.self) { _ = try await cli.pullRequest(branch: "x", in: dir) }
        #expect(error?.output.contains("502") == true)
    }

    @Test func checksPendingExitCodeStillParses() async throws {
        let (cli, dir) = try fakeGH("echo '[{\"name\":\"build\",\"state\":\"IN_PROGRESS\",\"bucket\":\"pending\",\"link\":\"\"}]'\nexit 8\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checks = try await cli.checks(pullRequest: 3, in: dir)
        #expect(checks.map(\.name) == ["build"])
    }

    @Test func noChecksIsEmpty() async throws {
        let (cli, dir) = try fakeGH("echo \"no checks reported on the 'feature/x' branch\" >&2\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await cli.checks(pullRequest: 3, in: dir).isEmpty)
    }

    @Test func createPassesBodyThroughFileAndReturnsURL() async throws {
        let (cli, dir) = try fakeGH("""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--body-file" ]; then cp "$2" "\(FileManager.default.temporaryDirectory.path)/mercury-gh-body-copy"; fi
          shift
        done
        echo 'https://github.com/acme/app/pull/43'
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = "## Summary\n\n- `code` and $(not expanded)\n"
        let url = try await cli.createPullRequest(title: "-Leading dash title", body: body, base: "main", head: "feature/x",
                                                  draft: true, in: dir)
        #expect(url.absoluteString == "https://github.com/acme/app/pull/43")
        let args = try recordedArgs(dir)
        #expect(args.prefix(3) == ["pr", "create", "--title"])
        #expect(args[3] == "-Leading dash title")
        #expect(args.contains("--draft") && args.contains("--head") && args.contains("--base"))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("mercury-gh-body-copy")
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(try String(contentsOf: copy, encoding: .utf8) == body)
    }

    @Test func timeoutStopsTheProcess() async throws {
        var (cli, dir) = try fakeGH("exec sleep 30\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        cli.timeout = .milliseconds(300)
        let start = ContinuousClock.now
        let error = await #expect(throws: GitHubCLIError.self) { _ = try await cli.pullRequest(branch: "x", in: dir) }
        #expect(error?.kind == .timedOut)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func authStatusPassesActiveHost() async throws {
        let (cli, dir) = try fakeGH(#"echo '{"hosts":{"github.com":[{"state":"success","active":true,"login":"octo"}]}}'"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await cli.authStatus() == .loggedIn(login: "octo"))
        #expect(try recordedArgs(dir) == ["auth", "status", "--active", "--hostname", "github.com", "--json", "hosts"])
    }
}
