import Darwin
import Foundation
@testable import SevindaPTYHostKit
import SevindaPTYProtocol
import Testing

@Suite("PTYSession")
struct PTYSessionTests {
    private func attachCollector(_ session: PTYSession, sink: CollectingSink = CollectingSink()) -> OutputCollector {
        session.attach(sink) { scrollback, _ in sink.collector.append(scrollback) }
        return sink.collector
    }

    @Test func echoOutputReachesTheAttachment() async throws {
        let session = try PTYSession.spawn(request: PTYSpawnRequest(executable: "/bin/echo", arguments: ["hi"], cwd: "/"))
        let collector = attachCollector(session)
        let status = await collector.waitForExit()
        #expect(status == 0)
        #expect(collector.text.contains("hi"))
        #expect(session.info.isRunning == false)
        #expect(session.info.exitStatus == 0)
        #expect(session.scrollbackSnapshot().contains(text: "hi"))
        var waitStatus: Int32 = 0
        #expect(waitpid(session.pid, &waitStatus, WNOHANG) == -1 && errno == ECHILD, "child already reaped, no zombie")
    }

    @Test func catEchoesWrittenInput() async throws {
        let session = try PTYSession.spawn(request: PTYSpawnRequest(executable: "/bin/cat", cwd: "/"))
        let collector = attachCollector(session)
        session.write(Data("hello sevinda\n".utf8))
        // Once from the terminal's own echo, once from cat.
        #expect(await collector.wait(forText: "hello sevinda", occurrences: 2))
        session.terminate()
        #expect(await collector.waitForExit() == 128 + SIGHUP)
    }

    @Test func hasControllingTerminal() async throws {
        let session = try PTYSession.spawn(request: shellRequest("exec 3</dev/tty && test -t 0 && echo CTTY_OK"))
        let collector = attachCollector(session)
        #expect(await collector.waitForExit() == 0)
        #expect(collector.text.contains("CTTY_OK"))
    }

    @Test func appliesInitialSizeAndResize() async throws {
        let session = try PTYSession.spawn(request: shellRequest("stty size; read line; stty size", cols: 80, rows: 24))
        let collector = attachCollector(session)
        #expect(await collector.wait(forText: "24 80"))
        session.resize(cols: 132, rows: 43)
        session.write(Data("\n".utf8))
        #expect(await collector.wait(forText: "43 132"))
        #expect(await collector.waitForExit() == 0)
    }

    @Test func terminateKillsTheProcessGroup() async throws {
        let session = try PTYSession.spawn(request: shellRequest("/bin/sleep 100 & echo CHILD=$!; /bin/sleep 100"))
        let collector = attachCollector(session)
        #expect(await collector.waitForLine(after: "CHILD="))
        let child = try #require(pidAfterMarker("CHILD=", in: collector.text))
        #expect(kill(child, 0) == 0, "background child is alive before terminate")

        let started = ContinuousClock.now
        let status = await withCheckedContinuation { continuation in
            session.terminate { continuation.resume(returning: $0) }
        }
        #expect(status == 128 + SIGHUP)
        #expect(ContinuousClock.now - started < .seconds(1.5), "SIGHUP alone is enough here")
        #expect(await processIsGone(child), "child in the same process group must die")
        #expect(await processGroupIsGone(session.pid))
        #expect(collector.exitStatus == 128 + SIGHUP)
    }

    @Test func terminateEscalatesToSIGKILL() async throws {
        var tuning = PTYSessionTuning()
        tuning.killGrace = 0.3
        let session = try PTYSession.spawn(
            request: shellRequest("trap '' HUP; /bin/sleep 100 & echo CHILD=$!; /bin/sleep 100"), tuning: tuning
        )
        let collector = attachCollector(session)
        #expect(await collector.waitForLine(after: "CHILD="))
        let child = try #require(pidAfterMarker("CHILD=", in: collector.text))

        let status = await withCheckedContinuation { continuation in
            session.terminate { continuation.resume(returning: $0) }
        }
        #expect(status == 128 + SIGKILL)
        #expect(await processIsGone(child), "SIGHUP-ignoring group member must be killed too")
    }

