import Foundation
@testable import SevindaPTYHostKit
import SevindaPTYProtocol
import Testing

@Suite("Orchestration broker")
struct OrchestrationBrokerTests {
    @Test func callersAreIdentifiedByTokenOnly() async {
        let harness = BrokerHarness()
        let stranger = await harness.call("whoami", token: String(repeating: "x", count: 64))
        #expect(stranger?.ok == false)
        #expect(stranger?.error?.code == "unknown_session")
        let missing = await harness.call("whoami", token: "")
        #expect(missing?.error?.code == "unknown_session")
        let short = await harness.call("whoami", token: "abc")
        #expect(short?.error?.code == "unknown_session", "tokens shorter than the minimum are never accepted")
        let known = await harness.call("whoami")
        #expect(known?.ok == true)
        #expect(known?.result?["sessionID"]?.stringValue == "coordinator")
    }

    @Test func tokenStopsWorkingWhenItsSessionExits() async {
        let harness = BrokerHarness()
        harness.broker.sessionExited(hostSessionID: "host-coordinator", status: 0)
        let response = await harness.call("whoami")
        #expect(response?.error?.code == "unknown_session")
    }

    @Test func workerStartAsksTheAppWithAPreambleAndRunsTheWorker() async throws {
        let harness = BrokerHarness()
        let (response, request) = await harness.startWorker()
        let launch = try #require(request)
        #expect(launch.agent == .codex)
        #expect(launch.worktree == .new)
        #expect(launch.name == "fix-login")
        #expect(launch.coordinatorSessionID == "coordinator")
        #expect(launch.prompt.contains("Dispatch ID: \(launch.dispatchID)"))
        #expect(launch.prompt.contains("Task ID: t-"))
        #expect(launch.prompt.contains("sevinda ask --body"))
        #expect(launch.prompt.contains("sevinda done --status success"))
        #expect(launch.prompt.hasSuffix("=== TASK ===\nFix the login bug"))
        let reply = try #require(response)
        #expect(reply.ok)
        #expect(reply.text?.contains("END YOUR TURN") == true)
        #expect(reply.result?["dispatchID"]?.stringValue == launch.dispatchID)
        #expect(reply.result?["status"]?.stringValue == "running")
        let dispatch = try #require(harness.snapshot.dispatches.first)
        #expect(dispatch.status == .running)
        #expect(dispatch.workerSessionID == "worker")
    }

    @Test func workerStartIsQueuedWithoutAnAppAndSentWhenOneConnects() async throws {
        let harness = BrokerHarness(attachApp: false)
        let response = try #require(await harness.call("worker.start", ["agent": "claude", "spec": "Write docs"]))
        #expect(response.ok)
        #expect(response.result?["status"]?.stringValue == "queued")
        #expect(response.text?.contains("not open") == true)
        #expect(harness.app.started.isEmpty)
        harness.broker.attachApp(harness.app, id: UUID())
        _ = harness.broker.sync { 0 }
        let request = try #require(harness.app.started.first)
        #expect(request.name == "write-docs", "the name comes from the spec when none is given")
        #expect(harness.snapshot.dispatches.first?.status == .starting)
    }

    @Test func failedStartIsReportedToTheWaitingCaller() async throws {
        let harness = BrokerHarness()
        let box = ReplyBox()
        harness.broker.handle(BrokerRequest(token: BrokerHarness.coordinatorToken, command: "worker.start",
                                            options: ["agent": "codex", "spec": "x", "worktree": "new"])) { box.set($0) }
        _ = harness.broker.sync { 0 }
        let request = try #require(harness.app.started.first)
        harness.broker.workerStartFinished(WorkerLaunchResult(dispatchID: request.dispatchID, workerSessionID: nil,
                                                              error: "a plain folder has no worktrees"))
        let reply = try #require(await box.wait())
        #expect(reply.ok == false)
        #expect(reply.error?.code == "start_failed")
        #expect(reply.error?.message.contains("plain folder") == true)
        #expect(harness.snapshot.dispatches.first?.status == .startFailed)
    }

    @Test func invalidRequestsGetHints() async {
        let harness = BrokerHarness()
        let noSpec = await harness.call("worker.start", ["agent": "codex"])
        #expect(noSpec?.error?.code == "missing_spec")
        #expect(noSpec?.error?.hint?.contains("sevinda worker start") == true)
        let badAgent = await harness.call("worker.start", ["agent": "gemini", "spec": "x"])
        #expect(badAgent?.error?.code == "invalid_agent")
        let notWorker = await harness.call("ask", ["body": "?"])
        #expect(notWorker?.error?.code == "not_worker")
        let unknown = await harness.call("send", ["to": "d-00000000", "body": "hi"])
        #expect(unknown?.error?.code == "unknown_dispatch")
    }

