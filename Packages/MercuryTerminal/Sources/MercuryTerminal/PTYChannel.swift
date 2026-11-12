internal import CMercuryTerminalPTY
import Darwin
import Dispatch
import Foundation
import Synchronization

/// One child process under a pseudo-terminal: the master descriptor, its read, write and exit sources, and the
/// output hand-off to the main actor.
///
/// Thread confinement (why `@unchecked Sendable` is sound): every stored `var` outside `shared` is read and written
/// only on `queue`. `shared` is the only state touched from both `queue` and the main actor, and it is a `Mutex`.
/// `pid`, `ttyDevice` and `queue` are immutable.
final class PTYChannel: @unchecked Sendable {
    typealias OutputSink = @MainActor @Sendable (ArraySlice<UInt8>) -> Void
    typealias ExitSink = @MainActor @Sendable (Int32?) -> Void

    let pid: pid_t
    /// Device number of the PTY's slave side: every process whose controlling terminal it is belongs to this session.
    let ttyDevice: dev_t?

    private let queue: DispatchQueue
    private var fd: Int32
    /// The parent's slave descriptor, held until the master closes (see `mercury_terminal_spawn`).
    private var slaveFD: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var processSource: DispatchSourceProcess?
    private var writeBuffer: [UInt8] = []
    private var writeOffset = 0
    private var readSuspended = false
    private var readEnded = false
    private var processExited = false
    /// While set, the master stays open after the child exits, so the PTY (and its device number) cannot be reused
    /// before `terminate` has swept the processes still attached to it.
    private var holdOpen = false

    private struct Shared {
        var pending: [UInt8] = []
        var flushScheduled = false
        var readPaused = false
        /// Delivered to the main actor but not yet reported consumed (only counted while `countsConsumption`).
        var unconsumed = 0
        var countsConsumption = false
        var exitStatus: Int32?
        var exitReported = false
        var exitDelivered = false
        var output: OutputSink?
        var exit: ExitSink?

        /// Output not yet fed to the emulator: waiting for the main actor, plus delivered but unconsumed.
        var backlog: Int { pending.count + unconsumed }
    }

    private let shared = Mutex(Shared())


    /// Reads stop while more than this many bytes wait for the main actor, so a flood cannot grow memory without
    /// bound; the child then blocks in `write`, as under any terminal.
    static let highWaterMark = 4 * 1024 * 1024
    static let lowWaterMark = 1 * 1024 * 1024
    /// At most this much output per main-actor turn, so a flood never keeps the main thread from drawing.
    static let maxBytesPerDelivery = 1024 * 1024
    private static let readChunk = 64 * 1024

    private init(pid: pid_t, fd: Int32, slaveFD: Int32, ttyDevice: dev_t?) {
        self.pid = pid
        self.fd = fd
        self.slaveFD = slaveFD
        self.ttyDevice = ttyDevice
        queue = DispatchQueue(label: "mercury.terminal.pty.\(pid)", qos: .userInteractive)
    }

    // MARK: Spawning

    /// Starts `launch.executable` under a new PTY through `mercury_terminal_spawn` (C): the child is a session leader
    /// with the PTY as its controlling terminal, default signal dispositions, an empty signal mask and no descriptors
    /// besides 0, 1 and 2. Exec failures are reported as errors instead of an exit code 127.
    static func spawn(_ launch: TerminalLaunch, size: TerminalSize) throws -> PTYChannel {
        guard FileManager.default.isExecutableFile(atPath: launch.executable) else {
            throw TerminalEngineError.executableNotFound(launch.executable)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: launch.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TerminalEngineError.invalidWorkingDirectory(launch.cwd)
        }

        let argv = CStringArray([launch.executable] + launch.arguments)
        let envp = CStringArray(launch.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        defer {
            argv.free()
            envp.free()
        }
        guard argv.isComplete, envp.isComplete else { throw TerminalEngineError.spawnFailed(ENOMEM) }
        let size = size.clamped
        var pid: pid_t = 0
        var master: Int32 = -1
        var slave: Int32 = -1
        var stage: Int32 = 0
        let error = mercury_terminal_spawn(launch.executable, argv.pointer, envp.pointer, launch.cwd,
                                           UInt16(clamping: size.rows), UInt16(clamping: size.cols),
                                           &pid, &master, &slave, &stage)
        guard error == 0 else {
            if stage == Int32(MERCURY_TERMINAL_STAGE_CHDIR) { throw TerminalEngineError.invalidWorkingDirectory(launch.cwd) }
            throw TerminalEngineError.spawnFailed(error)
        }
        return PTYChannel(pid: pid, fd: master, slaveFD: slave, ttyDevice: slaveDevice(of: slave))
    }

    private static func slaveDevice(of slave: Int32) -> dev_t? {
        var info = stat()
        guard fstat(slave, &info) == 0 else { return nil }
        return info.st_rdev
    }

    // MARK: Running

    /// Starts reading and watching for exit. Output and the exit status go to the sinks on the main actor.
    func activate(output: @escaping OutputSink, exit: @escaping ExitSink) {
        shared.withLock {
            $0.output = output
            $0.exit = exit
        }
        queue.async { [self] in
            let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            read.setEventHandler { [self] in readAvailable() }
            readSource = read
            read.activate()

            let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            process.setEventHandler { [self] in childExited() }
            processSource = process
            process.activate()
            // The child may have exited before the source was armed; the source then never fires.
            reapIfExited()
        }
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            guard fd >= 0, !processExited else { return }
            writeBuffer.append(contentsOf: bytes)
            flushWrites()
        }
    }

