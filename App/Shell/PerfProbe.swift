#if DEBUG || SUIJIN_PERF
import AppKit
import Foundation
import os
import QuartzCore

/// Scripted UI responsiveness measurement, for development builds only (`DEBUG`, or a build with the `SUIJIN_PERF`
/// compilation condition). Launch the app on a seeded data root (`PerfSeedTests`) with `SUIJIN_PERF_OUT=<file>`: after
/// launch it switches tabs, opens and closes file and shell tabs, shows and hides the inspector and switches contexts,
/// measures the main thread after each action, writes one JSON object per sample to the file and quits.
///
/// Per action: `commitMs` is the run-loop turn that performed it (SwiftUI update, layout and Core Animation commit run
/// before the run loop sleeps again), `busyMs` the main thread's awake time in the `settle` window after it (follow-up
/// turns, animations, tasks), `maxTurnMs` its longest single turn. Each action is a points-of-interest signpost, so an
/// Instruments trace taken meanwhile lines up with the samples.
@MainActor
enum PerfProbe {
    static func startIfRequested(model: AppModel) {
        guard let out = ProcessInfo.processInfo.environment["SUIJIN_PERF_OUT"] else { return }
        Task { @MainActor in
            let run = Run(model: model, output: URL(fileURLWithPath: out))
            await run.execute()
            // Not from inside this main-queue job: `terminate` waits in a nested run loop for the delegate's reply,
            // which needs the main queue, so it is called from a plain run-loop block.
            RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        }
    }

    @MainActor
    private final class Run {
        let model: AppModel
        let output: URL
        let monitor = RunLoopMonitor()
        let signposter = OSSignposter(subsystem: "com.tekmium.suijin", category: .pointsOfInterest)
        var phase = "quiet"
        let rounds = Int(ProcessInfo.processInfo.environment["SUIJIN_PERF_ROUNDS"] ?? "") ?? 8
        let settle: Duration = .milliseconds(700)

        init(model: AppModel, output: URL) {
            self.model = model
            self.output = output
        }

        func execute() async {
            let defaults = UserDefaults.standard
            let savedShown = defaults.object(forKey: "inspector.shown")
            let savedTab = defaults.object(forKey: "inspector.tab")
            defer {
                if let savedShown { defaults.set(savedShown, forKey: "inspector.shown") } else { defaults.removeObject(forKey: "inspector.shown") }
                if let savedTab { defaults.set(savedTab, forKey: "inspector.tab") } else { defaults.removeObject(forKey: "inspector.tab") }
            }
            write(["name": "start", "pid": Int(ProcessInfo.processInfo.processIdentifier)])
            // Wait for the sessions to attach and the window to settle.
            for _ in 0..<60 where model.runtimes.liveCount == 0 { try? await Task.sleep(for: .milliseconds(250)) }
            NSApp.activate()
            defaults.set(false, forKey: "inspector.shown")
            try? await Task.sleep(for: .seconds(4))
            guard let context = busiestContext(), let other = otherContext(than: context),
                  let directory = model.directory(of: context) else {
                write(["error": "no seeded contexts"])
                return
            }
            model.selection = context
            try? await Task.sleep(for: .seconds(1))
            monitor.start()

            await idle("idle")
            await scenario(context: context, other: other, directory: directory)
            // Background churn: a shell in another context renames its tab ten times a second, as an agent's title
            // spinner does.
            let spinner = model.tabSessions(in: other).first.flatMap { model.runtimes.runtime(for: $0.id) }
            spinner?.terminal.send("while :; do for c in ⠂ ⠐ ⠒ ⠲; do printf '\\033]0;%s Working on the task\\007' $c; sleep 0.1; done; done\n")
            phase = "churn"
            try? await Task.sleep(for: .seconds(1))
            await idle("idle")
            await scenario(context: context, other: other, directory: directory, short: true)
            spinner?.terminal.send("\u{03}")
            try? await Task.sleep(for: .milliseconds(300))
            spinner?.terminal.send("clear\n")
            monitor.stop()
            write(["name": "done"])
        }