    @Test func rolesAreCheckedByToken() async throws {
        let harness = BrokerHarness()
        let (_, request) = await harness.startWorker()
        let dispatchID = try #require(request?.dispatchID)
        // A worker cannot act as its coordinator.
        let send = await harness.call("send", token: BrokerHarness.workerToken, ["to": dispatchID, "body": "hijack"])
        #expect(send?.error?.code == "not_coordinator")
        // A third session cannot answer the worker's question.
        harness.broker.sessionSpawned(hostSessionID: "host-other", sessionID: "other", agent: .claude, token: BrokerHarness.shellToken)
        let ask = try #require(await harness.call("ask", token: BrokerHarness.workerToken, ["body": "Which file?"]))
        let questionID = try #require(ask.result?["messageID"]?.stringValue)
        let foreign = await harness.call("reply", token: BrokerHarness.shellToken, ["id": questionID, "body": "this one"])
        #expect(foreign?.error?.code == "not_coordinator")
        // The coordinator cannot report done.
        let done = await harness.call("done", ["status": "success", "summary": "x"])
        #expect(done?.error?.code == "not_worker")
    }

    @Test func stateMovesThroughAskReplyAndDone() async throws {
        let harness = BrokerHarness()
        let (_, request) = await harness.startWorker()
        let dispatchID = try #require(request?.dispatchID)
        func status() -> DispatchStatus? { harness.snapshot.dispatches.first { $0.id == dispatchID }?.status }
        #expect(status() == .running)

        let ask = try #require(await harness.call("ask", token: BrokerHarness.workerToken, ["body": "Which file?"]))
        #expect(ask.ok)
        #expect(ask.text?.contains("END YOUR TURN") == true)
        #expect(status() == .asking)
        // A worker that asked and ended its turn is waiting, not stuck: no escalation.
        await harness.codexTurnEnded()
        #expect(status() == .asking)
        #expect(!harness.snapshot.messages.contains { $0.kind == .escalation })

        let questionID = try #require(ask.result?["messageID"]?.stringValue)
        let reply = try #require(await harness.call("reply", ["id": "message:\(questionID)", "body": "auth.swift"]))
        #expect(reply.ok)
        #expect(status() == .running)
        let again = await harness.call("reply", ["id": questionID, "body": "again"])
        #expect(again?.error?.code == "already_answered")

        let done = try #require(await harness.call("done", token: BrokerHarness.workerToken,
                                                   ["status": "success", "summary": "Fixed it; tests pass."]))
        #expect(done.ok)
        #expect(status() == .succeeded)
        #expect(harness.snapshot.dispatches.first?.summary == "Fixed it; tests pass.")
        let twice = await harness.call("done", token: BrokerHarness.workerToken, ["status": "failed", "summary": "x"])
        #expect(twice?.error?.code == "already_done")
        #expect(harness.snapshot.messages.map(\.kind) == [.question, .reply, .done])
    }

    @Test func failedDoneSettlesAsFailed() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        _ = await harness.call("done", token: BrokerHarness.workerToken, ["status": "failed", "summary": "Could not reproduce."])
        #expect(harness.snapshot.dispatches.first?.status == .failed)
    }

    @Test func turnEndWithoutDoneEscalatesOnce() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        await harness.codexTurnEnded()
        await harness.graceElapses()
        #expect(harness.snapshot.dispatches.first?.status == .stalled)
        await harness.codexTurnEnded()
        await harness.graceElapses()
        let escalations = harness.snapshot.messages.filter { $0.kind == .escalation }
        #expect(escalations.count == 1)
        #expect(escalations.first?.toSessionID == "coordinator")
        #expect(escalations.first?.body.contains("without reporting `sevinda done`") == true)
        // A stalled worker can still finish.
        let done = await harness.call("done", token: BrokerHarness.workerToken, ["status": "success", "summary": "ok"])
        #expect(done?.ok == true)
    }

    @Test func askArrivingJustAfterTheTurnEndDoesNotEscalate() async throws {
        // Codex can end its turn while its `sevinda ask` is still on the way to the broker.
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        await harness.codexTurnEnded()
        _ = await harness.call("ask", token: BrokerHarness.workerToken, ["body": "Which file?"])
        await harness.graceElapses()
        #expect(harness.snapshot.dispatches.first?.status == .asking)
        #expect(!harness.snapshot.messages.contains { $0.kind == .escalation })
        // Likewise a `done` that lands after the turn end.
        let second = BrokerHarness()
        _ = await second.startWorker()
        await second.codexTurnEnded()
        _ = await second.call("done", token: BrokerHarness.workerToken, ["status": "success", "summary": "ok"])
        await second.graceElapses()
        #expect(!second.snapshot.messages.contains { $0.kind == .escalation })
    }

    @Test func workerExitWithoutDoneEscalatesWithTheStatus() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        harness.broker.sessionExited(hostSessionID: "host-worker", status: 128 + 9)
        _ = harness.broker.sync { 0 }
        let dispatch = try #require(harness.snapshot.dispatches.first)
        #expect(dispatch.status == .exited)
        let escalation = try #require(harness.snapshot.messages.first { $0.kind == .escalation })
        #expect(escalation.body.contains("killed (signal 9)"))
        // Messages to a worker that is gone are refused with a hint.
        let send = await harness.call("send", ["to": dispatch.id, "body": "still there?"])
        #expect(send?.error?.code == "worker_gone")
    }

    @Test func exitAfterDoneDoesNotEscalate() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        _ = await harness.call("done", token: BrokerHarness.workerToken, ["status": "success", "summary": "ok"])
        harness.broker.sessionExited(hostSessionID: "host-worker", status: 0)
        _ = harness.broker.sync { 0 }
        #expect(harness.snapshot.dispatches.first?.status == .succeeded)
        #expect(!harness.snapshot.messages.contains { $0.kind == .escalation })
    }

    @Test func sendToAFinishedWorkerBecomesAFollowUpTask() async throws {
        let harness = BrokerHarness()
        let (_, request) = await harness.startWorker()
        let first = try #require(request?.dispatchID)
        _ = await harness.call("done", token: BrokerHarness.workerToken, ["status": "success", "summary": "ok"])
        let send = try #require(await harness.call("send", ["to": "dispatch:\(first)", "body": "Also add a test."]))
        #expect(send.ok)
        #expect(send.result?["delivery"]?.stringValue == "follow_up")
        let followUp = try #require(send.result?["dispatchID"]?.stringValue)
        #expect(followUp != first)
        let dispatch = try #require(harness.snapshot.dispatches.first { $0.id == followUp })
        #expect(dispatch.status == .running)
        #expect(dispatch.workerSessionID == "worker")
        #expect(harness.snapshot.tasks.first { $0.id == dispatch.taskID }?.followUpOf != nil)
        // The worker reports the follow-up with `done` again.
        let done = await harness.call("done", token: BrokerHarness.workerToken, ["status": "success", "summary": "test added"])
        #expect(done?.result?["dispatchID"]?.stringValue == followUp)
    }

    @Test func workerListAndInbox() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        _ = await harness.call("ask", token: BrokerHarness.workerToken, ["body": "Which file?"])
        let list = try #require(await harness.call("worker.list"))
        guard case .array(let items)? = list.result else {
            Issue.record("worker list result is not an array")
            return
        }
        #expect(items.count == 1)
        #expect(items.first?["name"]?.stringValue == "fix-login")
        #expect(items.first?["status"]?.stringValue == "asking")
        #expect(list.text?.contains("open questions") == true)
        let inbox = try #require(await harness.call("inbox"))
        guard case .array(let messages)? = inbox.result else {
            Issue.record("inbox result is not an array")
            return
        }
        #expect(messages.first?["kind"]?.stringValue == "question")
        #expect(messages.first?["direction"]?.stringValue == "in")
        let workerView = try #require(await harness.call("worker.list", token: BrokerHarness.workerToken))
        guard case .array(let own)? = workerView.result else { return }
        #expect(own.count == 1, "a worker sees its own dispatch")
    }

    @Test func stateSurvivesReopeningAndUnsettledWorkIsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        do {
            let harness = BrokerHarness(stateFile: file)
            _ = await harness.startWorker()
            _ = await harness.call("ask", token: BrokerHarness.workerToken, ["body": "Which file?"])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let reopened = Broker(dataRoot: directory, stateFile: file, io: nil)
        reopened.open(tick: false)
        let snapshot = reopened.snapshot()
        #expect(snapshot.dispatches.count == 1)
        #expect(snapshot.dispatches.first?.status == .exited, "the worker died with the previous helper")
        #expect(snapshot.messages.count == 1)
        #expect(snapshot.messages.first?.status == .undeliverable)
    }

    @Test func workerNamesAreSlugs() {
        #expect(Broker.workerName("Fix Login!", spec: "") == "fix-login")
        #expect(Broker.workerName(nil, spec: "Write the README for the CLI") == "write-the-readme-for")
        #expect(Broker.workerName("  ", spec: "!!!") == "worker")
        #expect(Broker.workerName(String(repeating: "a", count: 50), spec: "").count == 32)
    }
}

