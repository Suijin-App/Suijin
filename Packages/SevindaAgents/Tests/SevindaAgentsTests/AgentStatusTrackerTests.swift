import Foundation
import SevindaCore
import Testing
@testable import SevindaAgents

@MainActor
@Suite struct AgentStatusTrackerTests {
    final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    let clock = Clock()

    func makeTracker() -> (AgentStatusTracker, () -> [AgentActivity]) {
        let clock = self.clock
        let tracker = AgentStatusTracker(idleThreshold: 8, clock: { clock.now })
        var changes: [AgentActivity] = []
        tracker.onChange = { changes.append($0) }
        return (tracker, { changes })
    }

    @Test func outputThenIdleTimeout() {
        let (tracker, changes) = makeTracker()
        #expect(tracker.activity == .starting)
        tracker.tick(now: clock.now.addingTimeInterval(60))
        #expect(tracker.activity == .starting, "no output yet: stays starting")

        tracker.noteOutput(at: clock.now)
        #expect(tracker.activity == .running)
        tracker.noteOutput(at: clock.now.addingTimeInterval(1))
        tracker.tick(now: clock.now.addingTimeInterval(8.5))
        #expect(tracker.activity == .running, "8 s not yet elapsed since the last output")
        tracker.tick(now: clock.now.addingTimeInterval(9))
        #expect(tracker.activity == .idle)

        tracker.noteOutput(at: clock.now.addingTimeInterval(10))
        #expect(tracker.activity == .running, "timeout idle resumes on any output")
        #expect(changes() == [.running, .idle, .running], "onChange fires only on transitions")
    }

    @Test func notificationWaitsUntilInputThenOutput() {
        let (tracker, _) = makeTracker()
        tracker.noteOutput(at: clock.now)
        clock.advance(2)
        tracker.noteHookEvent(ClaudeHookEvent(name: "Notification", message: "Claude needs your permission", notificationType: "permission_prompt"))
        #expect(tracker.activity == .waitingForInput)

        tracker.noteOutput(at: clock.now.addingTimeInterval(1))
        #expect(tracker.activity == .waitingForInput, "redraws without input keep waiting")
        tracker.tick(now: clock.now.addingTimeInterval(60))
        #expect(tracker.activity == .waitingForInput, "the idle timeout does not override waiting")

        tracker.noteInput(at: clock.now.addingTimeInterval(61))
        tracker.noteOutput(at: clock.now.addingTimeInterval(62))
        #expect(tracker.activity == .running)
    }

    @Test func inputBeforeNotificationDoesNotCount() {
        let (tracker, _) = makeTracker()
        tracker.noteInput(at: clock.now)
        clock.advance(1)
        tracker.noteHookEvent(ClaudeHookEvent(name: "Notification", notificationType: "idle_prompt"))
        tracker.noteOutput(at: clock.now.addingTimeInterval(1))
        #expect(tracker.activity == .waitingForInput)
    }

    @Test func userPromptSubmitResumesAndResetsIdleClock() {
        let (tracker, _) = makeTracker()
        tracker.noteHookEvent(ClaudeHookEvent(name: "Notification", notificationType: "idle_prompt"))
        #expect(tracker.activity == .waitingForInput)
        clock.advance(100)
        tracker.noteHookEvent(ClaudeHookEvent(name: "UserPromptSubmit"))
        #expect(tracker.activity == .running)
        tracker.tick(now: clock.now.addingTimeInterval(7))
        #expect(tracker.activity == .running)
        tracker.tick(now: clock.now.addingTimeInterval(8))
        #expect(tracker.activity == .idle)
    }

    @Test func stopIsQuietIdle() {
        let (tracker, _) = makeTracker()
        tracker.noteOutput(at: clock.now)
        tracker.noteHookEvent(ClaudeHookEvent(name: "Stop"))
        #expect(tracker.activity == .idle)
        tracker.noteOutput(at: clock.now.addingTimeInterval(0.5))
        #expect(tracker.activity == .idle, "trailing render after Stop stays idle")
        tracker.noteInput(at: clock.now.addingTimeInterval(5))
        tracker.noteOutput(at: clock.now.addingTimeInterval(5.1))
        #expect(tracker.activity == .running)
    }

    @Test func informationalNotificationIsIgnored() {
        let (tracker, _) = makeTracker()
        tracker.noteOutput(at: clock.now)
        tracker.noteHookEvent(ClaudeHookEvent(name: "Notification", notificationType: "auth_success"))
        tracker.noteHookEvent(ClaudeHookEvent(name: "SessionStart"))
        #expect(tracker.activity == .running)
    }

    @Test func exitIsTerminal() {
        let (tracker, changes) = makeTracker()
        tracker.noteOutput(at: clock.now)
        tracker.noteExit(0)
        #expect(tracker.activity == .exited(0))
        tracker.noteOutput(at: clock.now.addingTimeInterval(1))
        tracker.noteHookEvent(ClaudeHookEvent(name: "UserPromptSubmit"))
        tracker.noteExit(1)
        tracker.noteFailure("late")
        tracker.tick(now: clock.now.addingTimeInterval(100))
        #expect(tracker.activity == .exited(0))
        #expect(changes() == [.running, .exited(0)])
    }

    @Test func nonZeroExitAndFailures() {
        let (a, _) = makeTracker()
        a.noteExit(127)
        #expect(a.activity == .exited(127))
        #expect(a.activity.sessionState == .exited)

        let (b, _) = makeTracker()
        b.noteExit(nil)
        guard case .failed = b.activity else { Issue.record("expected failed"); return }
        #expect(b.activity.sessionState == .failed)

        let (c, _) = makeTracker()
        c.noteFailure("binary not found")
        #expect(c.activity == .failed("binary not found"))
    }

    @Test func sessionStateMapping() {
        #expect(AgentActivity.starting.sessionState == .starting)
        #expect(AgentActivity.running.sessionState == .running)
        #expect(AgentActivity.waitingForInput.sessionState == .waitingForInput)
        #expect(AgentActivity.idle.sessionState == .idle)
    }
}
