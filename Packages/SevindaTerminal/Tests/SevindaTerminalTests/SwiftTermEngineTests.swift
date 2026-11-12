import Darwin
import Foundation
import Testing
@testable import SevindaTerminal

/// Collects what an engine delivers.
@MainActor
final class EngineRecorder {
    var output: [UInt8] = []
    var exits: [Int32?] = []
    var text: String { String(decoding: output, as: UTF8.self) }

    func attach(to engine: any TerminalEngine) {
        engine.onOutput = { [weak self] bytes in self?.output.append(contentsOf: bytes) }
        engine.onExit = { [weak self] code in self?.exits.append(code) }
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

/// Children of `pid`, from `pgrep -P`.
func children(of pid: pid_t) -> [pid_t] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-P", String(pid)]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
}

func launch(_ executable: String, _ arguments: [String] = []) -> TerminalLaunch {
    TerminalLaunch(executable: executable, arguments: arguments,
                   environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"],
                   cwd: NSTemporaryDirectory())
}

@Suite("SwiftTermEngine", .serialized)
@MainActor
struct SwiftTermEngineTests {
    let size = TerminalSize(cols: 80, rows: 24)

    @Test("runs /bin/echo and reports its output, then exit 0")
    func echo() async throws {
        let engine = SwiftTermEngine()
        let recorder = EngineRecorder()
        recorder.attach(to: engine)
        try await engine.start(launch("/bin/echo", ["hello mercury"]), size: size)
        #expect(engine.processID != nil)
        #expect(engine.sessionID == nil)
        #expect(await waitUntil { !recorder.exits.isEmpty })
        #expect(recorder.text.contains("hello mercury"))
        #expect(recorder.exits == [0])
        #expect(engine.exitCode == 0)
    }

    @Test("reports exit codes and deaths by signal")
    func exitCodes() async throws {
        let failing = SwiftTermEngine()
        let failed = EngineRecorder()
        failed.attach(to: failing)
        try await failing.start(launch("/bin/sh", ["-c", "exit 3"]), size: size)
        #expect(await waitUntil { !failed.exits.isEmpty })
        #expect(failed.exits == [3])

        let killed = SwiftTermEngine()
        let recorder = EngineRecorder()
        recorder.attach(to: killed)
        try await killed.start(launch("/bin/sh", ["-c", "kill -TERM $$"]), size: size)
        #expect(await waitUntil { !recorder.exits.isEmpty })
        #expect(recorder.exits == [128 + SIGTERM])

        #expect(PTYChannel.exitCode(fromWaitStatus: 0x0100) == 1)
        #expect(PTYChannel.exitCode(fromWaitStatus: SIGKILL) == 128 + SIGKILL)
        #expect(PTYChannel.exitCode(fromWaitStatus: 0x137F) == nil)
    }