    @Test func terminateKillsHangupIgnoringBackgroundJobsInTheirOwnGroups() async throws {
        var tuning = PTYSessionTuning()
        tuning.killGrace = 0.5
        var request = PTYSpawnRequest(
            executable: "/bin/zsh", arguments: ["-f", "-i"],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": NSTemporaryDirectory()], cwd: "/"
        )
        request.cols = 200
        let session = try PTYSession.spawn(request: request, tuning: tuning)
        let collector = attachCollector(session)
        session.write(Data(#"nohup /bin/sleep 100 >/dev/null 2>&1 & echo NO''HUP=$!\#n"#.utf8))
        #expect(await collector.waitForLine(after: "NOHUP="))
        session.write(Data(#"(trap '' HUP; exec /bin/sleep 100) & echo TRA''PPED=$!\#n"#.utf8))
        #expect(await collector.waitForLine(after: "TRAPPED="))
        let nohupJob = try #require(pidAfterMarker("NOHUP=", in: collector.text))
        let trappedJob = try #require(pidAfterMarker("TRAPPED=", in: collector.text))
        // The case that escaped group-only signalling: each job leads its own process group.
        #expect(getpgid(nohupJob) == nohupJob)
        #expect(getpgid(trappedJob) == trappedJob)
        #expect(Set(session.terminalMembers()).isSuperset(of: [session.pid, nohupJob, trappedJob]))

        _ = await withCheckedContinuation { continuation in
            session.terminate { continuation.resume(returning: $0) }
        }
        #expect(await processIsGone(nohupJob), "nohup job must not survive closing the tab")
        #expect(await processIsGone(trappedJob), "SIGHUP-ignoring job must not survive closing the tab")
    }

    @Test func terminateAfterLeaderExitKillsStragglers() async throws {
        var tuning = PTYSessionTuning()
        tuning.killGrace = 0.3
        let session = try PTYSession.spawn(
            request: shellRequest("set -m; nohup /bin/sleep 100 >/dev/null 2>&1 & echo BG=$!"), tuning: tuning
        )
        let collector = attachCollector(session)
        #expect(await collector.waitForExit() == 0)
        let straggler = try #require(pidAfterMarker("BG=", in: collector.text))
        #expect(kill(straggler, 0) == 0, "the job outlives its shell")
        #expect(session.terminalMembers().contains(straggler))

        session.terminate()
        #expect(await processIsGone(straggler))
        try await waitUntil { session.terminalMembers().isEmpty }
    }

    @Test func attachMidStreamHasNoGapOrDuplicate() async throws {
        var tuning = PTYSessionTuning()
        tuning.attachmentWindowBytes = 8 * 1024 // force the flow-control path
        tuning.maxMessageBytes = 4 * 1024
        let session = try PTYSession.spawn(request: shellRequest(rawSeqScript(200_000)), tuning: tuning)
        try await Task.sleep(for: .milliseconds(30)) // let some output land in the scrollback first
        let sink = AcknowledgingSink(delay: 0.001) // slow client
        let token = session.attach(sink, flowControlled: true) { scrollback, _ in sink.collector.append(scrollback) }
        sink.bind(session, token: token)
        #expect(await sink.collector.waitForExit(timeout: 60) == 0)
        let full = session.scrollbackSnapshot()
        #expect(sink.collector.data.count == full.count)
        #expect(sink.collector.data == full)
        #expect(full == expectedSeqOutput(200_000))
    }

    @Test func slowAcknowledgerStallsTheChildThenCompletesIntact() async throws {
        var tuning = PTYSessionTuning()
        tuning.attachmentWindowBytes = 64 * 1024
        let lines = 2_000_000 // ~16 MB, twice the scrollback: nothing may be skipped
        let session = try PTYSession.spawn(request: shellRequest(rawSeqScript(lines)), tuning: tuning)
        let sink = AcknowledgingSink(acknowledging: false)
        let token = session.attach(sink, flowControlled: true) { scrollback, _ in sink.collector.append(scrollback) }
        sink.bind(session, token: token)

        try await waitUntil { session.isReadPaused }
        let stalledAt = session.bytesRead
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.bytesRead == stalledAt, "no reads while the client holds the whole window")
        #expect(session.isRunning, "the child is blocked on its write, not finished")
        #expect(stalledAt < 64 * 1024 + 4 * 64 * 1024 + 4096, "read-ahead bounded by the window plus one read burst")
        #expect(sink.collector.data.count <= 64 * 1024 + 4 * 64 * 1024)

        sink.release()
        #expect(await sink.collector.waitForExit(timeout: 60) == 0)
        #expect(sink.collector.data == expectedSeqOutput(lines))
    }

    @Test func detachStopsStreaming() async throws {
        let session = try PTYSession.spawn(request: PTYSpawnRequest(executable: "/bin/cat", cwd: "/"))
        let sink = CollectingSink()
        let token = session.attach(sink) { scrollback, _ in sink.collector.append(scrollback) }
        session.write(Data("one\n".utf8))
        #expect(await sink.collector.wait(forText: "one", occurrences: 2))
        session.detach(token)
        #expect(session.attachmentCount == 0)
        session.write(Data("two\n".utf8))
        let other = attachCollector(session)
        #expect(await other.wait(forText: "two", occurrences: 2))
        #expect(!sink.collector.text.contains("two"))
        session.terminate()
        _ = await session.waitForExit()
    }

    @Test func resolvesBareExecutableNamesThroughPATH() async throws {
        let request = PTYSpawnRequest(executable: "echo", arguments: ["from-path"], environment: ["PATH": "/bin"], cwd: "/")
        let session = try PTYSession.spawn(request: request)
        let collector = attachCollector(session)
        #expect(await collector.waitForExit() == 0)
        #expect(collector.text.contains("from-path"))
    }

    @Test func reportsSpawnFailures() {
        #expect(throws: PTYSpawnError.self) {
            try PTYSession.spawn(request: PTYSpawnRequest(executable: "/nonexistent/binary", cwd: "/"))
        }
        do {
            _ = try PTYSession.spawn(request: PTYSpawnRequest(executable: "/bin/echo", cwd: "/nonexistent-dir-\(UUID())"))
            Issue.record("spawn with a missing cwd must fail")
        } catch {
            #expect(error.localizedDescription.contains("Cannot enter directory"))
        }
    }
}
