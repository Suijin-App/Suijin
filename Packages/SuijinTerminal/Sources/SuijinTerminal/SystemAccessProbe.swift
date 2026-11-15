import Foundation
import ServiceManagement
import SuijinPTYProtocol

/// Whether macOS lets Suijin keep its terminal host as a background item (System Settings > General > Login Items).
public enum HostApproval: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    /// The LaunchAgent plist is missing from the app bundle.
    case notFound
}

extension PTYHostClient {
    /// The background item's state as launchd reports it. Only reads: nothing is registered (`register()` does that).
    /// launchd can report an agent as enabled that it cannot start; `isHelperUnreachable` tells that apart.
    public var approval: HostApproval {
        registration.approval()
    }

    /// The `SMAppService` reading behind `PTYHostRegistration.live`.
    nonisolated static func liveApproval() -> HostApproval {
        switch SMAppService.agent(plistName: PTYHostConstants.launchAgentPlist).status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notRegistered
        }
    }
}

/// Finds out whether Full Disk Access is granted. macOS has no API for that, so the probe lists folders in the home
/// Library that every account has and that only Full Disk Access opens. Their existence can be seen without the
/// permission, their contents cannot. A database that older probes read (`com.apple.TCC/TCC.db`) is no use: without
/// the permission its folder looks missing, which says nothing.
public enum FullDiskAccessProbe {
    public enum Result: Equatable, Sendable {
        case granted
        case denied
        /// None of the folders exists, or the probe could not run; never treated as granted.
        case unknown
    }

    /// Folders tried in order, relative to the home directory; the first one that exists decides.
    public static let protectedFolders = ["Library/Safari", "Library/Mail", "Library/Messages"]

    /// The probe as a shell script taking the folders as arguments: exit 0 when one can be listed, 1 when one exists
    /// but cannot be listed, 2 when none exists.
    static let script = #"for d in "$@"; do ls "$d" >/dev/null 2>&1 && exit 0; ls -d "$d" >/dev/null 2>&1 && exit 1; done; exit 2"#

    public static func result(forExitStatus status: Int32?) -> Result {
        switch status {
        case 0: .granted
        case 1: .denied
        default: .unknown
        }
    }

    /// Probes from this process: right when sessions run in the app because the terminal host is unavailable.
    public static func inProcess(home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> Result {
        for folder in protectedFolders {
            let path = home + "/" + folder
            if (try? fileManager.contentsOfDirectory(atPath: path)) != nil { return .granted }
            if fileManager.fileExists(atPath: path) { return .denied }
        }
        return .unknown
    }

    /// Probes from a process the terminal host starts, which is how agents and shells run: macOS decides file access
    /// by the process responsible for them, so this answers for what a session can read.
    @MainActor
    public static func inHost(_ client: PTYHostClient = .shared, home: String = NSHomeDirectory(),
                              timeout: Duration = .seconds(5)) async -> Result {
        let request = PTYSpawnRequest(
            executable: "/bin/sh", arguments: ["-c", script, "sh"] + protectedFolders.map { home + "/" + $0 },
            environment: ["PATH": "/usr/bin:/bin"], cwd: "/", metadata: ["suijin.probe": "full-disk-access"])
        guard let id = try? await client.spawn(request) else { return .unknown }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let info = try? await client.listSessions().first(where: { $0.id == id }), !info.isRunning {
                client.terminate(id) // read: the host can forget it
                return result(forExitStatus: info.exitStatus)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        client.terminate(id)
        return .unknown
    }
}