@Suite("Orchestration delivery")
struct OrchestrationDeliveryTests {
    @Test func deliversToAnIdleCoordinatorExactlyOnce() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        // The coordinator is still in the turn that started the worker: nothing is typed yet.
        await harness.hook("UserPromptSubmit")
        _ = await harness.call("ask", token: BrokerHarness.workerToken, ["body": "Which file?"])
        #expect(harness.io.pastes("host-coordinator").isEmpty)
        // Its turn ends: the question is pasted, then Return is sent separately.
        await harness.hook("Stop")
        await harness.settle()
        let pastes = harness.io.pastes("host-coordinator")
        #expect(pastes.count == 1)
        #expect(pastes.first?.contains("asks (question m-") == true)
        #expect(pastes.first?.contains("sevinda reply --id m-") == true)
        #expect(harness.io.submits("host-coordinator") == 1)
        let writes = harness.io.written("host-coordinator")
        #expect(writes.count == 2, "the paste and Return are two writes")
        // Further passes and turn ends never repeat it.
        harness.broker.pump()
        await harness.hook("Stop")
        await harness.settle()
        harness.broker.pump()
        #expect(harness.io.pastes("host-coordinator").count == 1)
        #expect(harness.snapshot.messages.first?.status == .delivered)
    }

    @Test func nothingIsTypedBeforeTheFirstTurnSignal() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        _ = await harness.call("done", token: BrokerHarness.workerToken, ["status": "success", "summary": "ok"])
        harness.broker.pump()
        #expect(harness.io.written("host-coordinator").isEmpty, "an unknown turn state is never typed into")
        await harness.hook("Stop")
        await harness.settle()
        #expect(harness.io.pastes("host-coordinator").count == 1)
    }

    @Test func deferredWhileTheUserTypes() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        await harness.hook("Stop")
        // The user types into the coordinator (no Return yet).
        harness.broker.userInput(hostSessionID: "host-coordinator", data: Data("hel".utf8))
        _ = await harness.call("done", token: BrokerHarness.workerToken, ["status": "success", "summary": "ok"])
        harness.broker.pump()
        #expect(harness.io.written("host-coordinator").isEmpty, "deferred within the quiet period")
        harness.clock.advance(2)
        harness.broker.pump()
        #expect(harness.io.written("host-coordinator").isEmpty)
        harness.clock.advance(1.5)
        harness.broker.tick()
        await harness.settle()
        #expect(harness.io.pastes("host-coordinator").count == 1)
    }

    @Test func returnFromTheUserStartsATurn() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        await harness.hook("Stop")
        harness.broker.userInput(hostSessionID: "host-coordinator", data: Data("go on\r".utf8))
        harness.clock.advance(10)
        _ = await harness.call("done", token: BrokerHarness.workerToken, ["status": "success", "summary": "ok"])
        harness.broker.pump()
        #expect(harness.io.written("host-coordinator").isEmpty, "the user's prompt is running")
        // No agent signal, no output for a while: the Return did not start a turn after all.
        harness.io.setBytesRead(100, for: "host-coordinator")
        harness.broker.tick()
        harness.clock.advance(25)
        harness.broker.tick()
        await harness.settle()
        #expect(harness.io.pastes("host-coordinator").count == 1)
    }

    @Test func permissionPromptBlocksDeliveryAndAsksForAttention() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        await harness.hook("Notification", type: "permission_prompt")
        _ = await harness.call("done", token: BrokerHarness.workerToken, ["status": "success", "summary": "ok"])
        harness.broker.pump()
        #expect(harness.io.written("host-coordinator").isEmpty)
        #expect(harness.app.attentions.first?.kind == .permission)
        await harness.hook("Notification", type: "idle_prompt")
        await harness.settle()
        #expect(harness.io.pastes("host-coordinator").count == 1)
    }

    @Test func messagesWaitingTogetherArriveInOnePaste() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        await harness.hook("UserPromptSubmit")
        _ = await harness.call("ask", token: BrokerHarness.workerToken, ["body": "First?"])
        _ = await harness.call("done", token: BrokerHarness.workerToken, ["status": "failed", "summary": "Blocked on access."])
        await harness.hook("Stop")
        await harness.settle()
        let pastes = harness.io.pastes("host-coordinator")
        #expect(pastes.count == 1)
        let paste = try #require(pastes.first)
        #expect(paste.hasPrefix("[Sevinda] 2 messages for you:"))
        #expect(paste.contains("First?"))
        #expect(paste.contains("failed."))
        #expect(paste.contains("Every worker has reported"))
    }

    @Test func replyReachesTheWorkerWhenItsTurnEnds() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        await harness.hook("Stop")
        let ask = try #require(await harness.call("ask", token: BrokerHarness.workerToken, ["body": "Which file?"]))
        let questionID = try #require(ask.result?["messageID"]?.stringValue)
        await harness.settle()
        _ = await harness.call("reply", ["id": questionID, "body": "auth.swift"])
        #expect(harness.io.pastes("host-worker").isEmpty, "the worker is still in its turn")
        await harness.codexTurnEnded()
        await harness.settle()
        let paste = try #require(harness.io.pastes("host-worker").first)
        #expect(paste.contains("answered your question \(questionID)"))
        #expect(paste.contains("auth.swift"))
    }

    @Test func coordinatorEndingItsTurnOnAnOpenQuestionNeedsTheUser() async throws {
        let harness = BrokerHarness()
        _ = await harness.startWorker()
        await harness.hook("Stop")
        _ = await harness.call("ask", token: BrokerHarness.workerToken, ["body": "Delete the table?"])
        await harness.settle()
        #expect(harness.io.pastes("host-coordinator").count == 1)
        // Woken, the coordinator asks the user instead of replying and ends its turn.
        await harness.hook("UserPromptSubmit")
        await harness.hook("Stop")
        let attention = try #require(harness.app.attentions.last)
        #expect(attention.kind == .decision)
        #expect(attention.body.contains("Delete the table?"))
        #expect(attention.sessionID == "coordinator")
    }

    @Test func shellsReadTheirMessagesInTheInbox() async throws {
        let harness = BrokerHarness()
        harness.broker.sessionSpawned(hostSessionID: "host-shell", sessionID: "shell", agent: nil, token: BrokerHarness.shellToken)
        let response = try #require(await harness.call("worker.start", token: BrokerHarness.shellToken, ["agent": "codex", "spec": "x"]))
        #expect(response.ok)
        let request = try #require(harness.app.started.first)
        harness.broker.sessionSpawned(hostSessionID: "host-worker", sessionID: "worker", agent: .codex, token: BrokerHarness.workerToken)
        harness.broker.workerStartFinished(WorkerLaunchResult(dispatchID: request.dispatchID, workerSessionID: "worker"))
        _ = await harness.call("done", token: BrokerHarness.workerToken, ["status": "success", "summary": "ok"])
        harness.broker.pump()
        #expect(harness.io.written("host-shell").isEmpty, "a shell has no turns to wait for")
    }
}

