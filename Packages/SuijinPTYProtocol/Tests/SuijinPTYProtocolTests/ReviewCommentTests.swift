import Foundation
import SuijinCLIKit
@testable import SuijinPTYHostKit
import SuijinPTYProtocol
import Synchronization
import Testing

/// Comment ids that share their first six hex digits (`c-7f3a2b`), and two that do not.
private enum IDs {
    static let first = "7f3a2b10-0000-4000-8000-000000000001"
    static let second = "7f3a2b20-0000-4000-8000-000000000002"
    static let other = "a1b2c3d4-0000-4000-8000-000000000003"
    static let foreign = "e5f60718-0000-4000-8000-000000000004"
}

private let otherToken = String(repeating: "o", count: 64)

private func comment(_ id: String, session: String = "coordinator", file: String = "docs/plan.md", note: String = "Tighten this.",
                     at seconds: TimeInterval = 0) -> PendingComment {
    PendingComment(id: id, sessionID: session, filePath: file, text: "[c-\(id.prefix(6))] line 3\n> quoted\nNote: \(note)",
                   createdAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
}

extension BrokerHarness {
    /// Attaches the recording app as connection `id` and syncs `comments`, as the app does after `hello`.
    @discardableResult
    func connectSyncingApp(_ id: UUID = UUID(), comments: [PendingComment] = []) -> UUID {
        broker.attachApp(app, id: id)
        broker.syncComments(comments, appID: id)
        _ = broker.sync { 0 }
        return id
    }

    func resolve(_ id: String, _ outcome: String = "fixed", reply: String? = nil,
                 token: String = BrokerHarness.coordinatorToken) async -> BrokerResponse? {
        var options = ["id": id, "outcome": outcome]
        if let reply { options["reply"] = reply }
        return await call("comment.resolve", token: token, options)
    }

    func addOtherSession() {
        broker.sessionSpawned(hostSessionID: "host-other", sessionID: "other", agent: .codex, token: otherToken)
    }

    var deliveredIDs: [String] { app.commentDeliveries.flatMap { $0.map(\.id) } }
}

@Suite("Review comments in the broker")
struct ReviewCommentBrokerTests {
    @Test func theReceivingSessionResolvesAndASyncedAppHearsAtOnce() async throws {
        let harness = BrokerHarness(attachApp: false)
        _ = harness.connectSyncingApp()
        harness.broker.registerComments([comment(IDs.other)])
        let response = try #require(await harness.resolve("c-a1b2c3", reply: "Renamed the section."))
        #expect(response.ok)
        #expect(response.text == "Marked c-a1b2c3 as fixed.")
        #expect(response.result?["outcome"]?.stringValue == "fixed")
        #expect(response.result?["reply"]?.stringValue == "Renamed the section.")
        let delivered = try #require(harness.app.commentDeliveries.first?.first)
        #expect(delivered.id == IDs.other)
        #expect(delivered.sessionID == "coordinator")
        #expect(delivered.outcome == "fixed")
        #expect(delivered.reply == "Renamed the section.")
        #expect(delivered.resolvedAt == harness.clock.now)
    }

    @Test func everyRefusalLooksTheSame() async throws {
        let harness = BrokerHarness()
        harness.addOtherSession()
        harness.broker.registerComments([comment(IDs.other), comment(IDs.foreign, session: "other")])
        let anotherSession = try #require(await harness.resolve("c-a1b2c3", token: otherToken))
        let unknownToken = try #require(await harness.resolve("c-a1b2c3", token: String(repeating: "x", count: 64)))
        let noToken = try #require(await harness.resolve("c-a1b2c3", token: ""))
        let unknownID = try #require(await harness.resolve("c-ffffff"))
        let malformed = try #require(await harness.resolve("c-zz12"))
        let foreignFromOwner = try #require(await harness.resolve("c-e5f607"))
        let refusals = [anotherSession, unknownToken, noToken, unknownID, malformed, foreignFromOwner]
        #expect(refusals.allSatisfy { !$0.ok })
        #expect(Set(refusals.compactMap(\.error)).count == 1, "nothing tells the cases apart")
        #expect(anotherSession.error?.code == "no-such-comment")
        #expect(anotherSession.error?.message == "No such comment for this session.")
        #expect(anotherSession.error?.hint?.contains("suijin comment list") == true)
        #expect(anotherSession == unknownID)
        #expect(harness.broker.commentRecords().allSatisfy { $0.result == nil })
    }

    @Test func shortIDsMustBeUnambiguousAndFullOrPrefixedIDsWork() async throws {
        let harness = BrokerHarness()
        harness.broker.registerComments([comment(IDs.first), comment(IDs.second), comment(IDs.other)])
        let ambiguous = try #require(await harness.resolve("c-7f3a2b"))
        #expect(ambiguous.error?.code == "no-such-comment")
        let full = try #require(await harness.resolve(IDs.first.uppercased()))
        #expect(full.ok)
        let prefixed = try #require(await harness.resolve("c-7F3A2B2", "declined"))
        #expect(prefixed.ok)
        #expect(prefixed.text == "Marked c-7f3a2b2 as declined.")
        let bare = try #require(await harness.resolve("a1b2c3d4"))
        #expect(bare.ok, "the c- prefix is optional")
        let outcomes = Dictionary(uniqueKeysWithValues: harness.broker.commentRecords().map { ($0.comment.id, $0.result?.outcome) })
        #expect(outcomes == [IDs.first: "fixed", IDs.second: "declined", IDs.other: "fixed"])
    }

    @Test func aSecondResolveNamesTheFirstOutcome() async throws {
        let harness = BrokerHarness()
        harness.broker.registerComments([comment(IDs.other)])
        #expect(await harness.resolve("c-a1b2c3", "declined", reply: "Out of scope.")?.ok == true)
        let again = try #require(await harness.resolve("c-a1b2c3", "fixed"))
        #expect(again.error?.code == "already-resolved")
        #expect(again.error?.message == "That comment was already reported as declined.")
        #expect(again.error?.hint?.contains("reopen") == true)
        #expect(harness.broker.commentRecords().first?.result?.outcome == "declined", "the first answer stands")
    }

    @Test func anOutcomeIsRequired() async throws {
        let harness = BrokerHarness()
        harness.broker.registerComments([comment(IDs.other)])
        let response = try #require(await harness.resolve("c-a1b2c3", "maybe"))
        #expect(response.error?.code == "invalid_outcome")
    }

    @Test func repliesAreSanitized() async throws {
        #expect(CommentLedger.sanitizeReply("a\u{1B}[31mb\nc\td\r\ne\u{07}\u{7F}") == "a[31mb c d e")
        #expect(CommentLedger.sanitizeReply("  safe \u{202E}txt.exe\u{2069} ") == "safe txt.exe")
        #expect(CommentLedger.sanitizeReply("one\n\n\ntwo") == "one two", "a run of line breaks is one space")
        #expect(CommentLedger.sanitizeReply(" \n\t\u{00} ") == nil)
        #expect(CommentLedger.sanitizeReply("") == nil)
        #expect(CommentLedger.sanitizeReply(nil) == nil)
        #expect(CommentLedger.sanitizeReply("👩‍💻 done") == "👩‍💻 done", "emoji sequences survive")
        let long = CommentLedger.sanitizeReply(String(repeating: "x", count: 900))
        #expect(long?.count == 500)
        #expect(long?.hasSuffix("…") == true)
        #expect(CommentLedger.sanitizeReply(String(repeating: "y", count: 500)) == String(repeating: "y", count: 500))

        let harness = BrokerHarness()
        harness.broker.registerComments([comment(IDs.other), comment(IDs.foreign)])
        #expect(await harness.resolve("c-a1b2c3", reply: "Fixed\nthe\u{1B}typo") != nil)
        #expect(await harness.resolve("c-e5f607", reply: " \n ") != nil)
        let records = Dictionary(uniqueKeysWithValues: harness.broker.commentRecords().map { ($0.comment.id, $0.result) })
        #expect(records[IDs.other]??.reply == "Fixed thetypo")
        #expect(records[IDs.foreign]??.reply == nil, "an empty reply is no reply")
        #expect(records[IDs.foreign]??.outcome == "fixed")
    }

    @Test func listShowsWaitingCommentsByFileEvenWithoutAnApp() async throws {
        let harness = BrokerHarness(attachApp: false)
        harness.addOtherSession()
        let empty = try #require(await harness.call("comment.list"))
        #expect(empty.ok)
        #expect(empty.text == "No review comments are waiting for an answer from this session.")
        #expect(empty.result == .array([]))
        harness.broker.registerComments([
            comment(IDs.first, file: "docs/plan.md", note: "First.", at: 1),
            comment(IDs.other, file: "README.md", note: "Second.", at: 2),
            comment(IDs.second, file: "docs/plan.md", note: "Third.", at: 3),
            comment(IDs.foreign, session: "other", file: "secret.md", note: "Not yours.", at: 4),
        ])
        let list = try #require(await harness.call("comment.list"))
        let text = try #require(list.text)
        #expect(text == """
        For each comment, edit the file, then report it: suijin comment resolve <id> --fixed --reply "what you changed" \
        (or --declined --reply "why not").

        Review comments on docs/plan.md:

        [c-7f3a2b] line 3
        > quoted
        Note: First.

        [c-7f3a2b] line 3
        > quoted
        Note: Third.

        Review comments on README.md:

        [c-a1b2c3] line 3
        > quoted
        Note: Second.
        """)
        #expect(!text.contains("Not yours"))
        guard case .array(let items)? = list.result else {
            Issue.record("comment list result is not an array")
            return
        }
        #expect(items.compactMap { $0["id"]?.stringValue } == [IDs.first, IDs.other, IDs.second])
        #expect(items.first?["filePath"]?.stringValue == "docs/plan.md")
        #expect(items.first?["sessionID"]?.stringValue == "coordinator")
        // Answered comments leave the list.
        _ = await harness.resolve(IDs.first)
        let after = try #require(await harness.call("comment.list"))
        #expect(after.text?.contains("Note: First.") == false)
        #expect(after.text?.contains("Note: Third.") == true)
    }

    @Test func listNeedsASuijinSession() async throws {
        let harness = BrokerHarness()
        let stranger = try #require(await harness.call("comment.list", token: String(repeating: "x", count: 64)))
        #expect(stranger.error?.code == "unknown_session")
    }

    @Test func resultsQueueWhileTheAppIsClosedAndArriveAfterSync() async throws {
        let harness = BrokerHarness(attachApp: false)
        harness.broker.registerComments([comment(IDs.other)])
        #expect(await harness.resolve("c-a1b2c3")?.ok == true)
        #expect(harness.app.commentDeliveries.isEmpty)
        let id = UUID()
        harness.broker.attachApp(harness.app, id: id)
        _ = harness.broker.sync { 0 }
        #expect(harness.app.commentDeliveries.isEmpty, "only after the app syncs")
        harness.broker.syncComments([comment(IDs.other)], appID: id)
        _ = harness.broker.sync { 0 }
        #expect(harness.deliveredIDs == [IDs.other])
    }

    @Test func syncBeforeHelloStillDeliversOnHello() async throws {
        let harness = BrokerHarness(attachApp: false)
        harness.broker.registerComments([comment(IDs.other)])
        _ = await harness.resolve("c-a1b2c3")
        let id = UUID()
        harness.broker.syncComments([], appID: id)
        _ = harness.broker.sync { 0 }
        #expect(harness.app.commentDeliveries.isEmpty)
        harness.broker.attachApp(harness.app, id: id)
        _ = harness.broker.sync { 0 }
        #expect(harness.deliveredIDs == [IDs.other])
    }

    @Test func aConnectionThatNeverSyncsIsNeverSentResults() async throws {
        let harness = BrokerHarness()
        harness.broker.registerComments([comment(IDs.other)])
        #expect(await harness.resolve("c-a1b2c3")?.ok == true)
        harness.broker.attachApp(harness.app, id: UUID())
        _ = harness.broker.sync { 0 }
        #expect(harness.app.commentDeliveries.isEmpty)
    }

    @Test func resultsAreRedeliveredUntilApplied() async throws {
        let harness = BrokerHarness(attachApp: false)
        let first = harness.connectSyncingApp(comments: [comment(IDs.other)])
        _ = await harness.resolve("c-a1b2c3")
        #expect(harness.deliveredIDs == [IDs.other])
        harness.broker.detachApp(id: first)
        let second = harness.connectSyncingApp(comments: [comment(IDs.other)])
        #expect(harness.deliveredIDs == [IDs.other, IDs.other], "not applied yet: sent again")
        harness.broker.commentResultsApplied([IDs.other.uppercased()])
        harness.broker.detachApp(id: second)
        _ = harness.connectSyncingApp()
        #expect(harness.deliveredIDs == [IDs.other, IDs.other], "applied: never again")
        let again = try #require(await harness.resolve("c-a1b2c3"))
        #expect(again.error?.code == "already-resolved", "the answer is still remembered")
    }

    @Test func withdrawnCommentsAreForgottenWithTheirResults() async throws {
        let harness = BrokerHarness(attachApp: false)
        harness.broker.registerComments([comment(IDs.first), comment(IDs.other)])
        harness.broker.withdrawComments([IDs.first])
        let refused = try #require(await harness.resolve(IDs.first))
        #expect(refused.error == CommentLedger.noSuchComment)
        _ = await harness.resolve("c-a1b2c3")
        harness.broker.withdrawComments([IDs.other.uppercased()])
        _ = harness.connectSyncingApp()
        #expect(harness.app.commentDeliveries.isEmpty, "the queued result went with the comment")
        #expect(harness.broker.commentRecords().isEmpty)
    }

    @Test func syncReplacesWaitingEntriesAndKeepsResults() async throws {
        let harness = BrokerHarness(attachApp: false)
        harness.broker.registerComments([comment(IDs.first), comment(IDs.second), comment(IDs.foreign)])
        _ = await harness.resolve("c-e5f607")
        _ = harness.connectSyncingApp(comments: [comment(IDs.second, note: "Edited."), comment(IDs.other)])
        let records = harness.broker.commentRecords()
        #expect(Set(records.map(\.comment.id)) == [IDs.second, IDs.other, IDs.foreign])
        #expect(records.first { $0.comment.id == IDs.second }?.comment.text.hasSuffix("Note: Edited.") == true)
        #expect(records.first { $0.comment.id == IDs.foreign }?.result?.outcome == "fixed", "an answer survives the sync")
        #expect(harness.deliveredIDs == [IDs.foreign])
    }

    @Test func registeringAnAnsweredCommentAgainClearsItsAnswer() async throws {
        let harness = BrokerHarness(attachApp: false)
        harness.broker.registerComments([comment(IDs.other)])
        _ = await harness.resolve("c-a1b2c3", "declined")
        harness.broker.registerComments([comment(IDs.other, note: "Sent again.")])
        let record = try #require(harness.broker.commentRecords().first)
        #expect(record.result == nil)
        #expect(record.comment.text.hasSuffix("Sent again."))
        _ = harness.connectSyncingApp(comments: [comment(IDs.other)])
        #expect(harness.app.commentDeliveries.isEmpty, "the old answer is gone")
        #expect(await harness.resolve("c-a1b2c3")?.ok == true)
    }

    @Test func sessionExitDropsWaitingCommentsButKeepsUnappliedResults() async throws {
        let harness = BrokerHarness(attachApp: false)
        harness.addOtherSession()
        harness.broker.registerComments([
            comment(IDs.first, session: "other"), comment(IDs.second, session: "other"), comment(IDs.foreign, session: "other"),
            comment(IDs.other),
        ])
        _ = await harness.resolve("c-7f3a2b2", token: otherToken)
        _ = await harness.resolve("c-e5f607", token: otherToken)
        let app = harness.connectSyncingApp(comments: [comment(IDs.first, session: "other"), comment(IDs.other)])
        harness.broker.commentResultsApplied([IDs.foreign])
        harness.broker.sessionExited(hostSessionID: "host-other", status: 0)
        _ = harness.broker.sync { 0 }
        let records = harness.broker.commentRecords()
        #expect(Set(records.map(\.comment.id)) == [IDs.second, IDs.other],
                "waiting and applied entries of the ended session go; its unapplied result stays")
        harness.broker.detachApp(id: app)
        _ = harness.connectSyncingApp(comments: [comment(IDs.other)])
        #expect(harness.app.commentDeliveries.last?.map(\.id) == [IDs.second])
        harness.broker.commentResultsApplied([IDs.second])
        _ = harness.broker.sync { 0 }
        #expect(harness.broker.commentRecords().map(\.comment.id) == [IDs.other])
    }

    @Test func anAnswerOlderThanAResentCommentIsDroppedOnSync() async throws {
        let harness = BrokerHarness(attachApp: false)
        harness.broker.registerComments([comment(IDs.other, note: "Old note.", at: 0)])
        harness.clock.advance(5)
        #expect(await harness.resolve("c-a1b2c3", reply: "Answered the old note.")?.ok == true)
        // Edited and sent again at +10 while the app could not tell the broker.
        _ = harness.connectSyncingApp(comments: [comment(IDs.other, note: "New note.", at: 10)])
        #expect(harness.app.commentDeliveries.isEmpty, "the old answer must not mark the new request")
        let record = try #require(harness.broker.commentRecords().first)
        #expect(record.result == nil)
        #expect(record.comment.text.hasSuffix("Note: New note."))
        #expect(try #require(await harness.call("comment.list")).text?.contains("Note: New note.") == true)
        harness.clock.advance(10)
        #expect(await harness.resolve("c-a1b2c3", "declined")?.ok == true)
        #expect(harness.app.commentDeliveries.last?.map(\.outcome) == ["declined"])
    }

    @Test func anAnswerNewerThanTheListedCommentIsKeptAndDelivered() async throws {
        let harness = BrokerHarness(attachApp: false)
        harness.broker.registerComments([comment(IDs.other, at: 0), comment(IDs.first, at: 0)])
        #expect(await harness.resolve("c-a1b2c3")?.ok == true, "answered at the moment it was sent")
        harness.clock.advance(5)
        #expect(await harness.resolve("c-7f3a2b1", "declined")?.ok == true)
        _ = harness.connectSyncingApp(comments: [comment(IDs.other, at: 0), comment(IDs.first, at: 0)])
        #expect(Set(harness.deliveredIDs) == [IDs.other, IDs.first])
        #expect(harness.broker.commentRecords().allSatisfy { $0.result != nil })
    }

    @Test func aResumedSessionAnswersCommentsSyncedAgain() async throws {
        let harness = BrokerHarness(attachApp: false)
        harness.addOtherSession()
        let app = harness.connectSyncingApp(comments: [comment(IDs.other, session: "other"), comment(IDs.foreign, session: "other")])
        _ = await harness.resolve("c-e5f607", token: otherToken)
        harness.broker.sessionExited(hostSessionID: "host-other", status: 0)
        _ = harness.broker.sync { 0 }
        #expect(harness.broker.commentRecords().map(\.comment.id) == [IDs.foreign], "only the unapplied answer stays")
        // Suijin resumes the session in place: same session id, new process and token.
        let resumedToken = String(repeating: "r", count: 64)
        harness.broker.sessionSpawned(hostSessionID: "host-other-2", sessionID: "other", agent: .claude, token: resumedToken)
        let stale = try #require(await harness.resolve("c-a1b2c3", token: otherToken))
        #expect(stale.error?.code == "no-such-comment", "the ended process's token no longer works")
        // The already synced connection syncs again when the session resumes.
        harness.broker.syncComments([comment(IDs.other, session: "other")], appID: app)
        _ = harness.broker.sync { 0 }
        #expect(try #require(await harness.call("comment.list", token: resumedToken)).text?.contains("[c-a1b2c3]") == true)
        let resolved = try #require(await harness.resolve("c-a1b2c3", reply: "Done after resuming.", token: resumedToken))
        #expect(resolved.ok)
        #expect(harness.app.commentDeliveries.last?.map(\.id) == [IDs.other])
        // The answer from before the exit, applied now, is still remembered for the resumed session.
        harness.broker.commentResultsApplied([IDs.foreign])
        let again = try #require(await harness.resolve("c-e5f607", token: resumedToken))
        #expect(again.error?.code == "already-resolved")
    }

    @Test func theLedgerSurvivesARestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        do {
            let harness = BrokerHarness(stateFile: file, attachApp: false)
            harness.broker.registerComments([comment(IDs.first), comment(IDs.other)])
            #expect(await harness.resolve("c-a1b2c3", reply: "Done.")?.ok == true)
        }
        let reopened = Broker(dataRoot: directory, stateFile: file, io: nil)
        reopened.open(tick: false)
        let records = reopened.commentRecords()
        #expect(records.first { $0.comment.id == IDs.first }?.result == nil)
        #expect(records.first { $0.comment.id == IDs.other }?.result?.reply == "Done.")
        let app = RecordingAppLink()
        let id = UUID()
        reopened.attachApp(app, id: id)
        reopened.syncComments([comment(IDs.first)], appID: id)
        _ = reopened.sync { 0 }
        #expect(app.commentDeliveries.flatMap { $0 }.map(\.id) == [IDs.other])
        reopened.close()
    }

    @Test func stateFilesWithAndWithoutCommentsLoadInBothBuilds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("state.json")
        // Written by a helper that predates comments.
        let old = #"{"snapshot":{"dispatches":[],"messages":[],"runs":[{"coordinatorSessionID":"c","createdAt":"2026-01-01T00:00:00Z","id":"r-1"}],"tasks":[]},"version":1}"#
        try Data(old.utf8).write(to: file)
        let broker = Broker(dataRoot: directory, stateFile: file, io: nil)
        broker.open(tick: false)
        #expect(broker.snapshot().runs.map(\.id) == ["r-1"])
        #expect(broker.commentRecords().isEmpty)
        broker.registerComments([comment(IDs.other)])
        _ = broker.sync { 0 }
        broker.close()
        // A helper that predates comments decodes the document as it always did, ignoring the new key.
        struct OlderDocument: Decodable {
            var version: Int
            var snapshot: OrchestrationSnapshot
        }
        let data = try Data(contentsOf: file)
        let older = try OrchestrationCoding.decoder.decode(OlderDocument.self, from: data)
        #expect(older.snapshot.runs.map(\.id) == ["r-1"])
        #expect(String(decoding: data, as: UTF8.self).contains(IDs.other))
    }
}

@Suite("suijin comment")
struct CommentCLITests {
    let parser = CommandParser(readFile: { _ in nil }, readStandardInput: { "from stdin" })

    private func failure(_ args: [String]) -> CLIUsageError? {
        do { _ = try parser.parse(args); return nil } catch let error as CLIUsageError { return error } catch { return nil }
    }

    @Test func parsesEveryForm() throws {
        #expect(try parser.parse(["comment", "list"]) == .broker(command: "comment.list", options: [:], json: false))
        #expect(try parser.parse(["comment", "list", "--json"]) == .broker(command: "comment.list", options: [:], json: true))
        #expect(try parser.parse(["comment", "resolve", "c-7f3a2b", "--fixed"])
                == .broker(command: "comment.resolve", options: ["id": "c-7f3a2b", "outcome": "fixed"], json: false))
        #expect(try parser.parse(["comment", "resolve", "--declined", "c-7f3a2b", "--reply", "Out of scope.", "--json"])
                == .broker(command: "comment.resolve", options: ["id": "c-7f3a2b", "outcome": "declined", "reply": "Out of scope."], json: true))
        #expect(try parser.parse(["comment", "resolve", "7f3a2b10-0000-4000-8000-000000000001", "--fixed", "--reply=Renamed it."])
                == .broker(command: "comment.resolve",
                           options: ["id": "7f3a2b10-0000-4000-8000-000000000001", "outcome": "fixed", "reply": "Renamed it."], json: false))
        #expect(try parser.parse(["comment", "resolve", "c-1", "--fixed", "--reply", "-"])
                == .broker(command: "comment.resolve", options: ["id": "c-1", "outcome": "fixed", "reply": "from stdin"], json: false))
        #expect(try parser.parse(["comment", "resolve", "--help"]) == .help(topic: "comment resolve"))
    }

    @Test func usageErrors() {
        #expect(failure(["comment", "resolve", "c-1", "--fixed", "--declined"])?.message == "Use either `--fixed` or `--declined`, not both.")
        #expect(failure(["comment", "resolve", "c-1"])?.message == "Missing `--fixed` or `--declined`.")
        #expect(failure(["comment", "resolve", "c-1", "--reply", "x"])?.message == "Missing `--fixed` or `--declined`.")
        #expect(failure(["comment", "resolve", "--fixed"])?.message.hasPrefix("Missing the comment id") == true)
        #expect(failure(["comment", "resolve", "", "--fixed"])?.message.hasPrefix("Missing the comment id") == true)
        #expect(failure(["comment", "resolve", "c-1", "--fixed", "--reply"])?.message == "`--reply` needs a value.")
        #expect(failure(["comment", "resolve", "c-1", "--fixd"])?.suggestion == "--fixed")
        #expect(failure(["comment", "resolve", "c-1", "--fixed", "--force"])?.message.contains("Unknown flag `--force`") == true)
        #expect(failure(["comment", "resolve", "c-1", "c-2", "--fixed"])?.message.contains("Unexpected argument `c-2`") == true)
        #expect(failure(["comment", "resolve", "-x", "--fixed"])?.message.contains("Unexpected argument") == true)
        #expect(failure(["comment", "list", "c-1"])?.message.contains("Unexpected argument") == true)
        #expect(failure(["comment", "list", "--all"])?.message.contains("Unknown flag") == true)
        #expect(failure(["comment"])?.suggestion?.hasPrefix("suijin comment") == true)
        #expect(failure(["coment", "list"])?.suggestion == "suijin comment list")
        let cli = SuijinCLI(environment: [OrchestrationEnvironment.sessionToken: "tok"], skillsDirectory: nil, version: "t",
                            transport: { _, _ in
                                Issue.record("a usage error never reaches the broker")
                                return .failure(BrokerFailure(code: "x", message: "x"))
                            })
        let result = cli.run(["comment", "resolve", "c-1", "--fixed", "--declined"])
        #expect(result.exitCode == SuijinCLI.Exit.usage)
        #expect(result.stderr.contains("suijin comment resolve <id> (--fixed | --declined)"))
    }

    @Test func printsTheConfirmationOrTheRefusal() {
        let seen = Mutex<[BrokerRequest]>([])
        let ok = SuijinCLI(environment: [OrchestrationEnvironment.sessionToken: "tok"], skillsDirectory: nil, version: "t",
                           transport: { request, _ in
                               seen.withLock { $0.append(request) }
                               return .success(["id": "x"], text: "Marked c-7f3a2b as fixed.")
                           })
        #expect(ok.run(["comment", "resolve", "c-7f3a2b", "--fixed"]) == CLIResult(stdout: "Marked c-7f3a2b as fixed.\n"))
        #expect(seen.withLock { $0 }.first?.command == "comment.resolve")
        #expect(seen.withLock { $0 }.first?.options == ["id": "c-7f3a2b", "outcome": "fixed"])
        let refusing = SuijinCLI(environment: [OrchestrationEnvironment.sessionToken: "tok"], skillsDirectory: nil, version: "t",
                                 transport: { _, _ in .failure(CommentLedger.noSuchComment) })
        let refused = refusing.run(["comment", "resolve", "c-7f3a2b", "--declined"])
        #expect(refused.exitCode == SuijinCLI.Exit.refused)
        #expect(refused.stderr.hasPrefix("suijin: No such comment for this session.\nNext: Run `suijin comment list`"))
        let help = SuijinCLI(environment: [:], skillsDirectory: nil, version: "t").run(["help"]).stdout
        #expect(help.contains("suijin comment list [--json]"))
        #expect(help.contains("suijin comment resolve <id> (--fixed | --declined) [--reply <text>] [--json]"))
    }
}

@Suite("Review comments over the real transport", .serialized)
struct ReviewCommentTransportTests {
    /// A real PTY session's agent runs `suijin comment resolve` over the broker socket; the app, connected to the
    /// broker endpoint over XPC and synced, receives the result.
    @Test func resolveOverTheSocketReachesTheSyncedApp() async throws {
        let directory = OrchestrationPaths.userTemporaryDirectory().appendingPathComponent("rc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataRoot = directory.appendingPathComponent("d", isDirectory: true)
        let manager = SessionManager(configuration: SessionManager.Configuration(metadataDirectory: nil))
        let hub = OrchestrationHub(manager: manager)
        manager.setObserver(hub)
        manager.start()
        defer { hub.shutdown() }
        let token = OrchestrationToken.make()
        let info = try manager.spawn(PTYSpawnRequest(
            executable: "/bin/cat", environment: [OrchestrationEnvironment.sessionToken: token, "PATH": "/usr/bin:/bin"],
            cwd: "/tmp", metadata: [OrchestrationMetadata.session: "S-1", OrchestrationMetadata.dataRoot: dataRoot.path,
                                    OrchestrationMetadata.agent: "claude"]))
        defer { manager.terminate(sessionID: info.id) }

        let client = ResultCollectingClient()
        let connection = NSXPCConnection(listenerEndpoint: hub.endpoint(dataRoot: dataRoot))
        connection.remoteObjectInterface = OrchestrationXPCInterfaces.host()
        connection.exportedInterface = OrchestrationXPCInterfaces.client()
        connection.exportedObject = client
        connection.resume()
        defer { connection.invalidate() }
        let proxy = try #require(connection.remoteObjectProxy as? any OrchestrationHostXPC)
        let accepted = await withCheckedContinuation { continuation in proxy.hello(appBuild: "test") { continuation.resume(returning: $0) } }
        #expect(accepted)
        let pending = [comment(IDs.other, session: "S-1")]
        proxy.syncComments(try OrchestrationCoding.encoder.encode([PendingComment]()))
        proxy.registerComments(try OrchestrationCoding.encoder.encode(pending))
        // Messages on one connection arrive in order: once the snapshot answers, both calls above reached the broker.
        _ = await withCheckedContinuation { continuation in proxy.snapshot { continuation.resume(returning: $0) } }

        let cli = SuijinCLI(environment: [OrchestrationEnvironment.sessionToken: token, OrchestrationEnvironment.dataRoot: dataRoot.path],
                            skillsDirectory: nil, version: "test")
        let list = cli.run(["comment", "list"])
        #expect(list.exitCode == 0, "\(list.stderr)")
        #expect(list.stdout.contains("Review comments on docs/plan.md:"))
        let resolved = cli.run(["comment", "resolve", "c-a1b2c3", "--fixed", "--reply", "Tightened it."])
        #expect(resolved.exitCode == 0, "\(resolved.stderr)")
        #expect(resolved.stdout == "Marked c-a1b2c3 as fixed.\n")
        let results = try #require(await client.waitForResults())
        #expect(results.map(\.id) == [IDs.other])
        #expect(results.first?.reply == "Tightened it.")
        let again = cli.run(["comment", "resolve", "c-a1b2c3", "--fixed"])
        #expect(again.exitCode == SuijinCLI.Exit.refused)
        #expect(again.stderr.contains("already reported as fixed"))

        proxy.commentResultsApplied(try OrchestrationCoding.encoder.encode([IDs.other]))
        _ = await withCheckedContinuation { continuation in proxy.snapshot { continuation.resume(returning: $0) } }
        let broker = hub.broker(dataRoot: dataRoot)
        #expect(broker.commentRecords().first?.acknowledged == true)
    }
}

/// An app that records the comment results the broker sends.
private final class ResultCollectingClient: NSObject, OrchestrationClientXPC, Sendable {
    private let results = Mutex<[CommentResult]>([])

    func startWorker(_ request: Data) {}
    func stateChanged() {}
    func attention(_ event: Data) {}
    func commentsResolved(_ results: Data) {
        guard let decoded = try? OrchestrationCoding.decoder.decode([CommentResult].self, from: results) else { return }
        self.results.withLock { $0.append(contentsOf: decoded) }
    }

    func waitForResults(timeout: TimeInterval = 5) async -> [CommentResult]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = results.withLock { $0 }
            if !current.isEmpty { return current }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}
