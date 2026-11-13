import Foundation
import Testing
@testable import SuijinGit

@Suite struct FileContentsTests {
    private let oldBytes = Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2])
    private let newBytes = Data([0x89, 0x50, 0x4E, 0x47, 0, 9, 9, 9])

    @Test func blobReadsCommittedBytesAndReportsMissingPathsAsNil() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        try repo.write("img/a*b.png", oldBytes)
        try repo.write("img/axb.png", newBytes)
        try await repo.commitAll("images")
        let service = DiffService(worktree: repo.url)

        #expect(try await service.blob(at: "img/a*b.png", revision: "HEAD") == oldBytes)
        #expect(try await service.blob(at: "img/axb.png", revision: "HEAD") == newBytes)
        #expect(try await service.blob(at: "img/none.png", revision: "HEAD") == nil)
        // A directory is not a file.
        #expect(try await service.blob(at: "img", revision: "HEAD") == nil)
        // The empty tree, the base before a repository's first commit, has nothing.
        let emptyTree = try await repo.git("hash-object", "-t", "tree", "/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try await service.blob(at: "README.md", revision: emptyTree) == nil)
    }

    @Test func blobRefusesLargeFilesAndPathsOutsideTheCheckout() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        try repo.write("big.bin", Data(count: 100))
        try await repo.commitAll("big")
        let service = DiffService(worktree: repo.url)

        await #expect(throws: FileContentsError.tooLarge(path: "big.bin", size: 100, limit: 10)) {
            try await service.blob(at: "big.bin", revision: "HEAD", maximumSize: 10)
        }
        await #expect(throws: FileContentsError.invalidPath("../outside")) {
            try await service.contents(of: "../outside", side: .new, scope: .uncommitted)
        }
        await #expect(throws: FileContentsError.invalidPath("/etc/hosts")) {
            try await service.blob(at: "/etc/hosts", revision: "HEAD")
        }
    }

    @Test func uncommittedSidesAreHeadAndTheWorkingTree() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        try repo.write("logo.png", oldBytes)
        try repo.write("gone.png", oldBytes)
        try await repo.commitAll("images")
        try repo.write("logo.png", newBytes)
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("gone.png"))
        try repo.write("fresh.png", newBytes)
        let service = DiffService(worktree: repo.url)

        #expect(try await service.contents(of: "logo.png", side: .old, scope: .uncommitted) == oldBytes)
        #expect(try await service.contents(of: "logo.png", side: .new, scope: .uncommitted) == newBytes)
        #expect(try await service.contents(of: "gone.png", side: .old, scope: .uncommitted) == oldBytes)
        #expect(try await service.contents(of: "gone.png", side: .new, scope: .uncommitted) == nil)
        #expect(try await service.contents(of: "fresh.png", side: .old, scope: .uncommitted) == nil)
        #expect(try await service.contents(of: "fresh.png", side: .new, scope: .uncommitted) == newBytes)
        await #expect(throws: FileContentsError.self) {
            try await service.contents(of: "fresh.png", side: .new, scope: .uncommitted, maximumSize: 2)
        }
    }

    @Test func uncommittedOldSideBeforeTheFirstCommitIsEmpty() async throws {
        let repo = try await TestRepo(initialCommit: false)
        defer { repo.cleanUp() }
        try repo.write("first.png", newBytes)
        let service = DiffService(worktree: repo.url)
        #expect(try await service.contents(of: "first.png", side: .old, scope: .uncommitted) == nil)
        #expect(try await service.contents(of: "first.png", side: .new, scope: .uncommitted) == newBytes)
    }

    @Test func committedSidesAreTheMergeBaseAndHeadIgnoringTheWorkingTree() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        try repo.write("logo.png", oldBytes)
        try await repo.commitAll("base")
        try await repo.git("checkout", "--quiet", "-b", "feature")
        try repo.write("logo.png", newBytes)
        try await repo.git("mv", "logo.png", "brand.png")
        try await repo.commitAll("rename and edit")
        // Uncommitted edits are not part of the committed group.
        try repo.write("brand.png", Data([1]))
        let service = DiffService(worktree: repo.url)

        #expect(try await service.contents(of: "logo.png", side: .old, scope: .committed("main")) == oldBytes)
        #expect(try await service.contents(of: "brand.png", side: .new, scope: .committed("main")) == newBytes)
        #expect(try await service.contents(of: "brand.png", side: .old, scope: .committed("main")) == nil)
    }

    @Test func commitSidesAreItsParentAndTheCommit() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        try repo.write("logo.png", oldBytes)
        try await repo.commitAll("first")
        try repo.write("logo.png", newBytes)
        try await repo.commitAll("second")
        let second = try await repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.write("logo.png", Data([7]))
        try await repo.commitAll("third")
        let root = try await repo.git("rev-list", "--max-parents=0", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let service = DiffService(worktree: repo.url)

        #expect(try await service.contents(of: "logo.png", side: .old, scope: .commit(second)) == oldBytes)
        #expect(try await service.contents(of: "logo.png", side: .new, scope: .commit(second)) == newBytes)
        // A root commit's parent is the empty tree.
        #expect(try await service.contents(of: "README.md", side: .old, scope: .commit(root)) == nil)
        #expect(try await service.contents(of: "README.md", side: .new, scope: .commit(root)) == Data("hello\n".utf8))
    }

    @Test func parsesExactlyTheRequestedTreeEntry() {
        let listing = Data("100644 blob abc123      12\tlogo.png\0160000 commit def456       -\tsub\0".utf8)
        #expect(DiffService.parseTreeEntry(listing, path: "logo.png")?.object == "abc123")
        #expect(DiffService.parseTreeEntry(listing, path: "logo.png")?.size == 12)
        #expect(DiffService.parseTreeEntry(listing, path: "sub") == nil)
        #expect(DiffService.parseTreeEntry(listing, path: "logo") == nil)
    }
}
