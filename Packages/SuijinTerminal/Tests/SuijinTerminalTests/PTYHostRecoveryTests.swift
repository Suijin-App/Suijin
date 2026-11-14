import Darwin
import Foundation
@testable import SuijinTerminal
import SuijinPTYProtocol
import Testing

/// A listener that turns every connection away, as launchd does in effect when it cannot start the helper: requests
/// fail at once instead of waiting for a timeout.
private final class RefusingListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool { false }
}

/// A helper that accepts the connection and never answers, so requests run into the client's timeout (what the app
/// saw when launchd kept the request while failing to start the helper).
private final class SilentHost: NSObject, PTYHostXPC, @unchecked Sendable {
    func handshake(clientProtocolVersion: Int, reply: @escaping @Sendable (Int, String) -> Void) {}
    func listSessions(reply: @escaping @Sendable (Data) -> Void) {}
    func spawn(_ request: Data, reply: @escaping @Sendable (String?, String?) -> Void) {}
    func attach(_ sessionID: String, reply: @escaping @Sendable (Data?, Data?) -> Void) {}
    func detach(_ sessionID: String) {}
    func write(_ sessionID: String, data: Data) {}
    func resize(_ sessionID: String, cols: Int, rows: Int) {}
    func terminate(_ sessionID: String) {}
    func shutdownIfIdle() {}
    func ack(_ sessionID: String, bytes: Int) {}
    func orchestrationEndpoint(dataRoot: String, reply: @escaping @Sendable (NSXPCListenerEndpoint?, String?) -> Void) {}
}

private final class SilentListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let host = SilentHost()

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = PTYXPCInterfaces.host()
        connection.remoteObjectInterface = PTYXPCInterfaces.client()
        connection.exportedObject = host
        connection.resume()
        return true
    }
}

/// A launchd registration in memory: which helper the client reaches depends on whether it was renewed, the way a
/// stale registration keeps launchd from starting the helper until the app registers it again.
@MainActor
private final class FakeRegistration {
    enum Broken { case refusing, silent }

    var approval = HostApproval.enabled
    var helperRunning: Bool? = false
    var recorded: String?
    var canRepair = true
    /// The helper answers once the registration was renewed (or from the start).
    var healthy = false
    /// What a renewal does to the helper: nothing (it stays broken) when false.
    var renewalHeals = true
    var registersNow = false
    var registerError: PTYHostClientError?
    var reregisterError: PTYHostClientError?
    /// How long a renewal takes.
    var renewalDelay: Duration = .zero
    var broken = Broken.refusing
    private(set) var registerCalls = 0
    private(set) var reregisterCalls = 0
    /// Connections opened while a renewal ran: what would let launchd start a helper that the renewal then stops.
    private(set) var connectionsDuringRenewal = 0
    private var renewing = false
    let identity = "/Applications/Suijin.app|developer-id|TEAM"

    let working = FakeListener(version: PTYHostConstants.protocolVersion)
    let refusing = RefusingListener()
    let silent = SilentListener()

    var registration: PTYHostRegistration {
        PTYHostRegistration(
            approval: { self.approval },
            register: {
                self.registerCalls += 1
                if let error = self.registerError { throw error }
                return self.registersNow
            },
            reregister: {
                self.reregisterCalls += 1
                self.renewing = true
                defer { self.renewing = false }
                if self.renewalDelay > .zero { try await Task.sleep(for: self.renewalDelay) }
                if let error = self.reregisterError { throw error }
                self.registerError = nil
                if self.renewalHeals { self.healthy = true }
            },
            helperRunning: { self.helperRunning },
            recordedIdentity: { self.recorded },
            recordIdentity: { self.recorded = $0 },
            identity: identity, canRepair: canRepair)
    }

    func client(timeout: TimeInterval = 5) -> PTYHostClient {
        let client = PTYHostClient(connectionFactory: { [unowned self] in
            if self.renewing { self.connectionsDuringRenewal += 1 }
            let endpoint = self.healthy ? self.working.listener.endpoint
                : self.broken == .silent ? self.silent.listener.endpoint : self.refusing.listener.endpoint
            return NSXPCConnection(listenerEndpoint: endpoint)
        })
        client.requestTimeout = timeout
        client.registration = registration
        return client
    }
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
@Suite("PTY host recovery")
struct PTYHostRecoveryTests {
    // MARK: Decisions

