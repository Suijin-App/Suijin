import AppKit
import Foundation
import Testing
@testable import SuijinTerminal

/// An engine the test drives by hand.
@MainActor
final class ScriptedEngine: TerminalEngine {
    var onOutput: (@MainActor (ArraySlice<UInt8>) -> Void)?
    var onExit: (@MainActor (Int32?) -> Void)?
    var sessionID: String? { nil }
    var consumed = 0
    var written: [UInt8] = []

    func start(_ launch: TerminalLaunch, size: TerminalSize) async throws {}
    func write(_ bytes: ArraySlice<UInt8>) { written.append(contentsOf: bytes) }
    func resize(_ size: TerminalSize) {}
    func terminate() async {}
    func outputConsumed(_ byteCount: Int) { consumed += byteCount }

    func emit(_ bytes: [UInt8]) { onOutput?(bytes[...]) }
    func exit(_ code: Int32?) { onExit?(code) }
}

/// `count` lines of 50 characters ("\r\n" included), as `yes '<48 chars>'` prints through a PTY.
func floodLines(_ count: Int) -> [UInt8] {
    let line = Array((String(repeating: "abcdefgh", count: 6) + "\r\n").utf8)
    return [[UInt8]](repeating: line, count: count).flatMap { $0 }
}

@Suite("Terminal feed scheduler", .serialized)
@MainActor
struct TerminalFeedSchedulerTests {
    private func makeSession(_ scheduler: TerminalFeedScheduler) async throws -> (TerminalSession, ScriptedEngine) {
        let engine = ScriptedEngine()
        let session = TerminalSession(engine: engine, scheduler: scheduler)
        try await session.start(launch("/bin/echo"))
        return (session, engine)
    }

    @Test("output is fed before the exit is delivered")
    func outputBeforeExit() async throws {
        let scheduler = TerminalFeedScheduler(budget: .milliseconds(1), chunkSize: 4 * 1024)
        let (session, engine) = try await makeSession(scheduler)
        var fedAtExit = -1
        session.onExit = { _ in fedAtExit = session.fedByteCount }
        let output = floodLines(4_000) + Array("LAST LINE\r\n".utf8)
        engine.emit(output)
        engine.exit(7)
        // Nothing is fed synchronously, and the exit waits for the output.
        #expect(session.pendingByteCount == output.count)
        #expect(!session.hasExited)
        #expect(await waitUntil { session.hasExited })
        #expect(fedAtExit == output.count)
        #expect(session.exitCode == 7)
        #expect(session.pendingByteCount == 0)
        #expect(session.view.visibleText().contains("LAST LINE"))
        #expect(scheduler.turnCount > 1)
    }

    @Test("an exit without pending output is delivered on the next turn")
    func exitWithoutOutput() async throws {
        let scheduler = TerminalFeedScheduler()
        let (session, engine) = try await makeSession(scheduler)
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        engine.exit(nil)
        engine.exit(3)
        #expect(await waitUntil { session.hasExited })
        #expect(exits == [nil])
        #expect(!session.isRunning)
    }

    @Test("sessions are fed round-robin, chunk by chunk")
    func fairness() async throws {
        let scheduler = TerminalFeedScheduler(budget: .milliseconds(5), chunkSize: 1_000)
        let (first, firstEngine) = try await makeSession(scheduler)
        let (second, secondEngine) = try await makeSession(scheduler)
        var order: [String] = []
        scheduler.chunkObserver = { session, _ in order.append(session === first ? "A" : "B") }
        firstEngine.emit(floodLines(200))   // 10 chunks
        secondEngine.emit(floodLines(60))   // 3 chunks
        #expect(await waitUntil { first.pendingByteCount == 0 && second.pendingByteCount == 0 })
        #expect(order.joined() == "ABABABAAAAAAA")
        #expect(first.fedByteCount == 10_000 && second.fedByteCount == 3_000)
    }

    @Test("outputConsumed reports exactly the bytes fed, and never scrollback")
    func consumptionTotals() async throws {
        let scheduler = TerminalFeedScheduler(budget: .milliseconds(2), chunkSize: 16 * 1024)
        let (session, engine) = try await makeSession(scheduler)
        engine.emit(floodLines(1_000))
        session.attached(scrollback: Array(floodLines(500)))
        engine.emit(floodLines(3_000))
        #expect(await waitUntil { session.pendingByteCount == 0 })
        #expect(engine.consumed == 4_000 * 50)
        #expect(session.fedByteCount == 4_500 * 50)
    }

