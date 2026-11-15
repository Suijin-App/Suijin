import AppKit
import Testing
@testable import SuijinTerminal

@Suite("Pasting and dropping images on a terminal")
@MainActor
struct TerminalImagePasteTests {
    /// A folder of its own for each test, removed by `cleanUp`.
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("suijin-image-tests-\(UUID().uuidString)", isDirectory: true)
    private var store: TerminalImageStore { TerminalImageStore(directory: root.appendingPathComponent("PastedImages")) }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func pasteboard(_ write: (NSPasteboard) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("suijin.test.image.\(UUID().uuidString)"))
        pasteboard.clearContents()
        write(pasteboard)
        return pasteboard
    }

    private func makeView() -> (SuijinTerminalView, () -> [UInt8]) {
        let view = SuijinTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        var sent: [UInt8] = []
        view.onInput = { sent += $0 }
        view.imageStore = store
        return (view, { sent })
    }

    private func bitmap(width: Int = 4, height: Int = 3) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.setColor(.red, atX: 1, y: 1)
        return bitmap
    }

    private var png: Data { bitmap().representation(using: .png, properties: [:])! }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)) ?? []
    }

    @Test("a clipboard with only an image pastes as an image, PNG as it is and TIFF converted")
    func imageOnlyClipboard() throws {
        let pngBoard = pasteboard { $0.setData(png, forType: .png) }
        #expect(SuijinTerminalView.pasteContent(on: pngBoard) == .image(png))

        let tiffBoard = pasteboard { $0.setData(bitmap().tiffRepresentation!, forType: .tiff) }
        guard case .image(let converted) = SuijinTerminalView.pasteContent(on: tiffBoard) else {
            Issue.record("a TIFF on the clipboard is an image")
            return
        }
        let decoded = try #require(NSBitmapImageRep(data: converted))
        #expect(decoded.pixelsWide == 4 && decoded.pixelsHigh == 3)
        #expect(converted.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("text wins over an image copied with it, and an empty clipboard pastes nothing")
    func textAndEmptyClipboards() {
        let both = pasteboard {
            $0.declareTypes([.string, .png], owner: nil)
            $0.setString("echo hi", forType: .string)
            $0.setData(png, forType: .png)
        }
        #expect(SuijinTerminalView.pasteContent(on: both) == .text("echo hi"))
        #expect(SuijinTerminalView.pasteContent(on: pasteboard { _ in }) == .nothing)
        #expect(files().isEmpty)
    }

    @Test("a pasted image becomes a readable PNG file whose escaped path is pasted, bracketed when asked for")
    func pasteImageSavesAndPastesPath() throws {
        defer { cleanUp() }
        let (view, sent) = makeView()
        let file = try #require(view.pasteImage(png))
        #expect(file.deletingLastPathComponent().standardizedFileURL == store.directory.standardizedFileURL)
        #expect(file.lastPathComponent.hasPrefix("Pasted-") && file.pathExtension == "png")
        #expect(try Data(contentsOf: file) == png)
        #expect(sent() == Array(TerminalFileDrop.text(for: [file]).utf8))

        view.feed(text: "\u{1B}[?2004h")
        let before = sent().count
        let second = try #require(view.pasteImage(png))
        #expect(second != file)
        #expect(Array(sent()[before...]) == Array("\u{1B}[200~\(TerminalFileDrop.text(for: [second]))\u{1B}[201~".utf8))
        #expect(files().count == 2)
    }

    @Test("the folder is private to the user and so is each file")
    func permissions() throws {
        defer { cleanUp() }
        let file = try store.save(png: png)
        let manager = FileManager.default
        #expect(try manager.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test("without an image store, or when the file cannot be written, nothing is pasted")
    func nothingPastedWithoutAFile() throws {
        defer { cleanUp() }
        let (view, sent) = makeView()
        view.imageStore = nil
        #expect(view.pasteImage(png) == nil)

        // A file where the folder should be: the folder cannot be created.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: store.directory)
        view.imageStore = store
        #expect(view.pasteImage(png) == nil)
        #expect(sent().isEmpty)
    }

    @Test("dropped image data is saved and its path pasted")
    func dropOfImageData() throws {
        defer { cleanUp() }
        let (view, sent) = makeView()
        let image = pasteboard { $0.setData(bitmap().tiffRepresentation!, forType: .tiff) }
        #expect(view.canTakeFileDrop(from: image))
        #expect(view.takeFileDrop(from: image))
        let file = try #require(files().first)
        #expect(files().count == 1)
        #expect(NSBitmapImageRep(data: try Data(contentsOf: file)) != nil)
        // The listing spells the temporary folder `/private/var/…`; the pasted path is the store's own spelling.
        let pasted = store.directory.appendingPathComponent(file.lastPathComponent)
        #expect(sent() == Array(TerminalFileDrop.text(for: [pasted]).utf8))
    }

    @Test("a file dropped with an image of itself pastes the file's own path and saves nothing")
    func fileWinsOverImageData() {
        defer { cleanUp() }
        let (view, sent) = makeView()
        let drag = pasteboard {
            $0.writeObjects([URL(fileURLWithPath: "/tmp/shot.png") as NSURL])
            $0.addTypes([.png], owner: nil)
            $0.setData(png, forType: .png)
        }
        #expect(view.takeFileDrop(from: drag))
        #expect(sent() == Array("/tmp/shot.png".utf8))
        #expect(files().isEmpty)
    }

    @Test("a file in a temporary folder is one a promise replaces; a file anywhere else is pasted by its own path")
    func temporaryFiles() {
        let temporary = [
            "/var/folders/mn/abc/T/TemporaryItems/NSIRD_screencaptureui_yCb5uN/Screenshot 2026-11-15 at 15.56.25.png",
            "/private/var/folders/mn/abc/T/x.png", "/tmp/x.png", "/private/tmp/x.png",
            "/Users/me/Library/Caches/TemporaryItems/x.png",
        ]
        for path in temporary { #expect(SuijinTerminalView.isTemporaryFile(URL(fileURLWithPath: path)), "\(path)") }
        let lasting = ["/Users/me/Desktop/shot.png", "/Users/me/tmp/x.png", "/Volumes/Disk/a.png", "/Users/me/Screenshots/a.png"]
        for path in lasting { #expect(!SuijinTerminalView.isTemporaryFile(URL(fileURLWithPath: path)), "\(path)") }
    }

    @Test("an existing folder with wider permissions is made private when an image is saved")
    func existingFolderIsMadePrivate() throws {
        defer { cleanUp() }
        let manager = FileManager.default
        try manager.createDirectory(at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try store.save(png: png)
        #expect(try manager.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test("a promised drop pastes the files that arrived, and the drag's image when none did")
    func promisedDropOutcome() throws {
        defer { cleanUp() }
        let (view, sent) = makeView()
        let arrived = URL(fileURLWithPath: "/tmp/Dropped/Screenshot 1.png")
        view.finishPromisedDrop([arrived], fallbackImage: png)
        #expect(sent() == Array("/tmp/Dropped/Screenshot\\ 1.png".utf8))
        #expect(files().isEmpty)

        let before = sent().count
        view.finishPromisedDrop([], fallbackImage: png)
        let saved = try #require(files().first)
        #expect(try Data(contentsOf: saved) == png)
        #expect(sent().count > before)

        let afterFallback = sent().count
        view.finishPromisedDrop([], fallbackImage: nil)
        #expect(sent().count == afterFallback)
    }

    @Test("image data is refused without an image store, and a pane drag is refused with one")
    func refusedDrops() {
        defer { cleanUp() }
        let (view, sent) = makeView()
        let pane = pasteboard {
            $0.declareTypes([NSPasteboard.PasteboardType("com.tekmium.suijin.pane")], owner: nil)
            $0.setString(UUID().uuidString, forType: NSPasteboard.PasteboardType("com.tekmium.suijin.pane"))
        }
        #expect(!view.canTakeFileDrop(from: pane))
        #expect(!view.takeFileDrop(from: pane))

        let image = pasteboard { $0.setData(png, forType: .png) }
        view.imageStore = nil
        #expect(!view.canTakeFileDrop(from: image))
        #expect(!view.takeFileDrop(from: image))
        #expect(sent().isEmpty)
        #expect(files().isEmpty)
    }

    @Test("saved images older than a week are removed, newer ones kept")
    func expiry() throws {
        defer { cleanUp() }
        let now = Date()
        let old = try store.save(png: png, at: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let recent = try store.save(png: png, at: now)
        let oldDrop = try store.makeDropFolder()
        try png.write(to: oldDrop.appendingPathComponent("Screenshot.png"))
        let manager = FileManager.default
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        try manager.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: old.path)
        try manager.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: oldDrop.path)

        #expect(store.removeExpired(at: now) == 2)
        #expect(files().map(\.lastPathComponent) == [recent.lastPathComponent])
        // A store whose folder was never created has nothing to remove.
        #expect(TerminalImageStore(directory: root.appendingPathComponent("missing")).removeExpired(at: now) == 0)
    }

    @Test("two images saved in the same second get different names")
    func sameSecond() throws {
        defer { cleanUp() }
        let date = Date()
        let first = try store.save(png: png, at: date)
        let second = try store.save(png: png, at: date)
        #expect(first != second)
        #expect(second.lastPathComponent.hasSuffix("-2.png"))
    }
}