    @Test func aHelperThatCannotBeReachedIsRegisteredAgainOnlyWhenNoneRuns() {
        for error in [PTYHostClientError.timedOut, .connectionFailed("invalid"), .notResponding] {
            #expect(PTYHostClient.recoveryStep(after: error, approval: .enabled, helperRunning: false, canRepair: true) == .reregister)
            #expect(PTYHostClient.recoveryStep(after: error, approval: .notRegistered, helperRunning: false, canRepair: true) == .reregister)
            // A running helper may hold sessions: renewing the registration would stop it, so only try again.
            #expect(PTYHostClient.recoveryStep(after: error, approval: .enabled, helperRunning: true, canRepair: true) == .retry)
            // Not knowing counts as running.
            #expect(PTYHostClient.recoveryStep(after: error, approval: .enabled, helperRunning: nil, canRepair: true) == .retry)
            // A test host, or a launch whose automatic renewal is spent, only tries again.
            #expect(PTYHostClient.recoveryStep(after: error, approval: .enabled, helperRunning: false, canRepair: false) == .retry)
            // Waiting for the user's approval or a broken bundle: nothing the app can do by itself.
            #expect(PTYHostClient.recoveryStep(after: error, approval: .requiresApproval, helperRunning: false, canRepair: true) == .none)
            #expect(PTYHostClient.recoveryStep(after: error, approval: .notFound, helperRunning: false, canRepair: true) == .none)
        }
    }

    @Test func otherFailuresAreNotRepaired() {
        let hostErrors: [PTYHostClientError] = [.protocolMismatch(host: 1, client: 3), .spawnFailed("no such file"),
                                                .sessionNotFound("x"), .invalidReply, .requiresApproval]
        let others: [any Error] = hostErrors + [CocoaError(.fileNoSuchFile)]
        for error in others {
            #expect(PTYHostClient.recoveryStep(after: error, approval: .enabled, helperRunning: false, canRepair: true) == .none)
        }
    }

