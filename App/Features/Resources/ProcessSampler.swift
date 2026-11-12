import Darwin
import Foundation

/// What the Resource Manager measures: a running session, Mercury itself, or the terminal host helper.
enum ResourceKey: Hashable, Sendable {
    case session(UUID)
    case app
    case terminalHost
}

/// Memory and CPU of one measured target. `cpu` is a percentage of one core (200 means two busy cores) and is `nil`
/// until two samples are far enough apart to compare.
struct ResourceFigures: Equatable, Sendable {
    var memory: UInt64
    var cpu: Double?
}

/// The processes one measurement covers.
enum ResourceTarget: Sendable {
    /// A process and every descendant (a session: its shell and the agent processes under it).
    case tree(pid_t)
    /// One process alone (Mercury itself: its in-process terminals are counted with their sessions).
    case process(pid_t)
    /// The PTY host helper: the parent of the hosted session processes when it carries the helper's name, otherwise
    /// the first process of the current user with that name.
    case terminalHost(sessionPIDs: [pid_t])
}

/// One row of the kernel process table.
struct ProcessEntry: Equatable, Sendable {
    var parent: pid_t
    var uid: uid_t
    /// The short command name (`p_comm`, at most 16 characters).
    var name: String
}

/// Reads memory and CPU of process trees with libproc and `sysctl`: read-only inspection, no signals, no `ps`.
///
/// Memory is the physical footprint (`ri_phys_footprint`, the figure Activity Monitor shows as "Memory"). CPU is the
/// growth of user + system time between two samples divided by the wall time between them, so the first sample has
/// no CPU figure. The actor keeps the previous CPU times, which also keeps every syscall off the main thread.
actor ProcessSampler {
    /// The executable name of the PTY host helper (`Contents/MacOS/SevindaPTYHost`).
    static let terminalHostName = "SevindaPTYHost"

    private var previousCPU: [pid_t: UInt64] = [:]
    private var previousInstant: ContinuousClock.Instant?

    /// Measures every target once. Targets whose processes are gone (or belong to another user) are left out.
    func sample(_ targets: [ResourceKey: ResourceTarget]) throws -> [ResourceKey: ResourceFigures] {
        let table = try Self.processTable()
        let children = Self.childrenIndex(table)
        let now = ContinuousClock.now
        let elapsed = previousInstant.map { Self.seconds(now - $0) }
        var currentCPU: [pid_t: UInt64] = [:]
        var result: [ResourceKey: ResourceFigures] = [:]

        for (key, target) in targets {
            let pids = Self.resolve(target, table: table, children: children)
            guard !pids.isEmpty else { continue }
            var memory: UInt64 = 0
            var cpuDelta: UInt64 = 0
            var measured = false
            for pid in pids {
                guard let usage = Self.usage(of: pid) else { continue }
                measured = true
                memory += usage.memory
                currentCPU[pid] = usage.cpuNanoseconds
                if let before = previousCPU[pid], usage.cpuNanoseconds >= before { cpuDelta += usage.cpuNanoseconds - before }
            }
            guard measured else { continue }
            let cpu = elapsed.flatMap { $0 > 0.05 ? Double(cpuDelta) / ($0 * 1_000_000_000) * 100 : nil }
            result[key] = ResourceFigures(memory: memory, cpu: cpu)
        }
        previousCPU = currentCPU
        previousInstant = now
        return result
    }

    // MARK: Process table

    /// Every process of the system by pid, from `sysctl(KERN_PROC_ALL)`.
    static func processTable() throws -> [pid_t: ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        // The table can grow between the size query and the read: retry with room to spare.
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { throw ProcessSamplerError.processTable(errno) }
            let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            size = capacity * MemoryLayout<kinfo_proc>.stride
            let status = procs.withUnsafeMutableBufferPointer { buffer in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
            }
            if status != 0 {
                if errno == ENOMEM { continue }
                throw ProcessSamplerError.processTable(errno)
            }
            var table: [pid_t: ProcessEntry] = [:]
            for proc in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) where proc.kp_proc.p_pid > 0 {
                table[proc.kp_proc.p_pid] = ProcessEntry(
                    parent: proc.kp_eproc.e_ppid,
                    uid: proc.kp_eproc.e_ucred.cr_uid,
                    name: commandName(proc.kp_proc.p_comm)
                )
            }
            return table
        }
        throw ProcessSamplerError.processTable(ENOMEM)
    }

    /// `pid` and all its descendants that are in `table`; empty when `pid` is not running.
    static func tree(of pid: pid_t, in table: [pid_t: ProcessEntry]) -> Set<pid_t> {
        tree(of: pid, table: table, children: childrenIndex(table))
    }

    private static func tree(of pid: pid_t, table: [pid_t: ProcessEntry], children: [pid_t: [pid_t]]) -> Set<pid_t> {
        guard table[pid] != nil else { return [] }
        var found: Set<pid_t> = [pid]
        var pending = [pid]
        while let next = pending.popLast() {
            for child in children[next] ?? [] where found.insert(child).inserted { pending.append(child) }
        }
        return found
    }

    private static func childrenIndex(_ table: [pid_t: ProcessEntry]) -> [pid_t: [pid_t]] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, entry) in table where entry.parent != pid { children[entry.parent, default: []].append(pid) }
        return children
    }

    private static func resolve(_ target: ResourceTarget, table: [pid_t: ProcessEntry], children: [pid_t: [pid_t]]) -> Set<pid_t> {
        switch target {
        case .tree(let pid):
            return tree(of: pid, table: table, children: children)
        case .process(let pid):
            return table[pid] == nil ? [] : [pid]
        case .terminalHost(let sessionPIDs):
            return terminalHost(sessionPIDs: sessionPIDs, table: table).map { [$0] } ?? []
        }
    }

    /// The PTY host's pid: the helper-named parent of a hosted session, else the lowest-pid helper of this user.
    static func terminalHost(sessionPIDs: [pid_t], table: [pid_t: ProcessEntry]) -> pid_t? {
        for pid in sessionPIDs {
            if let parent = table[pid]?.parent, table[parent]?.name == terminalHostName { return parent }
        }
        let uid = getuid()
        return table.filter { $0.value.uid == uid && $0.value.name == terminalHostName }.keys.min()
    }

    // MARK: Usage

    struct Usage: Equatable, Sendable {
        var memory: UInt64
        var cpuNanoseconds: UInt64
    }

    /// Physical footprint and total CPU time of one process; `nil` when it is gone or not readable (another user).
    static func usage(of pid: pid_t) -> Usage? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        // `ri_user_time` and `ri_system_time` are in Mach absolute time units (not nanoseconds on Apple silicon).
        let ticks = info.ri_user_time &+ info.ri_system_time
        return Usage(memory: info.ri_phys_footprint, cpuNanoseconds: nanoseconds(fromMachTicks: ticks))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? mach_timebase_info_data_t(numer: 1, denom: 1) : info
    }()

    static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64 {
        let (high, low) = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        let denominator = UInt64(timebase.denom)
        guard high < denominator else { return .max }
        return denominator.dividingFullWidth((high, low)).quotient
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func commandName<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

enum ProcessSamplerError: Error, LocalizedError, Equatable {
    /// `sysctl(KERN_PROC_ALL)` failed with this `errno`.
    case processTable(Int32)

    var errorDescription: String? {
        switch self {
        case .processTable(let code):
            String(localized: "Could not read the process list (\(String(cString: strerror(code)))).")
        }
    }
}
