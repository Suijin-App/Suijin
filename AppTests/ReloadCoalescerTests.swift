import Foundation
import Testing
@testable import Suijin

/// The Changes tab reloads at most one at a time, and not for changes that cannot alter what it lists.
@MainActor
struct ReloadCoalescerTests {
    /// A reload the test releases by hand, recording how many ran and how many ran at once.
    @MainActor
    private final class Gate {
        var started = 0
        var running = 0
        var mostRunning = 0
        /// Set by the test before each release; what the reload "reads" when it starts.
        var state = 0
        var seen: [Int] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func run() async {
            started += 1
            running += 1
            mostRunning = max(mostRunning, running)
            seen.append(state)
            await withCheckedContinuation { waiters.append($0) }
            running -= 1
        }

        func releaseAll() {
            let current = waiters
            waiters = []
            current.forEach { $0.resume() }
        }

        /// Waits until `count` runs have started.
        func waitUntilStarted(_ count: Int) async {
            for _ in 0..<500 where started < count { try? await Task.sleep(for: .milliseconds(10)) }
        }

        func settle() async {
            for _ in 0..<50 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func aBurstWhileRunningCostsOneMoreRun() async {
        let gate = Gate()
        let coalescer = ReloadCoalescer { await gate.run() }

        coalescer.request()
        await gate.waitUntilStarted(1)
        for _ in 0..<10 { coalescer.request() }
        // Nothing else started beside the run in progress.
        await gate.settle()
        #expect(gate.started == 1)

        gate.releaseAll()
        await gate.waitUntilStarted(2)
        gate.releaseAll()
        await gate.settle()

        #expect(gate.started == 2)
        #expect(gate.mostRunning == 1)
    }

    @Test func theLastRunReadsTheLatestState() async {
        let gate = Gate()
        let coalescer = ReloadCoalescer { await gate.run() }

        gate.state = 1
        coalescer.request()
        await gate.waitUntilStarted(1)
        for value in 2...6 {
            gate.state = value
            coalescer.request()
        }
        gate.releaseAll()
        await gate.waitUntilStarted(2)
        gate.releaseAll()
        await gate.settle()

        #expect(gate.seen == [1, 6])
    }

    @Test func aRequestAfterTheRunFinishedStartsANewOne() async {
        let gate = Gate()
        let coalescer = ReloadCoalescer { await gate.run() }

        coalescer.request()
        await gate.waitUntilStarted(1)
        gate.releaseAll()
        await gate.settle()
        coalescer.request()
        await gate.waitUntilStarted(2)
        gate.releaseAll()
        await gate.settle()

        #expect(gate.started == 2)
    }

    @Test func stoppingDropsThePendingRunAndRefusesNewRequests() async {
        let gate = Gate()
        let coalescer = ReloadCoalescer { await gate.run() }

        coalescer.request()
        await gate.waitUntilStarted(1)
        coalescer.request()
        coalescer.stop()
        gate.releaseAll()
        await gate.settle()
        coalescer.request()
        await gate.settle()

        #expect(gate.started == 1)
    }

    @Test func onlyObjectsAndLogsUnderGitAreIgnored() {
        func matters(folders: Set<String> = [], subtrees: Set<String> = []) -> Bool {
            ReloadCoalescer.matters(FileSystemWatcher.Change(folders: folders, subtrees: subtrees))
        }
        #expect(!matters(folders: [".git/objects"]))
        #expect(!matters(folders: [".git/objects/ab", ".git/objects/pack"]))
        #expect(!matters(folders: [".git/logs", ".git/logs/refs/heads"]))
        #expect(!matters(subtrees: [".git/objects"]))

        // A commit, a checkout or `git add` writes the git directory itself, refs or the index.
        #expect(matters(folders: [".git"]))
        #expect(matters(folders: [".git/refs/heads"]))
        #expect(matters(folders: ["src"]))
        #expect(matters(folders: [""]))
        // Lost events and a replaced root ask for a rescan of everything.
        #expect(matters(subtrees: [""]))
        // One relevant folder among ignored ones is enough.
        #expect(matters(folders: [".git/objects/ab", "src"]))
        // Names that only start like an ignored folder are not ignored.
        #expect(matters(folders: [".git/objectsX"]))
        #expect(matters(folders: [".git/logs-old"]))
        // Nested folders of the work tree with the same names are work files.
        #expect(matters(folders: ["vendor/.git/objects"]))
    }
}