    @Test func aRegistrationFromAnotherBuildIsRenewedOnlyWhileNoHelperRuns() {
        let current = "/Applications/Suijin.app|developer-id|TEAM"
        // Registered by a development build somewhere else.
        #expect(PTYHostClient.registrationNeedsRefresh(recorded: "/Users/me/DerivedData/Suijin.app|development|TEAM",
                                                        current: current, approval: .enabled, helperRunning: false,
                                                        canRepair: true))
        // Before this check existed.
        #expect(PTYHostClient.registrationNeedsRefresh(recorded: nil, current: current,
                                                        approval: .enabled, helperRunning: false, canRepair: true))
        #expect(!PTYHostClient.registrationNeedsRefresh(recorded: current, current: current,
                                                         approval: .enabled, helperRunning: false, canRepair: true))
        #expect(!PTYHostClient.registrationNeedsRefresh(recorded: nil, current: current,
                                                         approval: .enabled, helperRunning: true, canRepair: true))
        #expect(!PTYHostClient.registrationNeedsRefresh(recorded: nil, current: current,
                                                         approval: .enabled, helperRunning: nil, canRepair: true))
        #expect(!PTYHostClient.registrationNeedsRefresh(recorded: nil, current: current,
                                                         approval: .requiresApproval, helperRunning: false, canRepair: true))
        #expect(!PTYHostClient.registrationNeedsRefresh(recorded: nil, current: current,
                                                         approval: .enabled, helperRunning: false, canRepair: false))
    }

    @Test func theReportedErrorSaysWhatTheUserCanActOn() {
        #expect(PTYHostClient.reportedError(after: PTYHostClientError.timedOut, approval: .enabled) as? PTYHostClientError == .notResponding)
        #expect(PTYHostClient.reportedError(after: PTYHostClientError.connectionFailed("x"), approval: .notRegistered)
                as? PTYHostClientError == .notResponding)
        #expect(PTYHostClient.reportedError(after: PTYHostClientError.timedOut, approval: .requiresApproval)
                as? PTYHostClientError == .requiresApproval)
        #expect(PTYHostClient.reportedError(after: PTYHostClientError.timedOut, approval: .notFound) as? PTYHostClientError == .notFound)
        #expect(PTYHostClient.reportedError(after: PTYHostClientError.protocolMismatch(host: 1, client: 3), approval: .enabled)
                as? PTYHostClientError == .protocolMismatch(host: 1, client: 3))
        #expect(PTYHostClientError.notResponding.errorDescription?.isEmpty == false)
        #expect(PTYHostClientError.registeredElsewhere.errorDescription?.isEmpty == false)
    }

    @Test func onlyARealAppBundleOutsideTestsMayRepair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-repair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Suijin.app")
        let agents = app.appendingPathComponent("Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: app))
        // No plist in it yet.
        #expect(!PTYHostRegistration.canRepair(bundle: bundle, environment: [:]))
        try Data().write(to: agents.appendingPathComponent(PTYHostConstants.launchAgentPlist))
        #expect(PTYHostRegistration.canRepair(bundle: bundle, environment: [:]))
        #expect(!PTYHostRegistration.canRepair(bundle: bundle, environment: ["XCTestConfigurationFilePath": "/x"]))
        #expect(!PTYHostRegistration.canRepair(bundle: bundle, environment: ["XCTestBundlePath": "/x"]))
        #expect(!PTYHostRegistration.canRepair(bundle: bundle,
                                               environment: [PTYHostConstants.machServiceOverrideEnv: "com.tekmium.suijin.ptyhost.e2e"]))
        // This test runner is no app.
        #expect(!PTYHostRegistration.live.canRepair)
    }

    @Test func aTranslocatedOrReadOnlyCopyNeverRenews() {
        #expect(PTYHostRegistration.isTransientLocation(
            path: "/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/Suijin.app", readOnlyVolume: false))
        #expect(PTYHostRegistration.isTransientLocation(path: "/Volumes/Suijin 0.1.1/Suijin.app", readOnlyVolume: true))
        #expect(!PTYHostRegistration.isTransientLocation(path: "/Applications/Suijin.app", readOnlyVolume: false))
    }

    @Test func theIdentityIgnoresTheBuildButNotTheSignatureOrPlace() {
        let release = CodeSignature(kind: .developerID, team: "TEAM")
        let identity = PTYHostRegistration.identity(bundlePath: "/Applications/Suijin.app", signature: release)
        // An update in place keeps the path and the signature, so it renews nothing.
        #expect(identity == PTYHostRegistration.identity(bundlePath: "/Applications/Suijin.app", signature: release))
        #expect(identity != PTYHostRegistration.identity(bundlePath: "/Applications/Suijin.app",
                                                         signature: CodeSignature(kind: .development, team: "TEAM")))
        #expect(identity != PTYHostRegistration.identity(bundlePath: "/Users/me/DerivedData/Suijin.app", signature: release))
        #expect(identity != PTYHostRegistration.identity(bundlePath: "/Applications/Suijin.app",
                                                         signature: CodeSignature(kind: .developerID, team: "OTHER")))
    }

    @Test func theSignatureKindComesFromTheLeafCertificate() {
        #expect(CodeSignature.kind(leafCertificateSummary: "Developer ID Application: Someone (TEAM)") == .developerID)
        #expect(CodeSignature.kind(leafCertificateSummary: "Apple Development: someone@example.com (ABC)") == .development)
        #expect(CodeSignature.kind(leafCertificateSummary: "Mac Developer: someone (ABC)") == .development)
        #expect(CodeSignature.kind(leafCertificateSummary: "Apple Distribution: Someone (TEAM)") == .distribution)
        #expect(CodeSignature.kind(leafCertificateSummary: nil) == .adHoc)
        #expect(CodeSignature.kind(leafCertificateSummary: "Something else") == .other)
    }

    @Test func theProcessProbeAnswers() {
        // This runner runs (under the command name the kernel keeps for it); a name no process has does not.
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        #expect(proc_pidinfo(getpid(), PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size)
        let own = withUnsafeBytes(of: info.pbsi_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        #expect(HelperProcessProbe.isRunning(named: own) == true)
        #expect(HelperProcessProbe.isRunning(named: "no-such-\(UUID().uuidString.prefix(6))") == false)
    }

    @Test func aTruncatedProcessListCountsAsUnknown() {
        #expect(HelperProcessProbe.verdict(listed: 700, capacity: 764, matched: false) == false)
        // The buffer filled up: processes may be missing from the list, so "none runs" cannot be told.
        #expect(HelperProcessProbe.verdict(listed: 764, capacity: 764, matched: false) == nil)
        #expect(HelperProcessProbe.verdict(listed: 0, capacity: 764, matched: false) == nil)
        #expect(HelperProcessProbe.verdict(listed: -1, capacity: 764, matched: false) == nil)
        #expect(HelperProcessProbe.verdict(listed: 764, capacity: 764, matched: true) == true)
        // Unknown is treated as running: no renewal.
        #expect(PTYHostClient.recoveryStep(after: PTYHostClientError.timedOut, approval: .enabled,
                                           helperRunning: HelperProcessProbe.verdict(listed: 764, capacity: 764, matched: false),
                                           canRepair: true) == .retry)
    }

    // MARK: Connecting

    @Test func aStaleRegistrationIsRepairedOnceAndTheConnectionSucceeds() async throws {
        let fake = FakeRegistration()
        fake.recorded = fake.identity // as far as the record goes, nothing changed; launchd still cannot start it
        let client = fake.client()
        try await client.connect()
        #expect(fake.reregisterCalls == 1)
        #expect(fake.recorded == fake.identity)
        #expect(!client.isHelperUnreachable)
        #expect(client.hostProtocolVersion == PTYHostConstants.protocolVersion)
        // Connected: no second registration on the next call.
        try await client.connect()
        try await client.reconnect()
        #expect(fake.reregisterCalls == 1 && fake.registerCalls == 1)
        client.disconnect()
    }

    @Test func aRealTimeoutIsRepairedToo() async throws {
        let fake = FakeRegistration()
        fake.recorded = fake.identity
        fake.broken = .silent
        let client = fake.client(timeout: 0.3)
        try await client.connect()
        #expect(fake.reregisterCalls == 1)
        #expect(!client.isHelperUnreachable)
        client.disconnect()
    }

    @Test func aRegistrationMadeByAnotherBuildIsRenewedBeforeConnecting() async throws {
        let fake = FakeRegistration()
        fake.recorded = "/Users/me/DerivedData/Debug/Suijin.app|development|TEAM"
        let client = fake.client()
        try await client.connect()
        #expect(fake.reregisterCalls == 1)
        #expect(fake.recorded == fake.identity)
        client.disconnect()
    }

    @Test func aRegistrationOfAnotherCopyIsRenewed() async throws {
        // launchd has the agent for another path: registering fails with "already registered" while the status is
        // not enabled for this copy.
        let fake = FakeRegistration()
        fake.registerError = .registeredElsewhere
        let client = fake.client()
        try await client.connect()
        #expect(fake.reregisterCalls == 1)
        #expect(!client.isHelperUnreachable)
        client.disconnect()
    }

    @Test func aFreshRegistrationIsRecorded() async throws {
        let fake = FakeRegistration()
        fake.registersNow = true
        fake.healthy = true
        let client = fake.client()
        try await client.connect()
        #expect(fake.reregisterCalls == 0)
        #expect(fake.recorded == fake.identity)
        client.disconnect()
    }

    @Test func callersAtOnceShareOneRenewalAndNothingConnectsDuringIt() async throws {
        let fake = FakeRegistration()
        fake.recorded = fake.identity
        fake.renewalDelay = .milliseconds(200)
        let client = fake.client()
        // Two session starts (or Repair during a Resume) fail together and want the same repair.
        async let first: Void = client.reconnect()
        async let second: Void = client.reconnect()
        async let third: Void = client.repair()
        _ = try await (first, second, third)
        #expect(fake.reregisterCalls == 1, "one renewal, no unregister after the helper came back")
        #expect(fake.connectionsDuringRenewal == 0)
        // A renewal never runs while connected.
        try await client.repair()
        #expect(fake.reregisterCalls == 1)
        client.disconnect()
    }

    @Test func aRenewalWaitsForNothingThatRunsAndSkipsWhenAHelperAppeared() async throws {
        let fake = FakeRegistration()
        fake.recorded = fake.identity
        let client = fake.client()
        // The helper process appears between the failed request and the renewal (launchd started it for someone):
        // the check right before unregistering skips the renewal.
        let checks = Counter()
        client.registration.helperRunning = {
            checks.value += 1
            return checks.value > 1
        }
        await #expect(throws: PTYHostClientError.notResponding) { try await client.reconnect() }
        #expect(fake.reregisterCalls == 0)
    }

    @Test func repeatedFailuresRenewAtMostOncePerLaunch() async throws {
        let fake = FakeRegistration()
        fake.recorded = fake.identity
        fake.renewalHeals = false
        let client = fake.client()
        for _ in 0..<4 {
            await #expect(throws: PTYHostClientError.notResponding) { try await client.reconnect() }
        }
        #expect(fake.reregisterCalls == 1)
        #expect(client.isHelperUnreachable)
        // The stale-registration check is spent too.
        fake.recorded = "elsewhere"
        await client.refreshRegistrationIfStale()
        #expect(fake.reregisterCalls == 1)
        // The Repair button still renews.
        fake.renewalHeals = true
        try await client.repair()
        #expect(fake.reregisterCalls == 2)
        #expect(!client.isHelperUnreachable)
        client.disconnect()
    }

    @Test func aRenewalThatThrowsIsReportedAndNotRepeated() async throws {
        let fake = FakeRegistration()
        fake.recorded = fake.identity
        fake.reregisterError = .registrationFailed("denied")
        let client = fake.client()
        await #expect(throws: PTYHostClientError.registrationFailed("denied")) { try await client.reconnect() }
        await #expect(throws: PTYHostClientError.notResponding) { try await client.reconnect() }
        #expect(fake.reregisterCalls == 1)
        #expect(client.isHelperUnreachable)
    }

    @Test func aRenewalThatHangsIsCutOff() async throws {
        let fake = FakeRegistration()
        fake.recorded = fake.identity
        fake.renewalDelay = .seconds(30)
        let client = fake.client()
        client.renewalTimeout = .milliseconds(200)
        let started = ContinuousClock.now
        await #expect(throws: PTYHostClientError.notResponding) { try await client.reconnect() }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(client.isHelperUnreachable)
    }

    @Test func aRunningHelperIsNeverRegisteredAgain() async throws {
        let fake = FakeRegistration()
        fake.helperRunning = true
        let client = fake.client()
        await #expect(throws: PTYHostClientError.notResponding) { try await client.connect() }
        #expect(fake.reregisterCalls == 0)
        #expect(client.isHelperUnreachable)
        // An update with the old helper still running: the renewal waits until it is gone.
        await client.refreshRegistrationIfStale()
        #expect(fake.reregisterCalls == 0)
        fake.helperRunning = false
        await client.refreshRegistrationIfStale()
        #expect(fake.reregisterCalls == 1)
        await client.refreshRegistrationIfStale()
        #expect(fake.reregisterCalls == 1, "renewed once")
        try await client.reconnect()
        #expect(!client.isHelperUnreachable)
        client.disconnect()
    }

    @Test func withoutRepairTheFailureSaysSo() async throws {
        let fake = FakeRegistration()
        fake.canRepair = false
        let client = fake.client()
        await #expect(throws: PTYHostClientError.notResponding) { try await client.reconnect() }
        await #expect(throws: PTYHostClientError.notResponding) { try await client.repair() }
        #expect(fake.reregisterCalls == 0)
        #expect(client.isHelperUnreachable)
    }

    @Test func aHelperWaitingForApprovalIsReportedAsSuch() async throws {
        let fake = FakeRegistration()
        fake.approval = .requiresApproval
        let client = fake.client()
        await #expect(throws: PTYHostClientError.requiresApproval) { try await client.reconnect() }
        #expect(fake.reregisterCalls == 0)
    }
}
