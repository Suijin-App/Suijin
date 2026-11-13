import CSuijinPTY
import Darwin
import Foundation
import SuijinPTYProtocol

/// Receives the live stream of one attachment. Calls arrive on the session's private queue, in stream order.
/// Implementations must not call back into the session synchronously.
public protocol PTYOutputSink: AnyObject, Sendable {
    /// Hands `output` to the transport. For a flow-controlled attachment the bytes count against its window until
    /// `PTYSession.acknowledge(_:bytes:)` reports them consumed.
    func deliver(output: Data, sessionID: String)
    /// Sent once, after the last output byte, when the process has exited.
    func deliver(exitStatus: Int32, sessionID: String)
}

public struct PTYSpawnError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Batching and flow-control knobs of a session.
public struct PTYSessionTuning: Sendable {
    /// Sustained output is pushed to attachments at most this often.
    public var flushInterval: TimeInterval = 0.008
    /// Flushes allowed back to back before `flushInterval` pacing applies; refills at one per interval. Keeps
    /// interactive echo immediate while bulk output is batched.
    public var burstFlushes = 4
    /// Pending output at or above this size is pushed immediately.
    public var flushThreshold = 64 * 1024
    /// Largest single output message.
    public var maxMessageBytes = 256 * 1024
    /// Unacknowledged bytes a flow-controlled attachment may have outstanding. Once its backlog (sent but not
    /// acknowledged, plus read but not yet sent) reaches this, the session stops reading the PTY until acks bring the
    /// backlog under half of it: the kernel buffer fills and the child blocks, like a real terminal.
    public var attachmentWindowBytes = 2 * 1024 * 1024
    /// Delay between SIGHUP and SIGKILL in `terminate`.
    public var killGrace: TimeInterval = 2
    /// Input held for a child that is not reading; beyond this new input is dropped.
    public var maxPendingInputBytes = 4 * 1024 * 1024

    public init() {}
}

/// One child process on its own pseudo terminal, owned by the PTY host.
///
/// All mutable state is confined to `queue`; the type is `@unchecked Sendable` on that basis. The master is read on a
/// `DispatchSource`, every byte goes into the `ScrollbackBuffer` first, and attachments are fed from the scrollback by
/// absolute offset. That makes the scrollback authoritative: an attachment starts at the snapshot's end offset (no gap,
/// no duplicate), and a slow attachment is simply served later from the ring instead of slowing the read loop.
public final class PTYSession: @unchecked Sendable {
    public let id: String
    public let pid: pid_t
    public let executable: String
    public let cwd: String
    public let startedAt: Date
    public let metadata: [String: String]

    private let queue: DispatchQueue
    private let tuning: PTYSessionTuning
    private let onExit: (@Sendable (PTYSession, Int32) -> Void)?

    // Queue-confined state.
    private var scrollback: ScrollbackBuffer
    private let masterFD: Int32
    private var readSource: DispatchSourceRead?
    private var readPaused = false
    private var processSource: DispatchSourceProcess?
    private var running = true
    private var exitStatus: Int32?
    private var flushedOffset: UInt64 = 0
    private var flushCredits: Double
    private var lastCreditRefill = DispatchTime.now()
    private var flushScheduled = false
    private var attachments: [UUID: Attachment] = [:]
    private var pendingInput = Data()
    private var inputRetryScheduled = false
    private var exitWaiters: [@Sendable (Int32) -> Void] = []
    private var terminateRequested = false
    /// True between terminate's SIGHUP and its SIGKILL sweep; the PTY stays open until then.
    private var sweepInProgress = false
    /// Device number of the slave; only meaningful while the PTY is open (`readSource != nil`).
    private let ttyDevice: dev_t
    private let readBuffer: UnsafeMutableRawPointer
    private static let readBufferSize = 64 * 1024

    /// Queue-confined per-attachment cursor.
    private final class Attachment: @unchecked Sendable {
        let sink: any PTYOutputSink
        var position: UInt64
        let flowControlled: Bool
        /// Sent but not acknowledged (always 0 without flow control).
        var inFlight = 0
        var exitDelivered = false

        init(sink: any PTYOutputSink, position: UInt64, flowControlled: Bool) {
            self.sink = sink
            self.position = position
            self.flowControlled = flowControlled
        }
    }

