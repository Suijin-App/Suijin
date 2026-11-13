// SuijinPTYHost — launchd agent that owns Suijin's pseudo terminals so sessions outlive the app.
//
// Registered by the app with `SMAppService.agent(plistName:)`; launchd starts it on demand when the app connects to
// the Mach service. It exits once no session is running and no app is connected (after a short grace period).
//
// It also hosts the agent orchestration broker of every data root its sessions belong to (`OrchestrationHub`): the
// `suijin` CLI in those sessions talks to it over <dataRoot>/orchestration/broker.sock, and the broker types messages
// into the agents' terminals, so delivery goes on while the app is closed.
//
// Environment:
//   SUIJIN_DATA_ROOT                  data root (default ~/Library/Application Support/Suijin); metadata goes to
//                                      <dataRoot>/pty-host/sessions
//   SUIJIN_PTYHOST_SERVICE            Mach service to listen on instead of com.tekmium.suijin.ptyhost (a test
//                                      instance next to the user's own helper)
//   SUIJIN_PTYHOST_RETENTION_HOURS    how long exited, unattached sessions are kept (default 24)
//   SUIJIN_PTYHOST_IDLE_GRACE         seconds idle before exiting (default 10)

import Foundation
import SuijinPTYHostKit
import SuijinPTYProtocol
import os
import Security

private let logger = Logger(subsystem: "com.tekmium.suijin.ptyhost", category: "main")

/// Bundle version of the enclosing app (the helper ships in Suijin.app/Contents/MacOS), or "dev".
private func hostBuild() -> String {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let appContents = executable.deletingLastPathComponent().deletingLastPathComponent()
    let appBundle = Bundle(url: appContents.deletingLastPathComponent())
    let info = appBundle?.infoDictionary ?? Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String
    let build = info["CFBundleVersion"] as? String
    switch (version, build) {
    case let (version?, build?): return "\(version) (\(build))"
    case let (nil, build?): return build
    default: return "dev"
    }
}

/// The helper's own Team ID, when it is signed with a Developer ID or development certificate.
private func ownTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
            == errSecSuccess,
          let dictionary = information as? [String: Any] else { return nil }
    return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
}

private func doubleSetting(_ name: String, default fallback: Double) -> Double {
    guard let raw = ProcessInfo.processInfo.environment[name], let value = Double(raw), value >= 0 else { return fallback }
    return value
}

// A client that disappears mid-write must not kill the helper.
signal(SIGPIPE, SIG_IGN)

var configuration = SessionManager.Configuration(metadataDirectory: SessionManager.defaultMetadataDirectory())
configuration.exitedRetention = doubleSetting("SUIJIN_PTYHOST_RETENTION_HOURS", default: 24) * 3600
configuration.idleGrace = doubleSetting("SUIJIN_PTYHOST_IDLE_GRACE", default: 10)

let manager = SessionManager(configuration: configuration) {
    // A broker socket left behind is replaced by the next helper; CLI calls meanwhile report Suijin unreachable.
    logger.info("no running sessions and no clients; exiting")
    exit(EXIT_SUCCESS)
}
let listener = NSXPCListener(machServiceName: PTYHostConstants.machServiceName)

// Only the signed Suijin app may drive the helper. Unsigned/ad-hoc development builds have no Team ID to pin; they
// rely on the per-user launchd domain (only this user's processes can look the service up).
let requirement = ownTeamIdentifier().map {
    "identifier \"com.tekmium.suijin\" and anchor apple generic and certificate leaf[subject.OU] = \"\($0)\""
}
if let requirement {
    listener.setConnectionCodeSigningRequirement(requirement)
    logger.info("accepting connections from com.tekmium.suijin signed by the helper's team")
} else {
    logger.notice("helper is not team-signed; connection code-signing requirement disabled")
}

// The same requirement guards the app connections to each data root's broker endpoint.
let orchestration = OrchestrationHub(manager: manager, configuration: OrchestrationHub.Configuration(connectionRequirement: requirement))
manager.setObserver(orchestration)
let server = PTYHostServer(manager: manager, build: hostBuild(), orchestration: orchestration)

listener.delegate = server
listener.resume()
manager.start()
logger.info("PTY host \(hostBuild(), privacy: .public) listening on \(PTYHostConstants.machServiceName, privacy: .public)")
dispatchMain()