        private func scenario(context: SessionContext, other: SessionContext, directory: URL, short: Bool = false) async {
            let defaults = UserDefaults.standard
            let ids = model.tabSessions(in: context).map(\.id)
            for index in 0..<(rounds * 2) {
                await measure("tab.switch") { self.model.selectedTab[context] = .session(ids[(index + 1) % ids.count]) }
            }
            for _ in 0..<rounds {
                await measure("inspector.files.show") {
                    defaults.set("files", forKey: "inspector.tab")
                    defaults.set(true, forKey: "inspector.shown")
                }
                await measure("inspector.hide") { defaults.set(false, forKey: "inspector.shown") }
                await measure("inspector.info.show") {
                    defaults.set("info", forKey: "inspector.tab")
                    defaults.set(true, forKey: "inspector.shown")
                }
                await measure("inspector.hide") { defaults.set(false, forKey: "inspector.shown") }
            }
            // With the inspector open, as the user usually works.
            defaults.set("files", forKey: "inspector.tab")
            defaults.set(true, forKey: "inspector.shown")
            try? await Task.sleep(for: .seconds(1))
            for index in 0..<(rounds * 2) {
                await measure("tab.switch.inspector") { self.model.selectedTab[context] = .session(ids[(index + 1) % ids.count]) }
            }
            defaults.set(false, forKey: "inspector.shown")
            try? await Task.sleep(for: .milliseconds(500))
            if short { return }
            let file = directory.appendingPathComponent("README.md").path
            for _ in 0..<rounds {
                await measure("tab.file.open") { self.model.openFile(file, in: context) }
                await measure("tab.file.close") { self.model.closeFile(file, in: context) }
            }
            for _ in 0..<max(3, rounds / 2) {
                var started: UUID?
                await measure("tab.new") {
                    started = await self.model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil)
                }
                if let started { await measure("tab.close") { await self.model.closeSession(started) } }
            }
            self.model.selectedTab[context] = .session(ids[0])
            for _ in 0..<rounds {
                await measure("context.switch") { self.model.selection = other }
                await measure("context.switch") { self.model.selection = context }
            }
        }

        /// Main-thread load with nobody touching the app.
        private func idle(_ name: String) async {
            let start = RunLoopMonitor.now()
            try? await Task.sleep(for: .seconds(5))
            let end = RunLoopMonitor.now()
            let stats = monitor.stats(from: start, to: end)
            write(["name": name, "phase": phase, "busyPct": stats.busy / Double(end - start) * 100,
                   "maxTurnMs": stats.maxTurn / 1e6, "turnsPerSec": Double(stats.turns) / 5])
        }

        private func measure(_ name: String, _ action: @MainActor () async -> Void) async {
            let state = signposter.beginInterval("action", "\(name, privacy: .public)")
            let start = RunLoopMonitor.now()
            await action()
            let acted = RunLoopMonitor.now()
            try? await Task.sleep(for: settle)
            let end = RunLoopMonitor.now()
            signposter.endInterval("action", state)
            let stats = monitor.stats(from: start, to: end)
            let commit = monitor.turnEnd(containing: acted).map { Double($0 - start) / 1e6 } ?? Double(acted - start) / 1e6
            write(["name": name, "phase": phase, "commitMs": commit, "busyMs": stats.busy / 1e6, "maxTurnMs": stats.maxTurn / 1e6,
                   "turns": Double(stats.turns), "actionMs": Double(acted - start) / 1e6])
        }

        private func write(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            // Appended at once, so a run cut short (a trace's time limit) keeps its samples.
            if !FileManager.default.fileExists(atPath: output.path) { FileManager.default.createFile(atPath: output.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: output) else { return }
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }

        private func busiestContext() -> SessionContext? {
            allContexts().max { model.tabSessions(in: $0).count < model.tabSessions(in: $1).count }
        }

        private func otherContext(than context: SessionContext) -> SessionContext? {
            allContexts().filter { $0 != context && !model.tabSessions(in: $0).isEmpty }.first
        }

        private func allContexts() -> [SessionContext] {
            model.workspaces.flatMap { workspace in
                [SessionContext.workspace(workspace.id)] + (model.worktrees[workspace.id] ?? []).map { .worktree($0.id) }
            }
        }
    }
}

/// Records when the main run loop is awake (between waking up and going to sleep again).
@MainActor
private final class RunLoopMonitor {
    private var observer: CFRunLoopObserver?
    private var awakeSince: UInt64?
    /// Awake intervals in nanoseconds of uptime.
    private var turns: [(start: UInt64, end: UInt64)] = []

    nonisolated static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func start() {
        awakeSince = Self.now()
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max
        ) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Self.now()
                if activity == .afterWaiting {
                    self.awakeSince = now
                } else if let since = self.awakeSince {
                    self.turns.append((since, now))
                    self.awakeSince = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    /// The end of the awake interval running at `time`.
    func turnEnd(containing time: UInt64) -> UInt64? {
        turns.first { $0.start <= time && $0.end >= time }?.end
    }

    func stats(from start: UInt64, to end: UInt64) -> (busy: Double, maxTurn: Double, turns: Int) {
        var busy: UInt64 = 0
        var longest: UInt64 = 0
        var count = 0
        for turn in turns where turn.end > start && turn.start < end {
            let length = min(turn.end, end) - max(turn.start, start)
            busy += length
            longest = max(longest, turn.end - turn.start)
            count += 1
        }
        return (Double(busy), Double(longest), count)
    }
}
#endif
