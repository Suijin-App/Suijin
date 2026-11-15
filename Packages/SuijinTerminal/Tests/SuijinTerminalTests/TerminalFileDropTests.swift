import AppKit
import Testing
@testable import SuijinTerminal

@Suite("Dropping files on a terminal")
struct TerminalFileDropTests {
    @Test("paths are escaped as Terminal.app escapes them", arguments: [
        ("/Users/me/shot.png", "/Users/me/shot.png"),
        ("/Users/me/Screen Shot 2026-11-13 at 9.41.02.png", "/Users/me/Screen\\ Shot\\ 2026-11-13\\ at\\ 9.41.02.png"),
        ("/tmp/it's \"quoted\".txt", "/tmp/it\\'s\\ \\\"quoted\\\".txt"),
        ("/tmp/$HOME `id` (1) [a] {b} *?.md", "/tmp/\\$HOME\\ \\`id\\`\\ \\(1\\)\\ \\[a\\]\\ \\{b\\}\\ \\*\\?.md"),
        ("/tmp/a&b;c|d<e>f!g#h^i~j\\k", "/tmp/a\\&b\\;c\\|d\\<e\\>f\\!g\\#h\\^i\\~j\\\\k"),
        ("/tmp/v1.2_x-y+z,a:b@c%d=e", "/tmp/v1.2_x-y+z,a:b@c%d=e"),
        ("/Users/me/Ảnh chụp/日本語 ファイル.png", "/Users/me/Ảnh\\ chụp/日本語\\ ファイル.png"),
    ])
    func escaping(path: String, expected: String) {
        #expect(TerminalFileDrop.escape(path) == expected)
    }

    @Test("a name with a line break or tab is ANSI-C quoted, so the paste stays one line")
    func controlCharacters() {
        #expect(TerminalFileDrop.escape("/tmp/two\nlines.txt") == "$'/tmp/two\\nlines.txt'")
        #expect(TerminalFileDrop.escape("/tmp/tab\there's\\.txt") == "$'/tmp/tab\\there\\'s\\\\.txt'")
        #expect(TerminalFileDrop.escape("/tmp/bell\u{07}") == "$'/tmp/bell\\x07'")
        let text = TerminalFileDrop.text(for: [URL(fileURLWithPath: "/tmp/a\nb")])
        #expect(!text.contains("\n") && !text.contains("\r"))
    }

    @Test("several files become several paths separated by single spaces, folders without their trailing slash")
    func multipleFiles() {
        let urls = [URL(fileURLWithPath: "/tmp/a b.png"), URL(fileURLWithPath: "/tmp/dir/", isDirectory: true),
                    URL(string: "https://example.com/x.png")!, URL(fileURLWithPath: "/")]
        #expect(TerminalFileDrop.text(for: urls) == "/tmp/a\\ b.png /tmp/dir /")
        #expect(TerminalFileDrop.text(for: []) == "")
    }