    @Test("start validates the executable, the directory and double starts")
    func startValidation() async throws {
        let engine = SwiftTermEngine()
        await #expect(throws: TerminalEngineError.executableNotFound("/no/such/binary")) {
            try await engine.start(launch("/no/such/binary"), size: size)
        }
        var bad = launch("/bin/echo")
        bad.cwd = "/no/such/directory"
        await #expect(throws: TerminalEngineError.invalidWorkingDirectory("/no/such/directory")) {
            try await engine.start(bad, size: size)
        }
        // Not a valid executable format: exec fails in the child and the failure comes back as an error.
        let script = FileManager.default.temporaryDirectory.appending(path: "mercury-noexec-\(UUID())")
        try Data("no shebang\0\u{1}".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        await #expect(throws: TerminalEngineError.spawnFailed(ENOEXEC)) {
            try await engine.start(launch(script.path), size: size)
        }
        try await engine.start(launch("/bin/echo"), size: size)
        await #expect(throws: TerminalEngineError.alreadyStarted) {
            try await engine.start(launch("/bin/echo"), size: size)
        }
    }

    @Test("write reaches the program; the child runs in the requested directory with the given environment")
    func writeAndEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mercury engine")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The shell reports the physical path (/private/var/…); Foundation's symlink resolution keeps /var.
        let physical = try #require(realpath(directory.path, nil))
        defer { free(physical) }
        let physicalPath = String(cString: physical)
        var spec = launch("/bin/sh", ["-c", #"printf 'pwd=%s\nvar=%s\n' "$PWD" "$MERCURY_TEST"; read line; printf 'got=%s\n' "$line""#])
        spec.cwd = directory.path
        spec.environment["MERCURY_TEST"] = "xin chào"
        let engine = SwiftTermEngine()
        let recorder = EngineRecorder()
        recorder.attach(to: engine)
        try await engine.start(spec, size: size)
        #expect(await waitUntil { recorder.text.contains("var=") })
        engine.write(Array("typed input\r".utf8)[...])
        #expect(await waitUntil { !recorder.exits.isEmpty })
        #expect(recorder.text.contains("pwd=\(physicalPath)\r\n"), "\(recorder.text.debugDescription)")
        #expect(recorder.text.contains("var=xin chào"))
        #expect(recorder.text.contains("got=typed input"))
    }

    @Test("resize reaches the PTY")
    func resize() async throws {
        let engine = SwiftTermEngine()
        let recorder = EngineRecorder()
        recorder.attach(to: engine)
        try await engine.start(launch("/bin/sh", ["-c", "read go; stty size"]), size: size)
        engine.resize(TerminalSize(cols: 132, rows: 43))
        engine.write(Array("\r".utf8)[...])
        #expect(await waitUntil { !recorder.exits.isEmpty })
        #expect(recorder.text.contains("43 132"))
    }

    @Test("a flood is delivered completely, before the exit")
    func flood() async throws {
        let engine = SwiftTermEngine()
        let recorder = EngineRecorder()
        var outputAtExit = -1
        engine.onOutput = { bytes in recorder.output.append(contentsOf: bytes) }
        engine.onExit = { code in
            outputAtExit = recorder.output.count
            recorder.exits.append(code)
        }
        try await engine.start(launch("/bin/sh", ["-c", "yes | head -n 300000; echo END"]), size: size)
        #expect(await waitUntil(timeout: .seconds(30)) { !recorder.exits.isEmpty })
        #expect(recorder.exits == [0])
        // "y\r\n" per line through the PTY's onlcr, then "END\r\n". Under load the macOS tty can emit "y\r\r\n" (a
        // write blocked halfway through the onlcr conversion repeats the "\r"), so lines are counted, not bytes.
        #expect(recorder.output.count { $0 == UInt8(ascii: "y") } == 300_000)
        #expect(recorder.output.count { $0 == UInt8(ascii: "\n") } == 300_001)
        #expect(outputAtExit == recorder.output.count)
        #expect(recorder.text.hasSuffix("END\r\n"))
    }

    @Test("terminate hangs up the process group and leaves no child")
    func terminateLeavesNoChild() async throws {
        let engine = SwiftTermEngine(terminationGracePeriod: .seconds(2))
        let recorder = EngineRecorder()
        recorder.attach(to: engine)
        // `; :` keeps sh from exec-ing sleep, so sleep is a real child of the shell.
        try await engine.start(launch("/bin/sh", ["-c", "sleep 100; :"]), size: size)
        let shell = try #require(engine.processID)
        #expect(await waitUntil { !children(of: shell).isEmpty })
        let sleepers = children(of: shell)

        let clock = ContinuousClock()
        let elapsed = await clock.measure { await engine.terminate() }
        #expect(recorder.exits == [128 + SIGHUP])
        #expect(!isAlive(shell))
        for pid in sleepers { #expect(!isAlive(pid), "sleep \(pid) survived") }
        // SIGHUP was enough; no wait for the grace period.
        #expect(elapsed < .seconds(1.5))
    }

    @Test("terminate kills jobs that ignore SIGHUP after the grace period")
    func terminateKillsNohupJobs() async throws {
        let engine = SwiftTermEngine(terminationGracePeriod: .milliseconds(300))
        let recorder = EngineRecorder()
        recorder.attach(to: engine)
        try await engine.start(launch("/bin/sh", ["-c", "trap '' HUP; nohup sleep 100 >/dev/null 2>&1 & echo job=$!; wait"]), size: size)
        // Bytes, not Characters: "\r\n" is one Character, so `String.contains("\n")` never matches it.
        #expect(await waitUntil { recorder.text.contains("job=") && recorder.output.contains(UInt8(ascii: "\n")) })
        let line = try #require(recorder.text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("job=") })
        let job = try #require(pid_t(line.dropFirst(4).trimmingCharacters(in: .whitespaces)))
        #expect(isAlive(job))

        await engine.terminate()
        #expect(recorder.exits.count == 1)
        #expect(!isAlive(try #require(engine.processID)))
        #expect(await waitUntil(timeout: .seconds(2)) { !isAlive(job) }, "nohup job \(job) survived")
    }

    @Test("terminate after exit and a second terminate are no-ops")
    func terminateIdempotent() async throws {
        let engine = SwiftTermEngine()
        let recorder = EngineRecorder()
        recorder.attach(to: engine)
        try await engine.start(launch("/bin/echo", ["x"]), size: size)
        #expect(await waitUntil { !recorder.exits.isEmpty })
        await engine.terminate()
        await engine.terminate()
        #expect(recorder.exits == [0])
        await SwiftTermEngine().terminate()
    }
}
