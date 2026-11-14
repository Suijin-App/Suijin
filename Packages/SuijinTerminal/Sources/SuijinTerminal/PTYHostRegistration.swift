import Darwin
import Foundation
import Security
import SuijinPTYProtocol

/// The PTY host's launchd registration as `PTYHostClient` sees it: its state, registering and renewing it, whether a
/// helper process runs, and which build made the registration. `live` is the real system; tests build their own so no
/// LaunchAgent is ever registered or removed by them.
///
/// Why the build matters: when an app registers its agent, launchd records a launch constraint for the helper (its
/// signing identifier, team and signature kind, e.g. development or Developer ID) and where the program is. A
/// registration made by another copy or another kind of build can then refuse to start this bundle's helper
/// (`Launch Constraint Violation`), while `SMAppService` still reports it as enabled.
public struct PTYHostRegistration: Sendable {
    /// What launchd says about the agent (System Settings › General › Login Items).
    public var approval: @MainActor @Sendable () -> HostApproval
    /// Registers the agent unless it is registered; true when it registered it now.
    public var register: @MainActor @Sendable () throws -> Bool
    /// Removes the agent and registers it again. Stops a running helper, so callers make sure none runs.
    public var reregister: @MainActor @Sendable () async throws -> Void
    /// Whether a helper process of this user runs; nil when that cannot be told (treated as running).
    public var helperRunning: @MainActor @Sendable () -> Bool?
    /// The identity recorded by the last registration this app made, and recording a new one.
    public var recordedIdentity: @MainActor @Sendable () -> String?
    public var recordIdentity: @MainActor @Sendable (String) -> Void
    /// What a registration made by this copy gives launchd: the bundle's path and the kind and team of its signature.
    /// Not the build: an update in place keeps all three, and launchd starts its helper under the old registration.
    public var identity: String
    /// Whether this process may renew the registration: only a real app launch, never a test host.
    public var canRepair: Bool

    public init(approval: @escaping @MainActor @Sendable () -> HostApproval,
                register: @escaping @MainActor @Sendable () throws -> Bool,
                reregister: @escaping @MainActor @Sendable () async throws -> Void,
                helperRunning: @escaping @MainActor @Sendable () -> Bool?,
                recordedIdentity: @escaping @MainActor @Sendable () -> String?,
                recordIdentity: @escaping @MainActor @Sendable (String) -> Void,
                identity: String, canRepair: Bool) {
        self.approval = approval
        self.register = register
        self.reregister = reregister
        self.helperRunning = helperRunning
        self.recordedIdentity = recordedIdentity
        self.recordIdentity = recordIdentity
        self.identity = identity
        self.canRepair = canRepair
    }

    /// Defaults key of the recorded identity.
    static let identityKey = "PTYHostRegistrationIdentity"

    public static let live: PTYHostRegistration = {
        let signature = CodeSignature.ofThisProcess()
        return PTYHostRegistration(
            approval: { PTYHostClient.liveApproval() },
            register: { try PTYHostClient.registerAgent() },
            reregister: { try await PTYHostClient.reregisterAgent() },
            helperRunning: { HelperProcessProbe.isRunning() },
            recordedIdentity: { UserDefaults.standard.string(forKey: identityKey) },
            recordIdentity: { UserDefaults.standard.set($0, forKey: identityKey) },
            identity: identity(bundlePath: Bundle.main.bundleURL.standardizedFileURL.path, signature: signature),
            canRepair: canRepair(bundle: .main, environment: ProcessInfo.processInfo.environment)
        )
    }()

    /// "<bundle path>|<signature kind>|<team>": a registration made from another place, or by a build signed another
    /// way (a development build against a Developer ID one), differs; one made by an earlier build of this copy does not.
    public static func identity(bundlePath: String, signature: CodeSignature) -> String {
        "\(bundlePath)|\(signature.kind.rawValue)|\(signature.team)"
    }

    /// Only an app bundle that carries the agent's plist, outside of tests, renews the registration: a test host must
    /// not change the user's background items. Nor does a copy macOS runs from a temporary place (App Translocation) or
    /// from a read-only volume (a mounted disk image): a registration pointing there breaks once it is gone.
    static func canRepair(bundle: Bundle, environment: [String: String]) -> Bool {
        guard environment["XCTestConfigurationFilePath"] == nil, environment["XCTestBundlePath"] == nil,
              environment[PTYHostConstants.machServiceOverrideEnv] == nil,
              bundle.bundleURL.pathExtension == "app" else { return false }
        let readOnly = (try? bundle.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        guard !isTransientLocation(path: bundle.bundleURL.path, readOnlyVolume: readOnly) else { return false }
        let plist = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(PTYHostConstants.launchAgentPlist)
        return FileManager.default.fileExists(atPath: plist.path)
    }

    /// A place the app runs from only for now: App Translocation's random folder, or a read-only volume.
    static func isTransientLocation(path: String, readOnlyVolume: Bool) -> Bool {
        readOnlyVolume || path.contains("/AppTranslocation/")
    }
}

/// How a binary is signed, as far as launchd's launch constraint for the helper cares: the kind of signature
/// (`validation-category` in the constraint) and the team.
public struct CodeSignature: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case developerID = "developer-id"
        case development
        case distribution
        case adHoc = "ad-hoc"
        case other
    }

    public var kind: Kind
    public var team: String

    public init(kind: Kind, team: String) {
        self.kind = kind
        self.team = team
    }

    /// The kind from the leaf certificate's name ("Developer ID Application: …", "Apple Development: …"); nil means no
    /// certificate, an ad-hoc signature.
    public static func kind(leafCertificateSummary summary: String?) -> Kind {
        guard let summary else { return .adHoc }
        if summary.hasPrefix("Developer ID Application") { return .developerID }
        if summary.hasPrefix("Apple Development") || summary.hasPrefix("Mac Developer") { return .development }
        if summary.hasPrefix("Apple Distribution") || summary.hasPrefix("3rd Party Mac Developer")
            || summary.hasPrefix("Mac App Distribution") { return .distribution }
        return .other
    }

    /// This process's own signature.
    static func ofThisProcess() -> CodeSignature {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let info = information as? [String: Any] else { return CodeSignature(kind: .other, team: "") }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        let leaf = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        let summary = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        return CodeSignature(kind: kind(leafCertificateSummary: summary), team: team)
    }
}

/// Finds a running `SuijinPTYHost` of the current user, whichever build or copy it was started from.
enum HelperProcessProbe {
    static let processName = "SuijinPTYHost"

    /// True when one runs, false when none does, nil when that cannot be told (treated as running by callers).
    static func isRunning(named name: String = processName) -> Bool? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let listed = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let uid = getuid()
        var matched = false
        for pid in pids.prefix(Int(max(listed, 0))) where pid > 0 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid == uid else { continue }
            let command = withUnsafeBytes(of: info.pbsi_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if command == name {
                matched = true
                break
            }
        }
        return verdict(listed: Int(listed), capacity: pids.count, matched: matched)
    }

    /// A match is certain; "none runs" only from a complete list. A list that filled the whole buffer may have been cut
    /// short, so it says nothing about the processes left out.
    static func verdict(listed: Int, capacity: Int, matched: Bool) -> Bool? {
        if matched { return true }
        guard listed > 0, listed < capacity else { return nil }
        return false
    }
}