    /// Starts `request.executable` on a new pseudo terminal. `onExit` runs on the session queue after the final
    /// output has been read into the scrollback and pushed to attachments.
    public static func spawn(
        id: String = UUID().uuidString,
        request: PTYSpawnRequest,
        scrollbackCapacity: Int = ScrollbackBuffer.defaultCapacity,
        tuning: PTYSessionTuning = PTYSessionTuning(),
        onExit: (@Sendable (PTYSession, Int32) -> Void)? = nil
    ) throws -> PTYSession {
        guard !request.executable.isEmpty else { throw PTYSpawnError("Missing executable") }
        let environment = request.environment // complete environment; nothing is inherited from the helper
        guard let path = resolveExecutable(request.executable, environment: environment) else {
            throw PTYSpawnError("Executable not found: \(request.executable)")
        }
        let cols = UInt16(clamping: max(request.cols, 1))
        let rows = UInt16(clamping: max(request.rows, 1))

        let argv = ([request.executable] + request.arguments).map { strdup($0) }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var result = suijin_pty_spawn_result()
        let status: Int32 = (argv + [nil]).withUnsafeBufferPointer { argvBuffer in
            (envp + [nil]).withUnsafeBufferPointer { envpBuffer in
                suijin_pty_spawn(path, argvBuffer.baseAddress, envpBuffer.baseAddress, request.cwd, cols, rows, &result)
            }
        }
        guard status == 0 else {
            throw PTYSpawnError(describeSpawnFailure(stage: result.stage, errorNumber: result.error_number, request: request))
        }

        let session = PTYSession(
            id: id, pid: result.pid, masterFD: result.master_fd, slaveFD: result.slave_fd, request: request,
            scrollbackCapacity: scrollbackCapacity, tuning: tuning, onExit: onExit
        )
        return session
    }

    private init(
        id: String, pid: pid_t, masterFD: Int32, slaveFD: Int32, request: PTYSpawnRequest,
        scrollbackCapacity: Int, tuning: PTYSessionTuning, onExit: (@Sendable (PTYSession, Int32) -> Void)?
    ) {
        self.id = id
        self.pid = pid
        self.executable = request.executable
        self.cwd = request.cwd
        self.startedAt = Date()
        self.metadata = request.metadata
        self.tuning = tuning
        self.flushCredits = Double(tuning.burstFlushes)
        self.onExit = onExit
        self.masterFD = masterFD
        var slaveStat = stat()
        self.ttyDevice = fstat(slaveFD, &slaveStat) == 0 ? slaveStat.st_rdev : -1
        self.scrollback = ScrollbackBuffer(capacity: scrollbackCapacity)
        self.queue = DispatchQueue(label: "com.tekmium.suijin.ptyhost.session.\(id)", qos: .userInteractive)
        self.readBuffer = UnsafeMutableRawPointer.allocate(byteCount: Self.readBufferSize, alignment: 16)

        let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        read.setEventHandler { [weak self] in self?.drainMaster() }
        // The parent keeps the slave open until exit so output written just before the child exits is not lost.
        read.setCancelHandler {
            close(masterFD)
            close(slaveFD)
        }
        readSource = read

        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        process.setEventHandler { [weak self] in self?.reapIfExited() }
        // kqueue registration happens asynchronously after resume(); a child that exits before it is armed may never
        // fire the event. Check at registration, and keep a sparse backoff poll as a safety net (observed under load).
        process.setRegistrationHandler { [weak self] in self?.reapIfExited() }
        processSource = process

        read.resume()
        process.resume()
        scheduleExitPoll(after: 0.01)
    }

    deinit {
        if readPaused { readSource?.resume() } // releasing a suspended source traps
        readSource?.cancel()
        processSource?.cancel()
        readBuffer.deallocate()
    }

    // MARK: Public API (thread-safe; must not be called from a sink callback)

    public var info: PTYSessionInfo {
        queue.sync { makeInfo() }
    }

    public var isRunning: Bool {
        queue.sync { running }
    }

    public func scrollbackSnapshot() -> Data {
        queue.sync { scrollback.snapshot() }
    }