@Suite("Turn tracking and delivery text")
struct TurnTrackerTests {
    @Test func phasesAndQuietPeriod() {
        var tracker = TurnTracker()
        let start = Date()
        tracker.track("s", now: start)
        #expect(tracker.readiness("s", now: start) == .notIdle)
        tracker.turnEnded("s", now: start)
        #expect(tracker.readiness("s", now: start) == .ready)
        tracker.userInput("s", data: Data("x".utf8), now: start)
        #expect(tracker.readiness("s", now: start.addingTimeInterval(1)) == .deferred(until: start.addingTimeInterval(3)))
        #expect(tracker.readiness("s", now: start.addingTimeInterval(3)) == .ready)
        tracker.blocked("s", now: start)
        #expect(tracker.readiness("s", now: start.addingTimeInterval(10)) == .notIdle)
        tracker.userInput("s", data: Data("\r".utf8), now: start.addingTimeInterval(11))
        #expect(tracker.phase("s") == .busy, "answering the prompt resumes the turn")
    }

    @Test func unconfirmedBusyExpiresOnlyWithoutOutput() {
        var tracker = TurnTracker()
        let start = Date()
        tracker.turnEnded("s", now: start)
        tracker.userInput("s", data: Data("\r".utf8), now: start)
        tracker.observeOutput("s", bytesRead: 10, now: start.addingTimeInterval(1))
        tracker.observeOutput("s", bytesRead: 20, now: start.addingTimeInterval(15))
        tracker.observeOutput("s", bytesRead: 20, now: start.addingTimeInterval(30))
        #expect(tracker.phase("s") == .busy, "output 15 s ago: still working")
        tracker.observeOutput("s", bytesRead: 20, now: start.addingTimeInterval(36))
        #expect(tracker.phase("s") == .idle)
        // A confirmed turn never expires.
        tracker.turnStarted("s", now: start.addingTimeInterval(40))
        tracker.observeOutput("s", bytesRead: 20, now: start.addingTimeInterval(400))
        #expect(tracker.phase("s") == .busy)
    }

