import AppKit
import Darwin
import Foundation
import MercuryCore
import SwiftUI
import Testing
@testable import Mercury

/// The Resource Manager: process tree discovery and figures from libproc, the report grouping, and offscreen renders
/// of the popover (when `MERCURY_SCREENSHOTS` names an output folder).
@Suite(.serialized)
struct ResourceManagerTests {
    /// Starts `/bin/sh -c "<script>"` as a child of the test process; the caller ends it with `stop`.
    private func spawnShell(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        return process
    }

    /// Kills the processes this test started (the shell and what it started) and reaps the shell.
    private func stop(_ process: Process, descendants: Set<pid_t>) {
        for pid in descendants where pid != process.processIdentifier { kill(pid, SIGKILL) }
        process.terminate()
        process.waitUntilExit()
    }

    /// Waits until `pid` has at least `count` descendants (the shell needs a moment to fork).
    private func tree(of pid: pid_t, atLeast count: Int) async throws -> Set<pid_t> {
        for _ in 0..<50 {
            let found = ProcessSampler.tree(of: pid, in: try ProcessSampler.processTable())
            if found.count >= count { return found }
            try await Task.sleep(for: .milliseconds(50))
        }
        return ProcessSampler.tree(of: pid, in: try ProcessSampler.processTable())
    }

    @Test func treeFindsChildrenAndGrandchildren() async throws {
        let shell = try spawnShell("/bin/sleep 30 & /bin/sleep 30 & wait")
        let shellPID = shell.processIdentifier
        let shellTree = try await tree(of: shellPID, atLeast: 3)
        defer { stop(shell, descendants: shellTree) }

        #expect(shellTree.count == 3, "the shell and its two sleeps")
        // A background child is forked before it runs `sleep`; wait until both have exec'd, so they carry its name.
        var table = try ProcessSampler.processTable()
        for _ in 0..<40 where shellTree.contains(where: { $0 != shellPID && table[$0]?.name != "sleep" }) {
            try await Task.sleep(for: .milliseconds(50))
            table = try ProcessSampler.processTable()
        }
        #expect(table[shellPID]?.parent == getpid())
        for pid in shellTree where pid != shellPID {
            #expect(table[pid]?.parent == shellPID)
            #expect(table[pid]?.name == "sleep")
        }
        let ownTree = ProcessSampler.tree(of: getpid(), in: table)
        #expect(shellTree.isSubset(of: ownTree), "grandchildren are part of the test process tree")
        #expect(ProcessSampler.tree(of: -42, in: table).isEmpty)
    }

    @Test func usageReportsFootprintAndCPUTime() throws {
        let usage = try #require(ProcessSampler.usage(of: getpid()))
        #expect(usage.memory > 1_000_000, "the test host uses more than a megabyte")
        #expect(usage.cpuNanoseconds > 0)
        // Mach ticks convert to nanoseconds with the timebase (identity on Intel, 125/3 on Apple silicon).
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        #expect(ProcessSampler.nanoseconds(fromMachTicks: 3_000) == 3_000 * UInt64(timebase.numer) / UInt64(timebase.denom))
        #expect(ProcessSampler.usage(of: -42) == nil)
    }

    @Test func sampleSumsTheTreeAndMeasuresCPUBetweenSamples() async throws {
        // A busy child: its CPU between two samples is well above zero.
        let shell = try spawnShell("while :; do :; done")
        let shellTree = try await tree(of: shell.processIdentifier, atLeast: 1)
        defer { stop(shell, descendants: shellTree) }

        let sampler = ProcessSampler()
        let targets: [ResourceKey: ResourceTarget] = [
            .session(UUID()): .tree(shell.processIdentifier),
            .app: .process(getpid()),
            .terminalHost: .terminalHost(sessionPIDs: []),
        ]
        let first = try await sampler.sample(targets)
        let session = try #require(first.first { if case .session = $0.key { true } else { false } }?.value)
        #expect(session.memory > 0)
        #expect(session.cpu == nil, "no CPU figure before a second sample")
        #expect((first[.app]?.memory ?? 0) > 0)

        try await Task.sleep(for: .milliseconds(800))
        let second = try await sampler.sample(targets)
        let busy = try #require(second.first { if case .session = $0.key { true } else { false } }?.value.cpu)
        #expect(busy > 1, "a spinning shell uses CPU, even on a loaded machine")
        #expect(second[.app]?.cpu != nil)

        let gone = try await sampler.sample([.app: .tree(-42)])
        #expect(gone.isEmpty, "a missing process is left out")
    }

