import AppKit
import Foundation
import SuijinCore
import Testing
@testable import Suijin

/// Ten hosted terminals flooding output at once, all on screen: the main thread must keep serving the UI.
/// Prints the measurements; the thresholds are generous so the test catches freezes, not noise.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct LoadTests {
    @Test func tenFloodingTerminalsKeepTheMainThreadResponsive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-load-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        await model.runtimes.bootstrap()
        #expect(model.runtimes.hostProblem == nil)

        // All ten terminal views visible in one window, as in a 5×2 grid of splits.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.distribution = .fillEqually
        window.contentView = grid
        var ids: [UUID] = []
        var row: NSStackView?
        for index in 0..<10 {
            let id = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
            ids.append(id)
            if index % 5 == 0 {
                row = NSStackView()
                row?.distribution = .fillEqually
                grid.addArrangedSubview(row!)
            }
            row?.addArrangedSubview(try #require(model.runtimes.runtime(for: id)).terminal.view)
        }
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let usageBefore = Self.cpuSeconds()
        let start = ContinuousClock.now
        for id in ids {
            model.runtimes.runtime(for: id)?.terminal.send("yes 'Suijin load test line with some width to it' | head -n 400000; echo LOAD_DONE_$((7*6))\n")
        }
        // Measure the longest gap between main-thread ticks scheduled every 10 ms while the output streams in.
        var worstGap: Duration = .zero
        var last = ContinuousClock.now
        func allDone() -> Bool {
            ids.allSatisfy { model.runtimes.runtime(for: $0)?.terminal.view.visibleText().contains("LOAD_DONE_42") == true }
        }
        while !allDone(), ContinuousClock.now - start < .seconds(150) {
            try await Task.sleep(for: .milliseconds(10))
            let now = ContinuousClock.now
            worstGap = max(worstGap, now - last)
            last = now
        }
        let elapsed = ContinuousClock.now - start
        let cpu = Self.cpuSeconds() - usageBefore
        print("LOAD: 10×400k lines in \(elapsed), app CPU \(String(format: "%.1f", cpu)) s, worst main-thread gap \(worstGap), footprint \(ProcessMemory.formattedFootprint())")
        #expect(allDone())
        #expect(worstGap < .milliseconds(250), "the main thread stalled for \(worstGap)")
        for id in ids { await model.closeSession(id) }
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