    func resize(_ size: TerminalSize) {
        let size = size.clamped
        queue.async { [self] in
            guard fd >= 0 else { return }
            var window = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(fd, TIOCSWINSZ, &window)
        }
    }

    /// Starts a termination: keeps the master open past the child's exit (see `holdOpen`) until
    /// `endTermination()`. Returns `false` when the PTY is already closed: the child was reaped, and neither its PID
    /// nor the PTY's device number may be used for signals any more, since both can now name someone else's process.
    func beginTermination() -> Bool {
        queue.sync {
            guard fd >= 0 else { return false }
            holdOpen = true
            return true
        }
    }

    func endTermination() {
        queue.sync {
            holdOpen = false
            closeIfFinished()
        }
    }

    /// Whether the child has been reaped.
    var hasExited: Bool { shared.withLock { $0.exitReported } }

    // MARK: Signals
    //
    // Signals are sent on `queue`, where the child is reaped, so the child's PID is still a zombie (and cannot be
    // reused) whenever `processExited` is false. Processes found through the PTY's device number are only looked up
    // while the master is open, so the device still belongs to this session.

    /// Sends `signal` to the child's process group and to the group of every process attached to the PTY, then
    /// SIGCONT so stopped jobs act on it.
    func signalSession(_ signal: Int32) {
        queue.sync {
            var groups = Set(attachedProcesses().map { getpgid($0) }.filter { $0 > 0 })
            if !processExited { groups.insert(pid) }
            for group in groups {
                killpg(group, signal)
                if signal != SIGKILL { killpg(group, SIGCONT) }
            }
            if !processExited { kill(pid, signal) }
        }
    }

    /// SIGKILL to every process still attached to the PTY, wherever its process group is, and to the child and its
    /// group while it is not reaped.
    func killSessionMembers() {
        queue.sync {
            let me = getpid()
            for member in attachedProcesses() where member != me { kill(member, SIGKILL) }
            if !processExited {
                killpg(pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
    }

    /// Processes whose controlling terminal is this PTY (the shell, its jobs, and `nohup`ed or disowned children
    /// that never called `setsid`). Empty once the master is closed.
    func sessionMembers() -> [pid_t] {
        queue.sync { attachedProcesses() }
    }

    private func attachedProcesses() -> [pid_t] {
        guard fd >= 0, let ttyDevice else { return [] }
        let device = UInt32(bitPattern: ttyDevice)
        let bytes = proc_listpids(UInt32(PROC_TTY_ONLY), device, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 16)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_TTY_ONLY), device, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    // MARK: Queue-confined I/O

    private func readAvailable() {
        guard fd >= 0, !readEnded else { return }
        var buffer = [UInt8](repeating: 0, count: Self.readChunk)
        var collected: [UInt8] = []
        while collected.count < Self.highWaterMark {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { break }
            // EOF or EIO: the PTY was revoked (the parent's own slave descriptor keeps it open otherwise).
            endReading()
            break
        }
        if !collected.isEmpty { enqueue(collected) }
    }

    private func endReading() {
        guard !readEnded else { return }
        readEnded = true
        if readSuspended {
            readSuspended = false
            readSource?.resume()
        }
        readSource?.cancel()
        readSource = nil
        closeIfFinished()
    }

    private func flushWrites() {
        while writeOffset < writeBuffer.count {
            let count = writeBuffer.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress! + writeOffset, buffer.count - writeOffset)
            }
            if count > 0 {
                writeOffset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN {
                armWriteSource()
                return
            }
            // The PTY went away; nothing more can be delivered.
            writeBuffer.removeAll()
            writeOffset = 0
            disarmWriteSource()
            return
        }
        writeBuffer.removeAll(keepingCapacity: true)
        writeOffset = 0
        disarmWriteSource()
    }

    private func armWriteSource() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in flushWrites() }
        writeSource = source
        source.activate()
    }

    private func disarmWriteSource() {
        writeSource?.cancel()
        writeSource = nil
    }

    private func reapIfExited() {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { finishExit(status: Self.exitCode(fromWaitStatus: status)) }
        else if result < 0, errno == ECHILD { finishExit(status: nil) }
    }

