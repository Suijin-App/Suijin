import SuijinCore
import SuijinPTYProtocol
import SuijinUI
import SwiftUI

/// Orchestration in the inspector, for the session the selected tab shows: a worker's task, status and messages, or a
/// coordinator's workers. Nothing for a session that takes no part in orchestration.
struct OrchestrationInspectorSection: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext

    var body: some View {
        let orchestration = model.runtimes.orchestration
        if let id = model.activeSession(in: context) {
            let workers = orchestration.workers(of: id)
            let own = orchestration.dispatches(ofWorker: id)
            if let current = own.first {
                Section("Worker") {
                    DispatchDetails(dispatch: current, showsName: true)
                }
            }
            if !workers.isEmpty {
                Section {
                    ForEach(workers) { dispatch in
                        DisclosureGroup {
                            DispatchDetails(dispatch: dispatch, showsName: false)
                        } label: {
                            DispatchHeader(dispatch: dispatch)
                        }
                    }
                } header: {
                    Text("Workers")
                } footer: {
                    if let problem = orchestration.problem {
                        Text(verbatim: problem).font(.caption).foregroundStyle(SuijinColor.warningText)
                    }
                }
            }
        }
    }
}

private struct DispatchHeader: View {
    let dispatch: OrchestrationDispatch

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: dispatch.status.systemImage).foregroundStyle(dispatch.status.color)
            AgentLogo(agent: dispatch.agent == .claude ? .claude : .codex, size: 12)
            Text(verbatim: dispatch.name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: SuijinSpacing.xs)
            dispatch.status.label.font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Spec, status, summary and messages of one dispatch.
private struct DispatchDetails: View {
    @Environment(AppModel.self) private var model
    let dispatch: OrchestrationDispatch
    let showsName: Bool

    var body: some View {
        let orchestration = model.runtimes.orchestration
        if showsName {
            LabeledContent("Name") { Text(verbatim: dispatch.name) }
        }
        LabeledContent("Status") {
            Label { dispatch.status.label } icon: {
                Image(systemName: dispatch.status.systemImage).foregroundStyle(dispatch.status.color)
            }
        }
        LabeledContent("Dispatch") { Text(verbatim: dispatch.id).monospaced().textSelection(.enabled) }
        LabeledContent("Place") { dispatch.worktree == .new ? Text("New worktree") : Text("Coordinator's folder") }
        if let spec = orchestration.task(dispatch.taskID)?.spec {
            VStack(alignment: .leading, spacing: 4) {
                Text("Task").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: spec)
                    .font(.callout)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let summary = dispatch.summary {
            VStack(alignment: .leading, spacing: 4) {
                Text("Summary").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: summary).font(.callout).lineLimit(8).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let note = dispatch.lastError {
            Label { Text(verbatim: note) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.callout)
                .foregroundStyle(SuijinColor.warningText)
        }
        let messages = orchestration.messages(of: dispatch)
        if messages.isEmpty {
            Text("No messages yet").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(messages) { message in
                MessageRow(message: message)
            }
        }
    }
}

private struct MessageRow: View {
    let message: OrchestrationMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(message.kind == .escalation ? SuijinColor.warning : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    title.font(.caption.weight(.semibold))
                    Text(message.createdAt, style: .time).font(.caption).foregroundStyle(.tertiary)
                    if message.status == .pending {
                        Text("Waiting for turn end").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Text(verbatim: message.body)
                    .font(.callout)
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch message.kind {
        case .send: "arrow.down.message"
        case .question: "questionmark.bubble"
        case .reply: "arrowshape.turn.up.left"
        case .done: "checkmark.seal"
        case .escalation: "exclamationmark.triangle"
        }
    }

    private var title: Text {
        switch message.kind {
        case .send: Text("Message to worker")
        case .question: message.answeredBy == nil ? Text("Question (unanswered)") : Text("Question")
        case .reply: Text("Reply")
        case .done: Text("Report")
        case .escalation: Text("Escalation")
        }
    }
}
