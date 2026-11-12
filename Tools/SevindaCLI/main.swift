// mercury — the orchestration command agents run inside Mercury's terminals.
//
// Ships in Mercury.app/Contents/Helpers/mercury; Mercury puts that folder on PATH (and the full path in $MERCURY_CLI)
// only for the terminals it opens. The logic lives in SevindaCLIKit (Packages/SevindaPTYProtocol) so it is tested
// there; this file only finds the app bundle and runs it.

import Foundation
import SevindaCLIKit

// A reader that went away (a closed pipe) must not crash the command with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
    ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
// Contents/Helpers/mercury -> Contents
let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
let appInfo = Bundle(url: contents.deletingLastPathComponent())?.infoDictionary ?? [:]
let version = (appInfo["CFBundleShortVersionString"] as? String).map { "\($0) (\(appInfo["CFBundleVersion"] as? String ?? "?"))" } ?? "dev"

let cli = SevindaCLI(
    environment: ProcessInfo.processInfo.environment,
    skillsDirectory: contents.appendingPathComponent("Resources/Skills", isDirectory: true),
    version: version
)
let result = cli.run(Array(CommandLine.arguments.dropFirst()))
if !result.stdout.isEmpty { FileHandle.standardOutput.write(Data(result.stdout.utf8)) }
if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
exit(result.exitCode)