    @Test("delivery is a paste: markers only with bracketed paste, never a Return")
    func deliveryBytes() {
        let text = "/tmp/a\\ b.png /tmp/c.png"
        #expect(TerminalFileDrop.bytes(for: text, bracketedPaste: false) == Array(text.utf8))
        #expect(TerminalFileDrop.bytes(for: text, bracketedPaste: true)
                == Array("\u{1B}[200~".utf8) + Array(text.utf8) + Array("\u{1B}[201~".utf8))
        for bracketed in [false, true] {
            let bytes = TerminalFileDrop.bytes(for: text, bracketedPaste: bracketed)
            #expect(!bytes.contains(0x0D) && !bytes.contains(0x0A))
        }
    }

    // MARK: The view as a drop destination

    @MainActor
    private func pasteboard(_ write: (NSPasteboard) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("suijin.test.drop.\(UUID().uuidString)"))
        pasteboard.clearContents()
        write(pasteboard)
        return pasteboard
    }

    @MainActor
    private func makeView() -> (SuijinTerminalView, () -> [UInt8]) {
        let view = SuijinTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        var sent: [UInt8] = []
        view.onInput = { sent += $0 }
        return (view, { sent })
    }

    @MainActor
    @Test("the terminal registers for files, promised files and image data, and for nothing a pane or tab drag carries")
    func registeredTypes() {
        let (view, _) = makeView()
        let types = Set(view.registeredDraggedTypes)
        #expect(types.isSuperset(of: [.fileURL, .png, .tiff]))
        #expect(types.isSuperset(of: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }))
        #expect(!types.contains(.string))
        #expect(!types.contains(NSPasteboard.PasteboardType("com.tekmium.suijin.pane")))
    }

    @MainActor
    @Test("a file drop pastes its paths, bracketed once the program asks for it")
    func dropPastes() throws {
        let (view, sent) = makeView()
        let files = pasteboard { $0.writeObjects([URL(fileURLWithPath: "/tmp/my shot.png") as NSURL,
                                                  URL(fileURLWithPath: "/tmp/b.txt") as NSURL]) }
        #expect(view.takeFileDrop(from: files))
        #expect(sent() == Array("/tmp/my\\ shot.png /tmp/b.txt".utf8))

        view.feed(text: "\u{1B}[?2004h")
        #expect(view.isBracketedPasteMode)
        let before = sent().count
        #expect(view.takeFileDrop(from: files))
        #expect(Array(sent()[before...]) == Array("\u{1B}[200~/tmp/my\\ shot.png /tmp/b.txt\u{1B}[201~".utf8))
    }

    @MainActor
    @Test("pane and tab drags, text and web links are refused and send nothing")
    func otherDragsRefused() {
        let (view, sent) = makeView()
        let pane = pasteboard {
            $0.declareTypes([NSPasteboard.PasteboardType("com.tekmium.suijin.pane")], owner: nil)
            $0.setString(UUID().uuidString, forType: NSPasteboard.PasteboardType("com.tekmium.suijin.pane"))
        }
        let tab = pasteboard { $0.setString("file:/tmp/a.swift", forType: .string) }
        let web = pasteboard { $0.writeObjects([URL(string: "https://example.com/a.png")! as NSURL]) }
        for refused in [pane, tab, web] {
            #expect(!view.canTakeFileDrop(from: refused))
            #expect(!view.takeFileDrop(from: refused))
        }
        #expect(sent().isEmpty)
    }

    @MainActor
    @Test("a host that refuses drops (a reconnecting session), a scrollback replay and a catch-up take nothing")
    func refusedWhileUnavailable() {
        let (view, sent) = makeView()
        let files = pasteboard { $0.writeObjects([URL(fileURLWithPath: "/tmp/a.png") as NSURL]) }
        var accepts = false
        view.acceptsFileDrop = { accepts }
        #expect(!view.takeFileDrop(from: files))
        accepts = true
        view.isReplayingScrollback = true
        #expect(!view.takeFileDrop(from: files))
        view.isReplayingScrollback = false
        view.isCatchingUp = true
        #expect(!view.takeFileDrop(from: files))
        view.isCatchingUp = false
        #expect(sent().isEmpty)
        #expect(view.takeFileDrop(from: files))
        #expect(sent() == Array("/tmp/a.png".utf8))
        view.removeHandlers()
        #expect(view.acceptsFileDrop == nil)
    }

    @MainActor
    @Test("the drop highlight is shown and hidden")
    func highlight() {
        let (view, _) = makeView()
        #expect(!view.showsFileDropHighlight)
        view.showsFileDropHighlight = true
        #expect(view.showsFileDropHighlight)
        view.showsFileDropHighlight = false
        #expect(!view.showsFileDropHighlight)

        // In a container the ring goes around the terminal, in the container's layer, and leaves with the drag.
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
        container.wantsLayer = true
        view.frame.origin = CGPoint(x: 10, y: 10)
        container.addSubview(view)
        view.showsFileDropHighlight = true
        let ring = container.layer?.sublayers?.first { $0.name == "suijin.fileDropHighlight" }
        #expect(ring?.frame == view.frame.insetBy(dx: -4, dy: -4))
        view.showsFileDropHighlight = false
        #expect(!(container.layer?.sublayers ?? []).contains { $0.name == "suijin.fileDropHighlight" })
    }
}