    /// The exit event arrives when the child starts exiting, which can be before it can be reaped: closing its
    /// terminal waits for queued output to be read. Waiting in `waitpid` here would block the reads on this queue and
    /// deadlock with the dying child, so the reap is polled while reading goes on.
    private func childExited() {
        guard !processExited else { return }
        reapIfExited()
        guard !processExited else { return }
        readAvailable()
        queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [self] in childExited() }
    }

    private func finishExit(status: Int32?) {
        guard !processExited else { return }
        processExited = true
        processSource?.cancel()
        processSource = nil
        // What the child wrote just before exiting is still in the PTY; deliver it before the exit.
        if !readEnded { drainRemaining() }
        disarmWriteSource()
        writeBuffer.removeAll()
        let schedule = shared.withLock { state -> Bool in
            state.exitStatus = status
            state.exitReported = true
            guard !state.flushScheduled else { return false }
            state.flushScheduled = true
            return true
        }
        if schedule { scheduleDelivery() }
        closeIfFinished()
    }

    /// Reads what is left without waiting, ignoring backpressure: the child is gone, so the amount is bounded by
    /// the PTY buffer.
    private func drainRemaining() {
        var buffer = [UInt8](repeating: 0, count: Self.readChunk)
        var collected: [UInt8] = []
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        if !collected.isEmpty { enqueue(collected, ignoringBackpressure: true) }
    }

    /// Closes the master once the child is reaped and nobody asked to keep it.
    private func closeIfFinished() {
        guard processExited, !holdOpen, fd >= 0 else { return }
        if readSource != nil {
            if readSuspended {
                readSuspended = false
                readSource?.resume()
            }
            readSource?.cancel()
            readSource = nil
        }
        readEnded = true
        disarmWriteSource()
        close(fd)
        fd = -1
        close(slaveFD)
        slaveFD = -1
    }

    // MARK: Hand-off to the main actor

    private func enqueue(_ bytes: [UInt8], ignoringBackpressure: Bool = false) {
        let (schedule, pause) = shared.withLock { state -> (Bool, Bool) in
            state.pending.append(contentsOf: bytes)
            var pause = false
            if !ignoringBackpressure, state.backlog > Self.highWaterMark, !state.readPaused {
                state.readPaused = true
                pause = true
            }
            guard !state.flushScheduled else { return (false, pause) }
            state.flushScheduled = true
            return (true, pause)
        }
        if pause, !readSuspended, let readSource {
            readSuspended = true
            readSource.suspend()
        }
        if schedule { scheduleDelivery() }
    }

    private func scheduleDelivery() {
        // DispatchQueue.main keeps deliveries in FIFO order, which separate main-actor Tasks do not promise.
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { deliver() }
        }
    }

    /// From now on, output counts as backlog until `consumed(_:)` reports it fed, so a consumer that feeds the
    /// emulator in slices (TerminalSession) holds the PTY reader back instead of buffering without bound.
    func countConsumption() {
        shared.withLock { $0.countsConsumption = true }
    }

    func consumed(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        let resume = shared.withLock { state -> Bool in
            guard state.countsConsumption else { return false }
            state.unconsumed = max(0, state.unconsumed - byteCount)
            guard state.readPaused, state.backlog < Self.lowWaterMark else { return false }
            state.readPaused = false
            return true
        }
        if resume { resumeReading() }
    }

    private func resumeReading() {
        queue.async { [self] in
            guard readSuspended, let readSource else { return }
            readSuspended = false
            readSource.resume()
        }
    }

    @MainActor
    private func deliver() {
        let (batch, output, exitSink, exitStatus, more, resume) = shared.withLock { state in
            let count = min(state.pending.count, Self.maxBytesPerDelivery)
            let batch = Array(state.pending.prefix(count))
            state.pending.removeFirst(count)
            if state.countsConsumption { state.unconsumed += count }
            var resume = false
            if state.readPaused, state.backlog < Self.lowWaterMark {
                state.readPaused = false
                resume = true
            }
            let more = !state.pending.isEmpty
            let output = state.output
            var exitSink: ExitSink?
            if !more, state.exitReported, !state.exitDelivered {
                state.exitDelivered = true
                exitSink = state.exit
                state.output = nil
                state.exit = nil
            }
            state.flushScheduled = more
            return (batch, output, exitSink, state.exitStatus, more, resume)
        }
        if resume { resumeReading() }
        if !batch.isEmpty { output?(batch[...]) }
        if more { scheduleDelivery() }
        exitSink?(exitStatus)
    }

    // MARK: Helpers

    /// Shell convention: a normal exit reports its code, death by a signal reports 128 + the signal number.
    static func exitCode(fromWaitStatus status: Int32) -> Int32? {
        let signal = status & 0x7F
        if signal == 0 { return (status >> 8) & 0xFF }
        if signal != 0x7F { return 128 + signal }
        return nil
    }
}

/// A NULL-terminated `char *[]` built before a fork.
private struct CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int
    /// `false` when a copy failed (out of memory); the array must not be passed to exec then.
    let isComplete: Bool

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        var complete = true
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
            if pointer[index] == nil { complete = false }
        }
        pointer[strings.count] = nil
        isComplete = complete
    }

    func free() {
        for index in 0..<count { Darwin.free(pointer[index]) }
        pointer.deallocate()
    }
}
