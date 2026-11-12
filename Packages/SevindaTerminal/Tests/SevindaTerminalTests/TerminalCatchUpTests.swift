import AppKit
import Foundation
import Testing
@testable import SevindaTerminal

/// A resumed agent re-prints its whole conversation as it starts. The screen stays hidden until that output settles,
/// so it appears once, already at its end, instead of scrolling through the history.
@Suite("Terminal catch-up", .serialized)
@MainActor
struct TerminalCatchUpTests {
    private func makeSession(_ scheduler: TerminalFeedScheduler = TerminalFeedScheduler()) async throws
        -> (TerminalSession, ScriptedEngine) {
        let engine = ScriptedEngine()
        let session = TerminalSession(engine: engine, scheduler: scheduler)
        try await session.start(launch("/bin/echo"))
        return (session, engine)
    }

    @Test("the screen stays hidden through the burst and shows at its end once output pauses")
    func revealsAtTheEndAfterTheBurst() async throws {
        let (session, engine) = try await makeSession()
        var changes: [Bool] = []
        session.view.onCatchUpChange = { changes.append($0) }
        session.catchUp(quiet: .milliseconds(200), limit: .seconds(3))
        #expect(session.view.isCatchingUp && session.view.alphaValue == 0)

        // Nothing printed yet (the agent is still starting): no quiet period counts before the first output.
        try await Task.sleep(for: .milliseconds(400))
        #expect(session.view.isCatchingUp, "revealed before the agent printed anything")

        // The history arrives in a few bursts closer together than the quiet period.
        for part in 0..<4 {
            engine.emit(floodLines(1_000))
            if part == 3 { engine.emit(Array("END OF HISTORY\r\n".utf8)) }
            try await Task.sleep(for: .milliseconds(60))
            #expect(session.view.isCatchingUp, "revealed in the middle of the history")
        }
        #expect(await waitUntil(timeout: .seconds(2)) { !session.view.isCatchingUp })
        #expect(session.view.alphaValue == 1)
        #expect(changes == [true, false])
        // Shown at the end: the last line printed is on screen, not the top of the history.
        #expect(session.view.visibleText().contains("END OF HISTORY"))
        #expect(session.pendingByteCount == 0)
    }

    @Test("a few setup bytes and a pause do not count as the history having printed")
    func setupBytesBeforeTheHistory() async throws {
        let (session, engine) = try await makeSession()
        session.catchUp(quiet: .milliseconds(200), quietBeforeScreenful: .milliseconds(750), limit: .seconds(3))
        // Terminal setup (bracketed paste, a title) as an agent starts, then a pause longer than `quiet`.
        engine.emit(Array("\u{1B}[?2004h\u{1B}]0;Claude\u{07}".utf8))
        try await Task.sleep(for: .milliseconds(450))
        #expect(session.view.isCatchingUp, "revealed before the history came")
        engine.emit(floodLines(2_000) + Array("END OF HISTORY\r\n".utf8))
        #expect(await waitUntil(timeout: .seconds(2)) { !session.view.isCatchingUp })
        #expect(session.view.visibleText().contains("END OF HISTORY"))
    }

    @Test("a busy main thread does not count as the program being silent")
    func stalledMainThread() async throws {
        let (session, engine) = try await makeSession()
        session.catchUp(quiet: .milliseconds(300), limit: .seconds(3))
        engine.emit(floodLines(1_000))
        #expect(await waitUntil(timeout: .seconds(1)) { session.pendingByteCount == 0 })
        try await Task.sleep(for: .milliseconds(100))
        // The main thread is held while the rest of the history waits to be delivered: by the clock the program has
        // been silent for longer than `quiet` (100 + 400 ms), but the checks saw a quiet main actor for about 125 ms.
        usleep(400_000)
        // The check that came due during the stall runs before the held-back output is delivered.
        await Task.yield()
        await Task.yield()
        #expect(session.view.isCatchingUp, "revealed right after the stall, before the rest of the history")
        engine.emit(floodLines(1_000) + Array("END OF HISTORY\r\n".utf8))
        #expect(await waitUntil(timeout: .seconds(2)) { !session.view.isCatchingUp })
        #expect(session.view.visibleText().contains("END OF HISTORY"))
    }

    @Test("a program that never pauses is shown after the limit")
    func revealsAfterTheLimit() async throws {
        let (session, engine) = try await makeSession()
        session.catchUp(quiet: .milliseconds(200), limit: .milliseconds(600))
        let start = ContinuousClock.now
        while session.view.isCatchingUp, ContinuousClock.now - start < .seconds(3) {
            engine.emit(floodLines(20))
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!session.view.isCatchingUp)
        #expect(ContinuousClock.now - start < .milliseconds(1_500))
    }

    @Test("a program that prints nothing is shown after the limit")
    func revealsWithoutOutput() async throws {
        let (session, _) = try await makeSession()
        session.catchUp(quiet: .milliseconds(100), limit: .milliseconds(400))
        #expect(await waitUntil(timeout: .seconds(2)) { !session.view.isCatchingUp })
    }

    @Test("an exit shows the screen at once")
    func revealsOnExit() async throws {
        let (session, engine) = try await makeSession()
        session.catchUp(quiet: .seconds(1), limit: .seconds(3))
        engine.emit(Array("bye\r\n".utf8))
        engine.exit(0)
        #expect(await waitUntil(timeout: .seconds(1)) { session.hasExited })
        #expect(!session.view.isCatchingUp && session.view.alphaValue == 1)
    }

    @Test("input typed while hidden reaches the program")
    func inputWhileHidden() async throws {
        let (session, engine) = try await makeSession()
        session.catchUp(quiet: .milliseconds(200), limit: .seconds(3))
        engine.emit(floodLines(500))
        session.view.send(txt: "typed meanwhile")
        #expect(session.view.isCatchingUp)
        #expect(String(decoding: engine.written, as: UTF8.self) == "typed meanwhile")
        #expect(await waitUntil(timeout: .seconds(2)) { !session.view.isCatchingUp })
    }

    @Test("a hidden burst is fed ahead of other sessions' live output")
    func burstFedFirst() async throws {
        let scheduler = TerminalFeedScheduler(budget: .milliseconds(1), chunkSize: 4 * 1024)
        let (other, otherEngine) = try await makeSession(scheduler)
        let (resumed, resumedEngine) = try await makeSession(scheduler)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = resumed.view
        defer { window.contentView = nil }
        var order: [Bool] = []
        scheduler.chunkObserver = { session, _ in order.append(session === resumed) }
        resumed.catchUp(quiet: .milliseconds(200), limit: .seconds(3))
        otherEngine.emit(floodLines(2_000))
        resumedEngine.emit(floodLines(2_000))
        #expect(await waitUntil { other.pendingByteCount == 0 && resumed.pendingByteCount == 0 })
        let lastResumed = try #require(order.lastIndex(of: true))
        // The other session got at most its first chunk in before the burst took the line.
        #expect(order.prefix(lastResumed).filter { !$0 }.count <= 1)
    }
}