    @Test func terminalHostIsTheHelperNamedParent() {
        let table: [pid_t: ProcessEntry] = [
            10: ProcessEntry(parent: 1, uid: getuid(), name: ProcessSampler.terminalHostName),
            20: ProcessEntry(parent: 1, uid: getuid(), name: ProcessSampler.terminalHostName),
            21: ProcessEntry(parent: 20, uid: getuid(), name: "zsh"),
            30: ProcessEntry(parent: 1, uid: getuid() &+ 1, name: ProcessSampler.terminalHostName),
        ]
        #expect(ProcessSampler.terminalHost(sessionPIDs: [21], table: table) == 20)
        #expect(ProcessSampler.terminalHost(sessionPIDs: [], table: table) == 10, "otherwise the user's first helper")
        #expect(ProcessSampler.terminalHost(sessionPIDs: [], table: [30: table[30]!]) == nil, "never another user's")
    }

    @MainActor
    @Test func reportWithoutSessionsHasOnlyMercury() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mercury-resources-\(UUID().uuidString)")
        let model = AppModel(store: try MercuryStore.inMemory(), dataRoot: root)
        let report = ResourceReport.build(model: model, figures: [
            .app: ResourceFigures(memory: 200_000_000, cpu: 3),
            .terminalHost: ResourceFigures(memory: 300_000_000, cpu: 1.5),
        ])
        #expect(report.sessionGroups.isEmpty)
        #expect(report.mercury.rows.map(\.id) == [.terminalHost, .app], "largest memory first")
        #expect(report.memory == 500_000_000)
        #expect(report.cpu == 4.5)
    }

    // MARK: Screenshots

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MERCURY_SCREENSHOTS"] != nil))
    func popoverScreenshots() throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MERCURY_SCREENSHOTS"] ?? NSTemporaryDirectory())
        let api = UUID(), web = UUID()
        func row(_ agent: AgentKind, _ title: String, branch: String? = nil, _ activity: SessionActivityDisplay,
                 memory: UInt64, cpu: Double?) -> ResourceReport.Row {
            ResourceReport.Row(id: .session(UUID()), title: title, subtitle: branch, icon: .agent(agent), activity: activity,
                               figures: ResourceFigures(memory: memory, cpu: cpu), context: .workspace(api))
        }
        let busy = ResourceReport(
            sessionGroups: [
                ResourceReport.Group(id: .workspace(api), title: "mercury-api", rows: [
                    row(.claude, "Refactor the session restore path and keep the scrollback replay fast", branch: "fix-restore",
                        .running, memory: 812_000_000, cpu: 34.2),
                    row(.codex, "Codex", branch: "feature/a-very-long-branch-name-for-layout", .waitingForInput, memory: 245_000_000, cpu: 0.4),
                    row(.shell, "zsh", .running, memory: 6_200_000, cpu: 0),
                ]),
                ResourceReport.Group(id: .workspace(web), title: "A workspace with a rather long name that must truncate", rows: [
                    row(.claude, "Claude", .idle, memory: 402_000_000, cpu: 1.1),
                ]),
            ],
            mercury: ResourceReport.Group(id: .mercury, title: "Mercury", rows: [
                ResourceReport.Row(id: .app, title: "Mercury", icon: .symbol("macwindow"),
                                   figures: ResourceFigures(memory: 286_000_000, cpu: 2.7)),
                ResourceReport.Row(id: .terminalHost, title: "Terminal host", icon: .symbol("server.rack"),
                                   figures: ResourceFigures(memory: 21_000_000, cpu: 0.3)),
            ])
        )
        let history: [ResourceReport.GroupID: [UInt64]] = [
            .workspace(api): (0..<18).map { 1_000_000_000 + UInt64($0 % 5) * 30_000_000 + UInt64($0) * 4_000_000 },
            .workspace(web): (0..<18).map { 380_000_000 + UInt64(($0 * 7) % 4) * 8_000_000 },
            .mercury: (0..<18).map { 300_000_000 + UInt64($0) * 400_000 },
        ]
        let idle = ResourceReport(sessionGroups: [], mercury: busy.mercury)
        let cases: [(String, ResourceReport?, String?)] = [
            ("busy", busy, nil),
            ("empty", idle, "Could not reach the terminal host: The connection was interrupted."),
            ("loading", nil, nil),
        ]
        for (name, report, problem) in cases {
            for dark in [false, true] {
                let view = ResourceManagerView(report: report, history: history, problem: problem, onRefresh: {}, onSelect: { _ in })
                try render(view, to: output.appendingPathComponent("resources-\(name)-\(dark ? "dark" : "light").png"), dark: dark)
            }
        }
    }

    @MainActor
    private func render<V: View>(_ view: V, to url: URL, dark: Bool) throws {
        let host = NSHostingView(rootView: view.fixedSize().background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
