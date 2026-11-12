import AppKit
import Foundation
import Testing
@testable import MercuryTerminal

@Suite("Key routing")
struct TerminalKeyRoutingTests {
    @Test("⌘ shortcuts")
    func commandShortcuts() {
        let table: [(String, NSEvent.ModifierFlags, TerminalKeyRoute)] = [
            ("t", [.command], .newTab), ("w", [.command], .closeTab), ("d", [.command], .splitRight),
            ("D", [.command, .shift], .splitDown), ("{", [.command, .shift], .previousTab), ("]", [.command, .shift], .nextTab),
            ("c", [.command], .copy), ("v", [.command], .paste), ("a", [.command], .selectAll), ("f", [.command], .find),
            ("1", [.command], .app), (",", [.command], .app), ("q", [.command], .app), ("k", [.command, .option], .app),
        ]
        for (key, modifiers, route) in table {
            #expect(TerminalKeyRouter.route(key: key, modifiers: modifiers) == route, "\(key) \(modifiers)")
        }
    }

    @Test("pane shortcuts never reach the program")
    func paneShortcuts() {
        func key(_ code: Int) -> String { String(UnicodeScalar(UInt16(code))!) }
        // Arrow keys arrive with the numeric-pad and function flags, which do not count.
        let arrows: NSEvent.ModifierFlags = [.command, .option, .numericPad, .function]
        #expect(TerminalKeyRouter.route(key: key(NSLeftArrowFunctionKey), modifiers: arrows) == .focusPane(.left))
        #expect(TerminalKeyRouter.route(key: key(NSRightArrowFunctionKey), modifiers: arrows) == .focusPane(.right))
        #expect(TerminalKeyRouter.route(key: key(NSUpArrowFunctionKey), modifiers: arrows) == .focusPane(.up))
        #expect(TerminalKeyRouter.route(key: key(NSDownArrowFunctionKey), modifiers: arrows) == .focusPane(.down))
        #expect(TerminalKeyRouter.route(key: "\r", modifiers: [.command, .shift]) == .zoomPane)
        #expect(TerminalKeyRouter.route(key: "=", modifiers: [.command, .control]) == .equalizePanes)
        // ⌘↩ and ⌘= stay with the app's menus; ⌥ arrows without ⌘ stay with the terminal (word moves).
        #expect(TerminalKeyRouter.route(key: "\r", modifiers: [.command]) == .app)
        #expect(TerminalKeyRouter.route(key: "=", modifiers: [.command]) == .app)
        #expect(TerminalKeyRouter.route(key: key(NSLeftArrowFunctionKey), modifiers: [.option, .numericPad, .function]) == .terminal)
    }

    @Test("keys without ⌘ stay with the terminal (input methods included)")
    func plainKeys() {
        #expect(TerminalKeyRouter.route(key: "c", modifiers: [.control]) == .terminal)
        #expect(TerminalKeyRouter.route(key: "a", modifiers: [.option]) == .terminal)
        #expect(TerminalKeyRouter.route(key: "ư", modifiers: []) == .terminal)
    }
}

@Suite("Themes")
struct TerminalThemeTests {
    @Test("themes are complete and resolve with fallbacks")
    func themes() {
        #expect(Set(TerminalThemes.all.map(\.id)).count == TerminalThemes.all.count)
        #expect(TerminalThemes.all.allSatisfy { $0.ansi.count == 16 })
        #expect(TerminalThemes.resolve(id: "nord", isDark: false).id == "nord")
        #expect(TerminalThemes.resolve(id: "missing", isDark: true).id == "mercury-dark")
        #expect(TerminalThemes.resolve(id: nil, isDark: false).id == "mercury-light")
        #expect(TerminalThemes.all.allSatisfy { TerminalRGB.contrast($0.foreground, $0.background) >= 4.5 })
    }
}

