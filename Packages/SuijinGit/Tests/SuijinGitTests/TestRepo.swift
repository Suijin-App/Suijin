import Foundation
@testable import SuijinGit

/// A throwaway repository in a temporary directory. Paths are symlink-resolved (`/private/var/...`) so they
/// compare equal to what git reports.
struct TestRepo {
    let root: URL
    let url: URL
    let runner = GitRunner()

    init(initialCommit: Bool = true) async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("suijin-git-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // `resolvingSymlinksInPath()` maps `/private/var` back to `/var`; realpath gives git's form.
        guard let real = realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(real) }
        root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        url = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try await git("init", "--quiet", "--initial-branch=main")
        if initialCommit {
            try write("README.md", "hello\n")
            try await commitAll("initial")
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func git(_ args: String...) async throws -> String {
        try await git(args, in: url)
    }

    @discardableResult
    func git(_ args: [String], in dir: URL) async throws -> String {
        let identity = ["-c", "user.name=Suijin Tests", "-c", "user.email=tests@suijin.invalid", "-c", "commit.gpgsign=false"]
        return try await runner.text(identity + args, in: dir)
    }

    func write(_ path: String, _ content: String, in dir: URL? = nil) throws {
        try write(path, Data(content.utf8), in: dir)
    }

    func write(_ path: String, _ data: Data, in dir: URL? = nil) throws {
        let file = (dir ?? url).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func commitAll(_ message: String, in dir: URL? = nil) async throws {
        try await git(["add", "-A"], in: dir ?? url)
        try await git(["commit", "--quiet", "-m", message], in: dir ?? url)
    }
}