    @Test("scrollback is shown before live output that arrived first")
    func scrollbackFirst() async throws {
        let scheduler = TerminalFeedScheduler()
        let (session, engine) = try await makeSession(scheduler)
        engine.emit(Array("live\r\n".utf8))
        session.attached(scrollback: Array("history\r\n".utf8))
        #expect(await waitUntil { session.pendingByteCount == 0 })
        let lines = session.view.visibleText().split(separator: "\n").map(String.init)
        #expect(Array(lines.prefix(2)) == ["history", "live"])
    }

    @Test("a restored session stays invisible while its scrollback replays, then shows at the end")
    func scrollbackReplayHidden() async throws {
        let scheduler = TerminalFeedScheduler(budget: .milliseconds(1), chunkSize: 4 * 1024)
        let (session, engine) = try await makeSession(scheduler)
        #expect(!session.view.isReplayingScrollback)
        session.attached(scrollback: Array(floodLines(2_000)))
        #expect(session.view.isReplayingScrollback && session.view.alphaValue == 0)
        engine.emit(Array("live\r\n".utf8))
        #expect(await waitUntil { session.pendingByteCount == 0 })
        #expect(!session.view.isReplayingScrollback && session.view.alphaValue == 1)
    }

    @Test("the scrollback of a session on screen replays before hidden ones")
    func visibleReplayFirst() async throws {
        let scheduler = TerminalFeedScheduler(budget: .milliseconds(1), chunkSize: 4 * 1024)
        let (hidden, _) = try await makeSession(scheduler)
        let (shown, _) = try await makeSession(scheduler)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = shown.view
        defer { window.contentView = nil }
        // The order chunks were fed in, recorded by the scheduler itself (polling would see whatever the rest of the
        // turn fed after the shown session finished).
        var order: [Bool] = []
        scheduler.chunkObserver = { session, _ in order.append(session === shown) }
        hidden.attached(scrollback: Array(floodLines(2_000)))
        shown.attached(scrollback: Array(floodLines(2_000)))
        #expect(await waitUntil { hidden.pendingByteCount == 0 && shown.pendingByteCount == 0 })
        // Every chunk of the shown session comes before any chunk of the hidden one.
        let lastShown = try #require(order.lastIndex(of: true))
        let firstHidden = try #require(order.firstIndex(of: false))
        #expect(lastShown < firstHidden, "chunk order: \(order.map { $0 ? "S" : "h" }.joined())")
    }

    @Test("feeding 20 MB never holds the main actor for long")
    func mainActorStaysResponsive() async throws {
        let scheduler = TerminalFeedScheduler()
        var sessions: [(TerminalSession, ScriptedEngine)] = []
        for _ in 0..<4 { sessions.append(try await makeSession(scheduler)) }
        for (_, engine) in sessions { engine.emit(floodLines(100_000)) }   // 4 x 5 MB
        #expect(scheduler.pendingByteCount == 20_000_000)

        // A main-actor ticker measures the longest stretch in which nothing else could run.
        let clock = ContinuousClock()
        var last = clock.now
        var longestGap: Duration = .zero
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                let now = clock.now
                longestGap = max(longestGap, now - last)
                last = now
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        let drained = await waitUntil(timeout: .seconds(120)) { scheduler.pendingByteCount == 0 }
        ticker.cancel()
        #expect(drained)
        for (session, engine) in sessions {
            #expect(session.fedByteCount == 5_000_000)
            #expect(engine.consumed == 5_000_000)
        }
        print("[feed] 20 MB in \(scheduler.turnCount) turns, longest turn \(scheduler.longestTurn), longest main-actor gap \(longestGap)")
        // The scheduler's own hold on the main actor per turn. The ticker's gap also contains main-actor work of
        // other suites running in parallel (the engine tests run Process synchronously there), so it is reported,
        // not asserted; run this test alone to see it stay near the turn length.
        #expect(scheduler.longestTurn < .milliseconds(50))
        #expect(scheduler.turnCount > 100)
    }
}