@Suite("Shell launch")
struct ShellLaunchTests {
    @Test("base environment strips launch-context variables and sets terminal ones")
    func baseEnvironment() {
        let env = ShellLaunch.baseEnvironment(from: [
            "HOME": "/Users/me", "PATH": "/usr/bin:/bin", "XPC_SERVICE_NAME": "x", "__CFBundleIdentifier": "y",
            "DYLD_INSERT_LIBRARIES": "z", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "LANG": "C",
            "TERM": "dumb", "MERCURY_USER_ZDOTDIR": "/stale", "CLAUDE_CONFIG_DIR": "/kept",
        ])
        #expect(env["XPC_SERVICE_NAME"] == nil && env["__CFBundleIdentifier"] == nil && env["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(env["CLAUDECODE"] == nil && env["CLAUDE_CODE_ENTRYPOINT"] == nil && env["MERCURY_USER_ZDOTDIR"] == nil)
        #expect(env["CLAUDE_CONFIG_DIR"] == "/kept")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "Mercury")
        #expect(env["MERCURY_TERMINAL"] == "1")
        #expect(env["LANG"]?.hasSuffix(".UTF-8") == true)
        #expect(env["MERCURY_DATA_ROOT"]?.hasSuffix("/Library/Application Support/Mercury") == true)
        #expect(ShellLaunch.baseEnvironment(from: ["LANG": "vi_VN.UTF-8"])["LANG"] == "vi_VN.UTF-8")
        #expect(ShellLaunch.baseEnvironment(from: ["MERCURY_DATA_ROOT": "/tmp/m"])["MERCURY_DATA_ROOT"] == "/tmp/m")
        // macOS ships no vi_VN locale on every release; UTF-8 LC_CTYPE is what Vietnamese text needs either way.
        let vietnamese = FileManager.default.fileExists(atPath: "/usr/share/locale/vi_VN.UTF-8") ? "vi_VN.UTF-8" : "en_US.UTF-8"
        #expect(ShellLaunch.utf8Locale(Locale(identifier: "vi_VN")) == vietnamese)
        #expect(ShellLaunch.utf8Locale(Locale(identifier: "en_US")) == "en_US.UTF-8")
    }

    @Test("userShell is an executable login shell")
    func userShell() {
        #expect(FileManager.default.isExecutableFile(atPath: ShellLaunch.userShell()))
    }

    @Test("command runs through the login shell and keeps its arguments")
    @MainActor
    func command() async throws {
        let launch = ShellLaunch.command("/bin/echo", ["two words", "$HOME"], cwd: URL(fileURLWithPath: "/tmp"),
                                         environment: ["EXTRA": "1"])
        #expect(launch.arguments.contains("-c"))
        #expect(launch.arguments.suffix(3) == ["/bin/echo", "two words", "$HOME"])
        #expect(launch.environment["EXTRA"] == "1")
        #expect(launch.cwd == "/tmp")

        // The arguments arrive verbatim, unexpanded.
        let engine = SwiftTermEngine()
        let recorder = EngineRecorder()
        recorder.attach(to: engine)
        try await engine.start(launch, size: TerminalSize(cols: 80, rows: 24))
        #expect(await waitUntil { !recorder.exits.isEmpty })
        #expect(recorder.text.contains("two words $HOME"))
        #expect(recorder.exits == [0])
    }
}

@Suite("Terminal session")
@MainActor
struct TerminalSessionTests {
    @Test("binds engine output to the view, view input to the engine, and reports the exit")
    func binding() async throws {
        let session = TerminalSession(engine: SwiftTermEngine())
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        let size = session.view.gridSize
        try await session.start(launch("/bin/sh", ["-c", "read line; stty size; printf 'got=%s\\n' \"$line\""]))
        #expect(session.isRunning)
        // Typing goes through the view, as a keystroke would.
        session.view.send(txt: "xin chào\r")
        #expect(await waitUntil { !exits.isEmpty })
        #expect(exits == [0])
        #expect(!session.isRunning && session.hasExited && session.exitCode == 0)
        let screen = session.view.visibleText()
        #expect(screen.contains("got=xin chào"))
        #expect(screen.contains("\(size.rows) \(size.cols)"))
        session.send("ignored after exit")
        await session.terminate()
    }

    @Test("terminate ends a running session")
    func terminate() async throws {
        let session = TerminalSession(engine: SwiftTermEngine())
        try await session.start(launch("/bin/sh", ["-c", "sleep 100; :"]))
        await session.terminate()
        #expect(session.hasExited)
        #expect(session.exitCode == 128 + SIGHUP)
    }
}

@Suite("Terminal view resizing")
@MainActor
struct TerminalViewResizeTests {
    @Test("an animated size reflows the grid a few times, not every frame, and ends on the last size")
    func animatedResizeIsCoalesced() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let view = MercuryTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView?.addSubview(view)
        var gridChanges: [TerminalSize] = []
        view.onSizeChange = { gridChanges.append($0) }
        // Sixty frames of a width animating from 1200 to 900 points, as the inspector sliding in does.
        for frame in 0...60 {
            view.setFrameSize(NSSize(width: 1200 - CGFloat(frame) * 5, height: 700))
        }
        #expect(gridChanges.count == 1)
        #expect(await waitUntil(timeout: .seconds(2)) { view.frame.size == NSSize(width: 900, height: 700) })
        let final = try #require(gridChanges.last)
        #expect(gridChanges.count == 2)
        #expect(view.gridSize == final)
    }

    @Test("a single change, and any change outside a window, applies at once")
    func singleChangeIsImmediate() {
        let view = MercuryTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.setFrameSize(NSSize(width: 1000, height: 700))
        view.setFrameSize(NSSize(width: 900, height: 700))
        #expect(view.frame.size == NSSize(width: 900, height: 700))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView?.addSubview(view)
        view.setFrameSize(NSSize(width: 1100, height: 700))
        #expect(view.frame.size == NSSize(width: 1100, height: 700))
    }
}
