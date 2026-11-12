import AppKit
import Foundation
import Testing
@testable import SevindaTerminal

/// Programs such as Codex ask for the terminal's background (OSC 11) as they start and pick a light or dark palette
/// from the answer, so a session must answer with its theme from the very first byte.
@Suite("Terminal color queries", .serialized)
@MainActor
struct TerminalColorQueryTests {
    /// The 16-bit channels of an `OSC 11 ; rgb:rrrr/gggg/bbbb` reply.
    private func backgroundReply(theme: TerminalTheme?) async throws -> [Int] {
        let engine = ScriptedEngine()
        let session = TerminalSession(engine: engine, scheduler: TerminalFeedScheduler(), theme: theme)
        try await session.start(launch("/bin/echo"))
        engine.emit(Array("\u{1b}]11;?\u{1b}\\".utf8))
        #expect(await waitUntil { !engine.written.isEmpty })
        let reply = String(decoding: engine.written, as: UTF8.self)
        let spec = try #require(reply.range(of: "11;rgb:").map { reply[$0.upperBound...] })
        return spec.prefix(14).split(separator: "/").compactMap { Int($0, radix: 16) }
    }

    @Test("a light theme answers the background query with its light background")
    func lightThemeAnswersLight() async throws {
        let channels = try await backgroundReply(theme: TerminalThemes.mercuryLight)
        #expect(channels.count == 3)
        #expect(channels.allSatisfy { $0 > 0xC000 })
    }

    @Test("a dark theme answers with its dark background")
    func darkThemeAnswersDark() async throws {
        let channels = try await backgroundReply(theme: TerminalThemes.mercuryDark)
        #expect(channels.count == 3)
        #expect(channels.allSatisfy { $0 < 0x4000 })
    }
}
