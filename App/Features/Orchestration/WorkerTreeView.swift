import SuijinCore
import SuijinPTYProtocol
import SuijinUI
import SwiftUI

/// How a dispatch looks in the sidebar and the inspector.
extension DispatchStatus {
    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .starting: "circle.dotted"
        case .running: "circle.fill"
        case .asking: "questionmark.bubble.fill"
        case .stalled: "exclamationmark.triangle.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .exited: "stop.circle"
        case .startFailed: "xmark.octagon"
        }
    }

    var color: Color {
        switch self {
        case .queued, .starting, .exited: SuijinColor.idle
        case .running, .succeeded: SuijinColor.ok
        case .asking, .stalled: SuijinColor.warning
        case .failed, .startFailed: SuijinColor.error
        }
    }

    var label: Text {
        switch self {
        case .queued: Text("Queued")
        case .starting: Text("Starting")
        case .running: Text("Working")
        case .asking: Text("Asking")
        case .stalled: Text("Needs attention")
        case .succeeded: Text("Done")
        case .failed: Text("Failed")
        case .exited: Text("Exited")
        case .startFailed: Text("Not started")
        }
    }

    /// The worker waits on its coordinator (or the user): pulse it.
    var wantsAttention: Bool { self == .asking || self == .stalled }
}

/// The workers a coordinator session started, nested under its row in the sidebar. Clicking a worker opens its tab,
/// wherever it runs (often a new worktree).
struct WorkerTreeView: View {
    @Environment(AppModel.self) private var model
    let coordinator: AgentSessionRecord

    var body: some View {
        let workers = model.runtimes.orchestration.workers(of: coordinator.id)
        ForEach(workers) { dispatch in
            WorkerRow(dispatch: dispatch)
        }
    }
}

private struct WorkerRow: View {
    @Environment(AppModel.self) private var model
    let dispatch: OrchestrationDispatch

    var body: some View {
        let session = dispatch.workerSessionID.flatMap(UUID.init(uuidString:)).flatMap { id in model.sessions.first { $0.id == id } }
        Button {
            guard let session else { return }
            let context = model.context(of: session)
            model.selection = context
            model.selectedTab[context] = .session(session.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Image(systemName: dispatch.status.systemImage)
                    .font(.caption)
                    .foregroundStyle(dispatch.status.color)
                    .symbolEffect(.pulse, isActive: dispatch.status.wantsAttention)
                AgentLogo(agent: dispatch.agent == .claude ? .claude : .codex, size: 12)
                    .opacity(dispatch.status.isSettled ? 0.5 : 1)
                Text(verbatim: dispatch.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                Spacer(minLength: SuijinSpacing.xs)
                dispatch.status.label
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.leading, SuijinSpacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session == nil)
        .help(Text(verbatim: model.runtimes.orchestration.task(dispatch.taskID)?.spec ?? dispatch.name))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Worker \(dispatch.name)"))
        .accessibilityValue(dispatch.status.label)
        .accessibilityAddTraits(.isButton)
    }
}
