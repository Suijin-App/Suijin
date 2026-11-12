import Foundation
import SevindaAgents
import SevindaCore
import SevindaTerminal
import Observation

/// What the Resource Manager shows: one group per workspace with running sessions, then Mercury's own processes.
struct ResourceReport: Equatable {
    enum GroupID: Hashable {
        case workspace(UUID)
        case mercury
    }

    enum Icon: Equatable {
        case agent(AgentKind)
        case symbol(String)
    }

    struct Row: Identifiable, Equatable {
        let id: ResourceKey
        var title: String
        /// The worktree branch for sessions outside the main checkout.
        var subtitle: String?
        var icon: Icon
        /// The session's status; nil for Mercury's own processes.
        var activity: SessionActivityDisplay?
        /// Nil while the process could not be measured (not found, or not sampled yet).
        var figures: ResourceFigures?
        /// Where the session lives, so selecting the row can open it.
        var context: SessionContext?
    }

    struct Group: Identifiable, Equatable {
        let id: GroupID
        var title: String
        var rows: [Row]

        var memory: UInt64 { rows.reduce(0) { $0 + ($1.figures?.memory ?? 0) } }
        var cpu: Double? { ResourceReport.sumCPU(rows) }
    }

    var sessionGroups: [Group]
    var mercury: Group

    var memory: UInt64 { sessionGroups.reduce(mercury.memory) { $0 + $1.memory } }
    var cpu: Double? { Self.sumCPU(sessionGroups.flatMap(\.rows) + mercury.rows) }

    /// The sum of the known CPU figures; nil when none is known yet.
    private static func sumCPU(_ rows: [Row]) -> Double? {
        let known = rows.compactMap { $0.figures?.cpu }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// Groups the live sessions by workspace, largest memory first (rows within a group too). Mercury comes last.
    @MainActor
    static func build(model: AppModel, figures: [ResourceKey: ResourceFigures]) -> ResourceReport {
        var groups: [UUID: Group] = [:]
        for session in liveSessions(of: model) {
            let row = Row(
                id: .session(session.id),
                title: model.runtimes.displayTitle(of: session),
                subtitle: session.worktreeID.flatMap { model.worktree($0)?.branch },
                icon: .agent(session.agent),
                activity: model.runtimes.activity(of: session),
                figures: figures[.session(session.id)],
                context: model.context(of: session)
            )
            let title = model.workspace(session.workspaceID)?.name ?? String(localized: "Workspace")
            groups[session.workspaceID, default: Group(id: .workspace(session.workspaceID), title: title, rows: [])].rows.append(row)
        }
        let sessionGroups = groups.values
            .map { group in var sorted = group; sorted.rows.sort(by: byMemory); return sorted }
            .sorted { ($0.memory, $1.title) > ($1.memory, $0.title) }
        let mercury = Group(id: .mercury, title: String(localized: "Mercury"), rows: [
            Row(id: .app, title: String(localized: "Mercury"), icon: .symbol("macwindow"), figures: figures[.app]),
            Row(id: .terminalHost, title: String(localized: "Terminal host"), icon: .symbol("server.rack"), figures: figures[.terminalHost]),
        ].sorted(by: byMemory))
        return ResourceReport(sessionGroups: sessionGroups, mercury: mercury)
    }

    private static func byMemory(_ lhs: Row, _ rhs: Row) -> Bool {
        (lhs.figures?.memory ?? 0, rhs.title) > (rhs.figures?.memory ?? 0, lhs.title)
    }

    @MainActor
    static func liveSessions(of model: AppModel) -> [AgentSessionRecord] {
        model.sessions.filter { model.runtimes.activities[$0.id].map { !$0.isTerminal } ?? false }
    }
}

/// Samples the processes behind the live sessions and Mercury while the Resource Manager is open, and keeps the last
/// memory totals of each group for its sparkline.
@Observable
@MainActor
final class ResourceMonitor {
    static let historyLength = 30

    private(set) var report: ResourceReport?
    private(set) var history: [ResourceReport.GroupID: [UInt64]] = [:]
    /// Why the last sample failed or is incomplete; nil when it is complete.
    private(set) var problem: String?
    @ObservationIgnored private let sampler = ProcessSampler()

    /// Takes one sample and rebuilds the report. The syscalls run on the sampler actor, off the main thread.
    func refresh(model: AppModel) async {
        let (targets, hostProblem) = await Self.targets(model: model)
        do {
            let figures = try await sampler.sample(targets)
            let report = ResourceReport.build(model: model, figures: figures)
            self.report = report
            record(report)
            problem = hostProblem
        } catch {
            problem = error.localizedDescription
            if report == nil { report = ResourceReport.build(model: model, figures: [:]) }
        }
    }

    private func record(_ report: ResourceReport) {
        var next: [ResourceReport.GroupID: [UInt64]] = [:]
        for group in report.sessionGroups + [report.mercury] {
            next[group.id] = Array(((history[group.id] ?? []) + [group.memory]).suffix(Self.historyLength))
        }
        history = next
    }

    /// The process of every live session (its PTY child: in the app for in-process terminals, otherwise as the PTY
    /// host reports it), Mercury itself and the PTY host.
    private static func targets(model: AppModel) async -> ([ResourceKey: ResourceTarget], String?) {
        var targets: [ResourceKey: ResourceTarget] = [.app: .process(getpid())]
        var hosted: [UUID: String] = [:]
        for session in ResourceReport.liveSessions(of: model) {
            let engine = model.runtimes.runtime(for: session.id)?.terminal.engine
            if let local = engine as? SwiftTermEngine {
                if let pid = local.processID { targets[.session(session.id)] = .tree(pid) }
            } else if let hostID = engine?.sessionID ?? session.hostSessionID {
                hosted[session.id] = hostID
            }
        }
        var hostPIDs: [pid_t] = []
        var problem: String?
        if !hosted.isEmpty {
            do {
                let infos = try await PTYHostClient.shared.listSessions()
                let byID = Dictionary(infos.filter(\.isRunning).map { ($0.id, $0.pid) }, uniquingKeysWith: { first, _ in first })
                for (sessionID, hostID) in hosted {
                    guard let pid = byID[hostID] else { continue }
                    targets[.session(sessionID)] = .tree(pid)
                    hostPIDs.append(pid)
                }
            } catch {
                problem = String(localized: "Could not reach the terminal host: \(error.localizedDescription)")
            }
        }
        targets[.terminalHost] = .terminalHost(sessionPIDs: hostPIDs)
        return (targets, problem)
    }
}
