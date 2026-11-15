import Foundation
import SuijinCore
import Testing
@testable import Suijin

/// Closing a tab whose agent still works: asked first, and "Don't ask again" really stops the question until
/// Settings → General turns it back on. A stand-in `claude` script runs instead of the real one.
@MainActor
@Suite(.endsHostedSessions, .serialized) struct CloseConfirmationTests {
    private struct Fixture {
        let model: AppModel
        let context: SessionContext
        let root: URL
    }

    private func eventually(_ timeout: Duration = .seconds(8), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-close-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        for directory in [folder, bin] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        // An agent that stays at its prompt until its terminal goes away.
        let script = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf 'ready\\n'\nIFS= read -r line\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.selection = context
        await model.runtimes.bootstrap()
        model.runtimes.agentSearchPath = bin.path
        return Fixture(model: model, context: context, root: root)
    }

    private func startAgent(_ fixture: Fixture) async throws -> UUID {
        let id = try #require(await fixture.model.runtimes.start(in: fixture.context, agent: .claude, accountID: nil, prompt: nil))
        #expect(await eventually { fixture.model.runtimes.runtime(for: id) != nil })
        return id
    }

    private func finish(_ fixture: Fixture) async {
        await fixture.model.closeSessions(fixture.model.sessions.map(\.id))
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @Test func closingAWorkingAgentAsksFirst() async throws {
        let fixture = try await makeFixture()
        let id = try await startAgent(fixture)
        fixture.model.requestClose(id)
        #expect(fixture.model.pendingClose?.sessions == [id])
        #expect(fixture.model.sessions.contains { $0.id == id }, "nothing closes before the answer")

        // Confirmed without the box: this one closes, the next one is asked again.
        fixture.model.confirmPendingClose(dontAskAgain: false)
        #expect(fixture.model.pendingClose == nil)
        #expect(await eventually { !fixture.model.sessions.contains { $0.id == id } })
        #expect(fixture.model.setting(.confirmClosingBusyAgents) == nil)
        let next = try await startAgent(fixture)
        fixture.model.requestClose(next)
        #expect(fixture.model.pendingClose?.sessions == [next])
        fixture.model.pendingClose = nil
        await finish(fixture)
    }

    @Test func dontAskAgainStopsTheQuestion() async throws {
        let fixture = try await makeFixture()
        let id = try await startAgent(fixture)
        fixture.model.requestClose(id)
        fixture.model.confirmPendingClose(dontAskAgain: true)
        #expect(fixture.model.setting(.confirmClosingBusyAgents) == "false")
        #expect(await eventually { !fixture.model.sessions.contains { $0.id == id } })

        let next = try await startAgent(fixture)
        fixture.model.requestClose(next)
        #expect(fixture.model.pendingClose == nil, "the question is not asked again")
        #expect(await eventually { !fixture.model.sessions.contains { $0.id == next } })
        await finish(fixture)
    }

    @Test func settingsTurnTheQuestionBackOn() async throws {
        let fixture = try await makeFixture()
        fixture.model.setSetting(.confirmClosingBusyAgents, "false")
        fixture.model.setSetting(.confirmClosingBusyAgents, "true")
        let id = try await startAgent(fixture)
        fixture.model.requestClose(id)
        #expect(fixture.model.pendingClose?.sessions == [id])
        fixture.model.pendingClose = nil
        await finish(fixture)
    }

    @Test func cancellingKeepsTheSessionAndTheQuestion() async throws {
        let fixture = try await makeFixture()
        let id = try await startAgent(fixture)
        fixture.model.requestClose(id)
        fixture.model.pendingClose = nil
        #expect(fixture.model.sessions.contains { $0.id == id })
        #expect(fixture.model.setting(.confirmClosingBusyAgents) == nil)
        await finish(fixture)
    }

    /// The permission question keeps its own answer: not confirming closes says nothing about starting an agent
    /// without permission checks.
    @Test func theTwoDontAskAgainAnswersAreSeparate() async throws {
        let fixture = try await makeFixture()
        let id = try await startAgent(fixture)
        fixture.model.requestClose(id)
        fixture.model.confirmPendingClose(dontAskAgain: true)
        #expect(fixture.model.setting(.skipPermissionsConfirmed) == nil)
        await finish(fixture)
    }
}
