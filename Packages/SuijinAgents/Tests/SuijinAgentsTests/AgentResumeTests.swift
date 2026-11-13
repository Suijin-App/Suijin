import Foundation
import SuijinCore
import Testing
@testable import SuijinAgents

struct AgentResumeTests {
    static let claudeID = "0f4c3a52-7d1e-4b8a-9c2d-5e6f7a8b9c0d"
    static let codexID = "019a5f3e-8c2b-7d41-a9e0-3b6c1d2e4f50"

    @Test func resumeArguments() {
        #expect(AgentResume.arguments(kind: .claude, sessionID: Self.claudeID) == ["--resume", Self.claudeID])
        #expect(AgentResume.arguments(kind: .codex, sessionID: Self.codexID) == ["resume", Self.codexID])
        #expect(AgentResume.arguments(kind: .shell, sessionID: Self.claudeID).isEmpty)
        #expect(AgentResume.arguments(kind: .claude, sessionID: nil).isEmpty)
        // An id that would read as an option, or holds anything a shell would interpret, is not passed on.
        #expect(AgentResume.arguments(kind: .claude, sessionID: "--dangerously-skip-permissions").isEmpty)
        #expect(AgentResume.arguments(kind: .codex, sessionID: "abc; rm -rf ~").isEmpty)
    }

    @Test func launchSpecsResumeAfterTheSettingsAndBeforeAPrompt() {
        let hooks = ClaudeHooks.Installation(settingsFile: URL(fileURLWithPath: "/data/hooks/claude-settings.json"),
                                             eventsDirectory: URL(fileURLWithPath: "/data/hooks/events"))
        let claude = AgentLaunchSpecBuilder.make(kind: .claude, binary: URL(fileURLWithPath: "/bin/claude"), cwd: URL(fileURLWithPath: "/w"),
                                                 env: EnvPatch(), initialPrompt: nil, hooks: hooks, sessionID: UUID(),
                                                 resume: Self.claudeID)
        #expect(claude.arguments == ["--settings", "/data/hooks/claude-settings.json", "--resume", Self.claudeID])
        let codex = AgentLaunchSpecBuilder.make(kind: .codex, binary: URL(fileURLWithPath: "/bin/codex"), cwd: URL(fileURLWithPath: "/w"),
                                                env: EnvPatch(), initialPrompt: nil, hooks: nil, resume: Self.codexID)
        #expect(codex.arguments == ["resume", Self.codexID])
        let fresh = AgentLaunchSpecBuilder.make(kind: .codex, binary: URL(fileURLWithPath: "/bin/codex"), cwd: URL(fileURLWithPath: "/w"),
                                                env: EnvPatch(), initialPrompt: "hi", hooks: nil)
        #expect(fresh.arguments == ["hi"])
    }

    @Test func idsFromTheExitHints() {
        let claude = """
        > Press Ctrl-C again to exit

        Resume this session with:
        claude --resume \(Self.claudeID)
        """
        #expect(AgentResume.sessionID(inExitText: claude, kind: .claude) == Self.claudeID)
        // Codex's line, and the other agent's hint does not count.
        let codex = "Token usage: total=1200\nTo continue this session, run codex resume \(Self.codexID)"
        #expect(AgentResume.sessionID(inExitText: codex, kind: .codex) == Self.codexID)
        #expect(AgentResume.sessionID(inExitText: codex, kind: .claude) == nil)
        #expect(AgentResume.sessionID(inExitText: claude, kind: .codex) == nil)
        // The last hint wins (an earlier session's hint can still be in the scrollback).
        let two = "claude --resume 11111111-2222-3333-4444-555555555555\n…\nclaude --resume \(Self.claudeID)"
        #expect(AgentResume.sessionID(inExitText: two, kind: .claude) == Self.claudeID)
        #expect(AgentResume.sessionID(inExitText: "claude --resume not-an-id", kind: .claude) == nil)
        #expect(AgentResume.sessionID(inExitText: claude, kind: .shell) == nil)
    }

    @Test func hookEventsCarryTheClaudeSessionID() {
        let line = #"{"hook_event_name":"SessionStart","session_id":"\#(Self.claudeID)","source":"startup"}"#
        #expect(ClaudeHooks.parseEvents(Data(line.utf8)).first?.sessionID == Self.claudeID)
        let bad = #"{"hook_event_name":"Stop","session_id":"-x"}"#
        #expect(ClaudeHooks.parseEvents(Data(bad.utf8)).first?.sessionID == nil)
    }
}
