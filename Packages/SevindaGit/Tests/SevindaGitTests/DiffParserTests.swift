import Foundation
import Testing
@testable import SevindaGit

@Suite struct DiffParserTests {
    @Test func modifiedFileWithMultipleHunks() throws {
        let diff = """
        diff --git a/Sources/main.swift b/Sources/main.swift
        index 1111111..2222222 100644
        --- a/Sources/main.swift
        +++ b/Sources/main.swift
        @@ -1,3 +1,4 @@ import Foundation
         line1
        -line2
        +line2 changed
        +inserted
         line3
        @@ -10,2 +11,2 @@ func tail()
         ten
        --- a removed line that looks like a header
        +++ an added line that looks like a header

        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.oldPath == "Sources/main.swift" && file.newPath == "Sources/main.swift" && !file.isBinary)
        #expect(file.hunks.count == 2)

        let first = file.hunks[0]
        #expect(first.header == "@@ -1,3 +1,4 @@ import Foundation")
        #expect((first.oldStart, first.oldCount, first.newStart, first.newCount) == (1, 3, 1, 4))
        #expect(first.lines == [
            DiffLine(kind: .context, text: "line1", oldLine: 1, newLine: 1),
            DiffLine(kind: .deleted, text: "line2", oldLine: 2, newLine: nil),
            DiffLine(kind: .added, text: "line2 changed", oldLine: nil, newLine: 2),
            DiffLine(kind: .added, text: "inserted", oldLine: nil, newLine: 3),
            DiffLine(kind: .context, text: "line3", oldLine: 3, newLine: 4),
        ])

        let second = file.hunks[1]
        #expect(second.lines.map(\.kind) == [.context, .deleted, .added])
        #expect(second.lines[1] == DiffLine(kind: .deleted, text: "-- a removed line that looks like a header", oldLine: 11, newLine: nil))
        #expect(second.lines[2] == DiffLine(kind: .added, text: "++ an added line that looks like a header", oldLine: nil, newLine: 12))
    }

    @Test func newFileWithoutTrailingNewline() throws {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..3b18e51
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        \\ No newline at end of file

        """
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.oldPath == nil && file.newPath == "new.txt")
        let hunk = try #require(file.hunks.first)
        #expect((hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount) == (0, 0, 1, 1))
        #expect(hunk.lines == [
            DiffLine(kind: .added, text: "hello", oldLine: nil, newLine: 1),
            DiffLine(kind: .noNewlineMarker, text: "No newline at end of file", oldLine: nil, newLine: nil),
        ])
    }

    @Test func deletedFile() throws {
        let diff = """
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        index 3b18e51..0000000
        --- a/old.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -a
        -b

        """
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.oldPath == "old.txt" && file.newPath == nil)
        #expect(file.hunks.first?.lines.map(\.oldLine) == [1, 2])
    }

    @Test func emptyNewFileHasNoHunks() throws {
        let diff = "diff --git a/empty b/empty\nnew file mode 100644\nindex 0000000..e69de29\n"
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.oldPath == nil && file.newPath == "empty" && file.hunks.isEmpty)
    }

    @Test func pureRenameWithSimilarity() throws {
        let diff = """
        diff --git a/old name.txt b/dir/new name.txt
        similarity index 100%
        rename from old name.txt
        rename to dir/new name.txt

        """
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.oldPath == "old name.txt" && file.newPath == "dir/new name.txt")
        #expect(file.similarity == 100 && file.hunks.isEmpty)
    }

    @Test func renameWithEdits() throws {
        let diff = """
        diff --git a/a.txt b/b.txt
        similarity index 75%
        rename from a.txt
        rename to b.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/b.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        +new

        """
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.oldPath == "a.txt" && file.newPath == "b.txt" && file.similarity == 75)
        #expect(file.hunks.first?.lines.count == 3)
    }

    @Test func binaryFiles() throws {
        let diff = """
        diff --git a/image.png b/image.png
        index 1111111..2222222 100644
        Binary files a/image.png and b/image.png differ
        diff --git a/new.bin b/new.bin
        new file mode 100644
        index 0000000..2222222
        Binary files /dev/null and b/new.bin differ

        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files[0].isBinary && files[0].oldPath == "image.png" && files[0].newPath == "image.png" && files[0].hunks.isEmpty)
        #expect(files[1].isBinary && files[1].oldPath == nil && files[1].newPath == "new.bin")
    }

    @Test func noNewlineOnOldAndNewSides() throws {
        let diff = """
        diff --git a/f b/f
        index 1111111..2222222 100644
        --- a/f
        +++ b/f
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file

        """
        let lines = try #require(DiffParser.parse(diff).first?.hunks.first?.lines)
        #expect(lines.map(\.kind) == [.deleted, .noNewlineMarker, .added, .noNewlineMarker])
        #expect(lines[2].newLine == 1)
    }

    @Test func pathsWithSpacesAndQuotes() throws {
        let diff = """
        diff --git a/dir with space/file.txt b/dir with space/file.txt
        index 1111111..2222222 100644
        --- a/dir with space/file.txt\t
        +++ b/dir with space/file.txt\t
        @@ -1 +1 @@
        -a
        +b
        diff --git "a/caf\\303\\251 \\"q\\".txt" "b/caf\\303\\251 \\"q\\".txt"
        new file mode 100644
        index 0000000..2222222
        --- /dev/null
        +++ "b/caf\\303\\251 \\"q\\".txt"
        @@ -0,0 +1 @@
        +x

        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files[0].oldPath == "dir with space/file.txt" && files[0].newPath == "dir with space/file.txt")
        #expect(files[1].oldPath == nil && files[1].newPath == "café \"q\".txt")
    }

    @Test func headerOnlyPathWithSpaces() {
        #expect(DiffParser.parseGitHeader("a/x y b/x y") == ("x y", "x y"))
        #expect(DiffParser.parseGitHeader("a/old b/new") == ("old", "new"))
        #expect(DiffParser.parseGitHeader("\"a/t\\tab\" \"b/t\\tab\"") == ("t\tab", "t\tab"))
    }

    @Test func crlfContentIsKept() throws {
        let diff = "diff --git a/w.txt b/w.txt\nindex 1..2 100644\n--- a/w.txt\n+++ b/w.txt\n@@ -1 +1 @@\n-a\r\n+b\r\n"
        let lines = try #require(DiffParser.parse(diff).first?.hunks.first?.lines)
        #expect(lines.map(\.text) == ["a\r", "b\r"])
    }

    @Test func emptyInputAndModeOnlyChange() {
        #expect(DiffParser.parse("").isEmpty)
        let files = DiffParser.parse("diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n")
        #expect(files == [FileDiff(oldPath: "run.sh", newPath: "run.sh")])
    }
}
