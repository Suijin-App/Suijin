import AppKit
import Foundation
import SuijinGit
import Testing
@testable import Suijin

/// Image previews in the Changes view: which versions an image diff shows, where each is read from, and decoding.
struct ImageDiffTests {
    /// A PNG of `width` × `height` pixels, filled with `color`.
    private func png(width: Int, height: Int, color: NSColor) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<width { for y in 0..<height { bitmap.setColor(color, atX: x, y: y) } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private struct Repo {
        let root: URL
        let git = GitRunner()
        let identity = ["-c", "user.name=Suijin Tests", "-c", "user.email=tests@suijin.invalid", "-c", "commit.gpgsign=false"]

        init() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-image-diff-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            root = base
            _ = try await git.run(["init", "--quiet", "--initial-branch=main"], in: root)
        }

        func write(_ path: String, _ data: Data) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        func commitAll(_ message: String) async throws {
            _ = try await git.run(["add", "-A"], in: root)
            _ = try await git.run(identity + ["commit", "--quiet", "-m", message], in: root)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func onlyBinaryImagesArePreviewed() {
        #expect(ImageDiffSource.isImage(path: "a/logo.PNG"))
        for path in ["photo.jpeg", "x.jpg", "anim.gif", "shot.heic", "pic.webp", "scan.tiff", "old.bmp", "favicon.ico"] {
            #expect(ImageDiffSource.isImage(path: path), "\(path)")
        }
        #expect(!ImageDiffSource.isImage(path: "archive.zip"))
        #expect(!ImageDiffSource.isImage(path: "Makefile"))
        // A text diff of an image type (an SVG) stays a text diff.
        #expect(ImageDiffSource.sources(for: FileDiff(oldPath: "i.svg", newPath: "i.svg")).isEmpty)
        #expect(ImageDiffSource.sources(for: FileDiff(oldPath: "a.bin", newPath: "a.bin", isBinary: true)).isEmpty)
    }

    @Test func sourcesFollowTheKindOfChange() {
        #expect(ImageDiffSource.sources(for: FileDiff(oldPath: nil, newPath: "new.png", isBinary: true))
            == [ImageDiffSource(side: .new, path: "new.png")])
        #expect(ImageDiffSource.sources(for: FileDiff(oldPath: "gone.png", newPath: nil, isBinary: true))
            == [ImageDiffSource(side: .old, path: "gone.png")])
        #expect(ImageDiffSource.sources(for: FileDiff(oldPath: "a.png", newPath: "a.png", isBinary: true))
            == [ImageDiffSource(side: .old, path: "a.png"), ImageDiffSource(side: .new, path: "a.png")])
        #expect(ImageDiffSource.sources(for: FileDiff(oldPath: "old/a.png", newPath: "new/b.png", isBinary: true))
            == [ImageDiffSource(side: .old, path: "old/a.png"), ImageDiffSource(side: .new, path: "new/b.png")])
    }

    /// The real diffs git reports, read back through the sources: each version is the right image in each scope.
    @Test func sourcesReadTheRightVersions() async throws {
        let repo = try await Repo()
        defer { repo.cleanUp() }
        let red = try png(width: 4, height: 3, color: .red)
        let blue = try png(width: 6, height: 2, color: .blue)
        let green = try png(width: 5, height: 5, color: .green)
        try repo.write("logo.png", red)
        try repo.write("gone.png", try png(width: 9, height: 9, color: .yellow))
        try repo.write("move.png", red)
        try await repo.commitAll("base")
        _ = try await repo.git.run(["checkout", "--quiet", "-b", "feature"], in: repo.root)
        try repo.write("logo.png", blue)
        try await repo.commitAll("blue logo")
        try repo.write("logo.png", green)
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("gone.png"))
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("move.png"))
        try repo.write("moved.png", Data(red + [0, 0]))
        _ = try await repo.git.run(["add", "-A"], in: repo.root)
        try repo.write("fresh.png", blue)
        let service = DiffService(worktree: repo.root)

        func versions(_ path: String, _ scope: DiffScope) async throws -> [DiffSide: Data] {
            let diff = try await service.diff(for: path, scope: scope)
            var result: [DiffSide: Data] = [:]
            for source in ImageDiffSource.sources(for: diff) {
                result[source.side] = try await service.contents(of: source.path, side: source.side, scope: scope)
            }
            return result
        }

        #expect(try await versions("logo.png", .uncommitted) == [.old: blue, .new: green])
        #expect(try await versions("gone.png", .uncommitted) == [.old: try png(width: 9, height: 9, color: .yellow)])
        #expect(try await versions("fresh.png", .uncommitted) == [.new: blue])
        #expect(try await versions("moved.png", .uncommitted) == [.old: red, .new: Data(red + [0, 0])])
        #expect(try await versions("logo.png", .committed("main")) == [.old: red, .new: blue])
        let head = try await String(decoding: repo.git.run(["rev-parse", "HEAD"], in: repo.root), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try await versions("logo.png", .commit(head)) == [.old: red, .new: blue])
    }

    @Test func decodingReportsPixelSizeAndRejectsDamagedData() throws {
        let data = try png(width: 7, height: 3, color: .orange)
        let decoded = try #require(DecodedImage.decode(data))
        #expect(decoded.pixelWidth == 7 && decoded.pixelHeight == 3 && decoded.byteCount == data.count)
        #expect(DecodedImage.decode(Data("not an image".utf8)) == nil)
        #expect(DecodedImage.decode(data.prefix(20)) == nil)
    }
}