    /// Registers `sink` and calls `onSnapshot` with the current scrollback, atomically with respect to the read
    /// loop: `sink` then receives an empty chunk (the stream-start marker) and every byte after the snapshot. An
    /// exited session delivers its exit right after the marker.
    /// A `flowControlled` attachment must report consumption through `acknowledge(_:bytes:)`.
    @discardableResult
    public func attach(
        _ sink: any PTYOutputSink, flowControlled: Bool = false, onSnapshot: (Data, PTYSessionInfo) -> Void
    ) -> UUID {
        queue.sync {
            let token = UUID()
            let attachment = Attachment(sink: sink, position: scrollback.totalWritten, flowControlled: flowControlled)
            onSnapshot(scrollback.snapshot(), makeInfo())
            sink.deliver(output: Data(), sessionID: id)
            attachments[token] = attachment
            deliverExitIfDue(attachment)
            return token
        }
    }

    public func detach(_ token: UUID) {
        queue.async {
            self.attachments[token] = nil
            self.updateReadPause()
        }
    }

    /// Credits consumed bytes to a flow-controlled attachment (extra credit is clamped, never banked).
    public func acknowledge(_ token: UUID, bytes: Int) {
        guard bytes > 0 else { return }
        queue.async {
            guard let attachment = self.attachments[token], attachment.flowControlled else { return }
            attachment.inFlight = max(attachment.inFlight - bytes, 0)
            self.pump(token, attachment)
            self.updateReadPause()
        }
    }

    /// Bytes read from the PTY so far (the scrollback's absolute end offset).
    public var bytesRead: UInt64 {
        queue.sync { scrollback.totalWritten }
    }

    /// True while a slow flow-controlled attachment has stopped the session from reading the PTY.
    public var isReadPaused: Bool {
        queue.sync { readPaused }
    }