    @Test func pasteIsSanitizedAndFramed() {
        let payload = MessageDelivery.pastePayload("a\u{1B}[201~b\r\nc\td\u{07}")
        #expect(payload.starts(with: MessageDelivery.pasteStart))
        #expect(payload.suffix(6) == MessageDelivery.pasteEnd)
        let inner = String(decoding: payload.dropFirst(6).dropLast(6), as: UTF8.self)
        #expect(inner == "a[201~b\nc\td", "escape and bell are removed so a message cannot end the paste")
        #expect(MessageDelivery.submitDelay(forPasteBytes: 0) == 0.5)
    }

    @Test func preambleCarriesIDsAndRules() {
        let text = WorkerPreamble.build(taskID: "t-1", dispatchID: "d-2", name: "w", spec: "Do it", followUp: false)
        #expect(text.contains("Task ID: t-1"))
        #expect(text.contains("Dispatch ID: d-2"))
        #expect(text.contains("END YOUR TURN"))
        #expect(text.contains("Never poll"))
        #expect(text.contains("AskUserQuestion"))
        #expect(text.hasSuffix("=== TASK ===\nDo it"))
    }

    @Test func protocolVersionsNegotiate() {
        #expect(PTYHostConstants.protocolVersion == 3)
        #expect(PTYHostConstants.negotiatedVersion(clientVersion: 2) == 2, "an app one version behind keeps working")
        #expect(PTYHostConstants.negotiatedVersion(clientVersion: 3) == 3)
        #expect(PTYHostConstants.negotiatedVersion(clientVersion: 1) == 3)
        #expect(PTYHostConstants.negotiatedVersion(clientVersion: 9) == 3)
    }

