#if DEBUG || SUIJIN_PERF
import AppKit
import Foundation
import SuijinCore

/// Measurement of the Changes tab, for development builds only (`DEBUG`, or a build with the `SUIJIN_PERF`
/// compilation condition). Launch the app with `SUIJIN_PERF_SCENARIO=changes`, `SUIJIN_PERF_OUT=<file>` and
/// `SUIJIN_PERF_REPOS=<path>[:<path>…]`, on its own data root (`SUIJIN_DATA_ROOT`) and its own PTY host service
/// (`SUIJIN_PTYHOST_SERVICE`, so the user's helper and sessions are never reached).
///
/// Each repository is added as a workspace, its worktrees with it. For the workspace and every worktree: the context is
/// selected (`switch`), its Changes tab opened and watched while it loads (`open`), `perf-churn.txt` in the checkout
/// rewritten ten times a second as a dev server or an agent would (`churn`), the tab watched after that stops
/// (`drain`), left (`close`) and opened again (`reopen`). The scenario writes into the checkouts, so point it at copies.
/// `SUIJIN_PERF_LOAD_SECONDS`, `SUIJIN_PERF_CHURN_SECONDS` and `SUIJIN_PERF_DRAIN_SECONDS` set the `open`, `churn` and
/// `drain` phases (10, 20 and 10 seconds by default).
///
/// One JSON object per phase: `busyPct` is the main run loop's awake share, `maxTurnMs` its longest single turn, and
/// `t0`/`t1` the phase's wall-clock bounds, so samples taken outside the app (its child `git` processes, its CPU) line up.
@MainActor
enum PerfChangesProbe {
    static func execute(model: AppModel, output: URL) async {
        let environment = ProcessInfo.processInfo.environment
        let repos = (environment["SUIJIN_PERF_REPOS"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let load = Double(environment["SUIJIN_PERF_LOAD_SECONDS"] ?? "") ?? 10
        let churn = Double(environment["SUIJIN_PERF_CHURN_SECONDS"] ?? "") ?? 20
        let drain = Double(environment["SUIJIN_PERF_DRAIN_SECONDS"] ?? "") ?? 10
        let writer = Writer(output: output)
        writer.write(["name": "start", "pid": Int(ProcessInfo.processInfo.processIdentifier)])
        try? await Task.sleep(for: .seconds(2))
        // A new data root opens the welcome tour, whose animated sprites keep the window laying out every frame and
        // would be measured along with the Changes tab.
        model.onboarding = nil
        NSApp.activate()

        var targets: [(SessionContext, URL)] = []
        for repo in repos {
            await model.addWorkspace(at: repo)
            guard let workspace = model.workspaces.first(where: { $0.path == repo.standardizedFileURL.path }) else {
                writer.write(["error": "not added", "repo": repo.path])
                continue
            }
            targets.append((.workspace(workspace.id), URL(fileURLWithPath: workspace.path)))
            for tree in model.worktrees[workspace.id] ?? [] {
                targets.append((.worktree(tree.id), URL(fileURLWithPath: tree.path)))
            }
        }

        let monitor = RunLoopMonitor()
        monitor.start()
        for (context, directory) in targets {
            let label = directory.lastPathComponent
            // The context first, on its own, so its cost is not counted as the Changes tab's.
            model.selection = context
            await phase("switch", label: label, seconds: 2, monitor: monitor, writer: writer)
            model.selectedTab[context] = .changes
            await phase("open", label: label, seconds: load, monitor: monitor, writer: writer)

            let churnFile = directory.appendingPathComponent("perf-churn.txt")
            let churning = Task { @MainActor in
                var count = 0
                while !Task.isCancelled {
                    count += 1
                    try? "\(count)\n".write(to: churnFile, atomically: true, encoding: .utf8)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            await phase("churn", label: label, seconds: churn, monitor: monitor, writer: writer)
            churning.cancel()
            try? FileManager.default.removeItem(at: churnFile)
            await phase("drain", label: label, seconds: drain, monitor: monitor, writer: writer)

            // Leaving the tab and opening it again: what every later visit costs.
            model.selectedTab[context] = nil
            await phase("close", label: label, seconds: 2, monitor: monitor, writer: writer)
            model.selectedTab[context] = .changes
            await phase("reopen", label: label, seconds: 3, monitor: monitor, writer: writer)
        }
        monitor.stop()
        writer.write(["name": "done"])
    }

    private static func phase(_ name: String, label: String, seconds: Double, monitor: RunLoopMonitor,
                              writer: Writer) async {
        let started = Date().timeIntervalSince1970
        let start = RunLoopMonitor.now()
        try? await Task.sleep(for: .seconds(seconds))
        let end = RunLoopMonitor.now()
        let stats = monitor.stats(from: start, to: end)
        writer.write(["name": name, "target": label, "t0": started, "t1": Date().timeIntervalSince1970,
                      "busyPct": stats.busy / Double(end - start) * 100, "maxTurnMs": stats.maxTurn / 1e6,
                      "turns": stats.turns])
    }

    /// Appends one JSON line per record, at once, so a run cut short keeps its records.
    private final class Writer {
        let output: URL

        init(output: URL) {
            self.output = output
        }

        func write(_ object: [String: Any]) {
            var object = object
            object["t"] = Date().timeIntervalSince1970
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            if !FileManager.default.fileExists(atPath: output.path) { FileManager.default.createFile(atPath: output.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: output) else { return }
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
    }
}
#endif