    public var attachmentCount: Int {
        queue.sync { attachments.count }
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            guard self.running else { return }
            guard self.pendingInput.count + data.count <= self.tuning.maxPendingInputBytes else { return }
            self.pendingInput.append(data)
            self.flushInput()
        }
    }

    public func resize(cols: Int, rows: Int) {
        let cols = UInt16(clamping: max(cols, 1))
        let rows = UInt16(clamping: max(rows, 1))
        queue.async {
            guard self.running else { return }
            _ = suijin_pty_set_window_size(self.masterFD, cols, rows)
        }
    }

    /// Ends everything running on this terminal: SIGHUP + SIGCONT to the process group of every terminal member
    /// (background jobs of an interactive shell each have their own group, and `nohup` or `trap '' HUP` jobs ignore
    /// the hangup), then after `killGrace` SIGKILL to each member still alive. The PTY stays open until that sweep.
    /// Processes that left the session on purpose (`setsid`, daemons) are out of reach by design. Also works after
    /// the leader exited on its own while background jobs remain. `completion` runs once the leader has exited.
    public func terminate(completion: (@Sendable (Int32) -> Void)? = nil) {
        queue.async {
            if let completion {
                if !self.running, let status = self.exitStatus { completion(status) } else { self.exitWaiters.append(completion) }
            }
            guard !self.terminateRequested, self.running || !self.terminalMembers().isEmpty else { return }
            self.terminateRequested = true
            self.sweepInProgress = true
            self.signalTerminal(SIGHUP)
            self.signalTerminal(SIGCONT) // a stopped job must run to act on the hangup
            self.queue.asyncAfter(deadline: .now() + self.tuning.killGrace) { self.finishTermination() }
        }
    }

    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            queue.async {
                if !self.running, let status = self.exitStatus {
                    continuation.resume(returning: status)
                } else {
                    self.exitWaiters.append { continuation.resume(returning: $0) }
                }
            }
        }
    }

    // MARK: Queue-confined internals

    private func makeInfo() -> PTYSessionInfo {
        PTYSessionInfo(
            id: id, pid: pid, executable: executable, cwd: cwd, startedAt: startedAt,
            isRunning: running, exitStatus: exitStatus, metadata: metadata
        )
    }

    /// Processes that belong to this terminal: members of the session the leader created with `setsid` (background
    /// jobs keep it even after the leader exits, when the kernel has already dissociated the controlling terminal),
    /// plus anything else whose controlling terminal is this PTY while it is open. A pid whose session id is our
    /// leader's pid is ours: the kernel does not hand out a pid that is still in use as a session id.
    func terminalMembers() -> [pid_t] {
        let me = getpid()
        var members = Set(Self.listPIDs(type: UInt32(PROC_ALL_PIDS), info: 0).filter { getsid($0) == pid })
        if readSource != nil, ttyDevice != -1 {
            members.formUnion(Self.listPIDs(type: UInt32(PROC_TTY_ONLY), info: UInt32(bitPattern: ttyDevice)))
        }
        if !running { members.remove(pid) } // reaped: the number is no longer ours
        members.remove(me)
        return members.sorted()
    }

    private static func listPIDs(type: UInt32, info: UInt32) -> [pid_t] {
        let needed = proc_listpids(type, info, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(type, info, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// Signals the process group of every terminal member, plus the leader while it is not reaped.
    private func signalTerminal(_ signal: Int32) {
        let ownGroup = getpgrp()
        var groups = Set(terminalMembers().map { getpgid($0) }.filter { $0 > 1 && $0 != ownGroup })
        if running { groups.insert(pid) }
        for group in groups { killpg(group, signal) }
        if running { kill(pid, signal) }
    }

    /// SIGKILL by pid to every member still present (each pid was just verified as ours, so it is not a reused pid;
    /// no blind `killpg` on a group that may have emptied), then release the PTY if the leader is already gone.
    private func finishTermination() {
        for member in terminalMembers() { kill(member, SIGKILL) }
        if running { kill(pid, SIGKILL) } // not reaped yet, so the pid is still ours
        sweepInProgress = false
        if !running { closePTY() }
    }

    private func closePTY() {
        if readPaused { // a suspended source never runs its cancel handler
            readPaused = false
            readSource?.resume()
        }
        readSource?.cancel() // closes master and slave
        readSource = nil
    }

    private func drainMaster() {
        guard running else {
            discardStragglerOutput()
            return
        }
        var total = 0
        // Bounded per event so one chatty session cannot monopolize the queue; the source fires again.
        while total < 4 * Self.readBufferSize {
            let count = Darwin.read(masterFD, readBuffer, Self.readBufferSize)
            if count > 0 {
                scrollback.append(UnsafeRawBufferPointer(start: readBuffer, count: count))
                total += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break // EAGAIN (drained), or EOF/EIO
            }
        }
        if total > 0 {
            scheduleFlush()
            updateReadPause()
        }
    }

    /// Backlog of the slowest flow-controlled attachment: sent-but-unacknowledged plus read-but-unsent bytes.
    private func largestBacklog() -> Int {
        let end = scrollback.totalWritten
        return attachments.values.filter(\.flowControlled)
            .map { $0.inFlight + Int(end - min($0.position, end)) }
            .max() ?? 0
    }

    private func updateReadPause() {
        guard running, let readSource else { return }
        let backlog = largestBacklog()
        if !readPaused, backlog >= tuning.attachmentWindowBytes {
            readPaused = true
            readSource.suspend()
        } else if readPaused, backlog <= tuning.attachmentWindowBytes / 2 {
            readPaused = false
            readSource.resume()
        }
    }

    /// Token bucket: up to `burstFlushes` flushes go out immediately (keystroke echo is not delayed), after which
    /// sustained output is pushed at most once per `flushInterval`, or at once when `flushThreshold` bytes pile up.
    private func scheduleFlush() {
        let pending = scrollback.totalWritten - flushedOffset
        guard pending > 0 else { return }
        refillFlushCredits()
        if pending >= UInt64(tuning.flushThreshold) || flushCredits >= 1 {
            flushCredits = max(flushCredits - 1, 0)
            flush()
        } else if !flushScheduled {
            flushScheduled = true
            let wait = tuning.flushInterval * (1 - flushCredits)
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                self.refillFlushCredits()
                self.flushCredits = max(self.flushCredits - 1, 0)
                self.flush()
            }
        }
    }

    private func refillFlushCredits() {
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastCreditRefill.uptimeNanoseconds) / 1_000_000_000
        lastCreditRefill = now
        flushCredits = min(Double(tuning.burstFlushes), flushCredits + elapsed / tuning.flushInterval)
    }

    private func flush() {
        flushedOffset = scrollback.totalWritten
        for (token, attachment) in attachments {
            pump(token, attachment)
        }
    }

    private func pump(_ token: UUID, _ attachment: Attachment) {
        while attachment.inFlight < tuning.attachmentWindowBytes {
            // Only reachable when the window exceeds the ring (or without flow control): a client that fell behind
            // skips what was overwritten; the scrollback stays authoritative.
            if attachment.position < scrollback.startOffset { attachment.position = scrollback.startOffset }
            guard attachment.position < flushedOffset else { break }
            let length = min(
                tuning.maxMessageBytes,
                tuning.attachmentWindowBytes - attachment.inFlight,
                Int(flushedOffset - attachment.position)
            )
            let chunk = scrollback.read(from: attachment.position, maxLength: length)
            guard !chunk.isEmpty else { break }
            attachment.position += UInt64(chunk.count)
            if attachment.flowControlled { attachment.inFlight += chunk.count }
            attachment.sink.deliver(output: chunk, sessionID: id)
        }
        deliverExitIfDue(attachment)
    }

    private func deliverExitIfDue(_ attachment: Attachment) {
        guard !running, let status = exitStatus, !attachment.exitDelivered,
              attachment.position >= scrollback.totalWritten else { return }
        attachment.exitDelivered = true
        attachment.sink.deliver(exitStatus: status, sessionID: id)
    }

    private func flushInput() {
        while running, !pendingInput.isEmpty {
            let written = pendingInput.withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
            if written > 0 {
                pendingInput.removeFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                // The child is not reading; retry shortly rather than holding a write source on the shared fd.
                if !inputRetryScheduled {
                    inputRetryScheduled = true
                    queue.asyncAfter(deadline: .now() + 0.005) { [weak self] in
                        guard let self else { return }
                        self.inputRetryScheduled = false
                        self.flushInput()
                    }
                }
                return
            } else {
                pendingInput.removeAll()
                return
            }
        }
    }

    private func scheduleExitPoll(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay, qos: .utility) { [weak self] in
            guard let self, self.running else { return }
            self.reapIfExited()
            if self.running { self.scheduleExitPoll(after: min(delay * 5, 5)) }
        }
    }

    private func reapIfExited() {
        guard running else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, WNOHANG)
        } while result < 0 && errno == EINTR
        if result == 0 { return } // still running
        // result < 0 (ECHILD) means someone else reaped it; the status is unknown.
        finish(exitCode: result == pid ? suijin_pty_exit_code(status) : -1)
    }

    /// After the leader's exit the stream is over for attachments; bytes written during the terminate sweep are read
    /// and dropped so a writer cannot block on a full PTY.
    private func discardStragglerOutput() {
        guard readSource != nil else { return }
        while Darwin.read(masterFD, readBuffer, Self.readBufferSize) > 0 {}
    }

    private func finish(exitCode: Int32) {
        drainMaster()
        running = false
        exitStatus = exitCode
        pendingInput.removeAll()
        processSource?.cancel()
        processSource = nil
        // A pending terminate sweep releases the PTY itself; background jobs left behind by a natural exit are
        // still found by session id when the tab is closed later.
        if !sweepInProgress { closePTY() }
        flush()
        let waiters = exitWaiters
        exitWaiters.removeAll()
        waiters.forEach { $0(exitCode) }
        onExit?(self, exitCode)
    }

    // MARK: Spawn helpers

    static func resolveExecutable(_ name: String, environment: [String: String]) -> String? {
        if name.contains("/") {
            return access(name, X_OK) == 0 ? name : nil
        }
        let searchPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(name)"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }

    private static func describeSpawnFailure(stage: Int32, errorNumber: Int32, request: PTYSpawnRequest) -> String {
        let reason = String(cString: strerror(errorNumber))
        switch Int(stage) {
        case Int(SUIJIN_PTY_STAGE_CHDIR): return "Cannot enter directory \(request.cwd): \(reason)"
        case Int(SUIJIN_PTY_STAGE_EXEC): return "Cannot execute \(request.executable): \(reason)"
        case Int(SUIJIN_PTY_STAGE_FORK): return "Cannot fork: \(reason)"
        case Int(SUIJIN_PTY_STAGE_SETSID): return "Cannot set up the controlling terminal: \(reason)"
        default: return "Cannot open a pseudo terminal: \(reason)"
        }
    }
}