    @Test func machServiceOverrideIsLimitedToSevindaNames() {
        #expect(PTYHostConstants.resolveMachServiceName(environment: [:]) == "com.tekmium.sevinda.ptyhost")
        #expect(PTYHostConstants.resolveMachServiceName(environment: ["SEVINDA_PTYHOST_SERVICE": "com.tekmium.sevinda.ptyhost.e2e"])
                == "com.tekmium.sevinda.ptyhost.e2e")
        #expect(PTYHostConstants.resolveMachServiceName(environment: ["SEVINDA_PTYHOST_SERVICE": "com.apple.something"])
                == "com.tekmium.sevinda.ptyhost")
        #expect(PTYHostConstants.resolveMachServiceName(environment: ["SEVINDA_PTYHOST_SERVICE": "com.tekmium.sevinda.ptyhost.a b"])
                == "com.tekmium.sevinda.ptyhost")
    }

    @Test func socketPathFitsSunPath() {
        let short = URL(fileURLWithPath: "/tmp/m")
        #expect(OrchestrationPaths.socketPath(dataRoot: short) == "/tmp/m/orchestration/broker.sock")
        let deep = URL(fileURLWithPath: "/tmp/" + String(repeating: "deep/", count: 30))
        let path = OrchestrationPaths.socketPath(dataRoot: deep)
        #expect(path.utf8.count <= OrchestrationPaths.socketPathByteLimit)
        #expect(path.hasPrefix(OrchestrationPaths.userTemporaryDirectory().path))
        #expect(OrchestrationPaths.socketPath(dataRoot: deep) == path, "stable for the same data root")
        #expect(OrchestrationPaths.spoolDirectory(dataRoot: short) != OrchestrationPaths.spoolDirectory(dataRoot: deep))
    }

    @Test func identifiersNormalize() {
        #expect(OrchestrationID.normalize(" dispatch:D-1A2B3C4D ") == "d-1a2b3c4d")
        #expect(OrchestrationID.make("m").hasPrefix("m-"))
        #expect(OrchestrationID.make("m").count == 10)
    }
}
