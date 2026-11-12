import Observation
import SwiftUI

/// Progress event emitted by a long operation (Pull & Up, safe file save, recipe…).
public enum ProgressEvent: Sendable, Equatable {
    case stepStarted(Int)
    case stepFinished(Int)
    /// Marks one step failed while the run continues (bulk operations where each item is independent).
    case stepFailed(Int)
    case log(String)
    /// Stops at the current step, with a reason for the user.
    case failed(String)
}

/// State of the progress sheet. Separated from the view so it is testable.
@MainActor
@Observable
public final class ProgressModel: Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    public enum StepState: Equatable, Sendable { case pending, running, done, failed }
    public enum Outcome: Equatable, Sendable { case running, succeeded, failed(String) }

    public let title: String
    public let stepTitles: [String]
    public private(set) var steps: [StepState]
    public private(set) var log: String = ""
    public private(set) var outcome: Outcome = .running
    /// The user tapped `Chạy nền` (run in background): the sheet closes, the operation keeps running.
    public var runsInBackground = false
    /// Stops the operation (cancels its task, which stops the remote command). Set by operations that can
    /// be stopped; the sheet then offers `Dừng` while it runs.
    @ObservationIgnored public var stopHandler: (@MainActor () -> Void)?
    /// `Dừng` was pressed and the operation is winding down.
    public private(set) var isStopping = false

    /// The operation can be stopped now.
    public var canStop: Bool { stopHandler != nil && outcome == .running && !isStopping }

    public init(title: String, steps: [String]) {
        self.title = title
        self.stepTitles = steps
        self.steps = Array(repeating: .pending, count: steps.count)
    }

    public var fractionComplete: Double {
        guard !steps.isEmpty else { return outcome == .succeeded ? 1 : 0 }
        return Double(steps.filter { $0 == .done }.count) / Double(steps.count)
    }

    public func apply(_ event: ProgressEvent) {
        guard outcome == .running else { return }
        switch event {
        case .stepStarted(let index) where steps.indices.contains(index):
            steps[index] = .running
        case .stepFinished(let index) where steps.indices.contains(index):
            steps[index] = .done
        case .stepFailed(let index) where steps.indices.contains(index):
            steps[index] = .failed
        case .log(let line):
            log += log.isEmpty ? line : "\n" + line
        case .failed(let reason):
            if let running = steps.firstIndex(of: .running) { steps[running] = .failed }
            outcome = .failed(reason)
        default:
            break
        }
    }

    /// Asks the operation to stop. Its task reports the end (usually `.failed`) when it has stopped.
    public func stop() {
        guard canStop, let stopHandler else { return }
        isStopping = true
        stopHandler()
    }

    /// Called when the stream ends without error.
    public func finish() {
        guard outcome == .running else { return }
        outcome = .succeeded
    }

    /// Runs an event stream until it finishes; a thrown error is turned into `.failed`.
    public func run(_ stream: AsyncThrowingStream<ProgressEvent, Error>) async {
        do {
            for try await event in stream { apply(event) }
            finish()
        } catch {
            apply(.failed(error.localizedDescription))
        }
    }
}

/// Sheet showing progress: step list, progress bar, live log.
public struct ProgressSheetView: View {
    @Bindable var model: ProgressModel
    let doneTitle: Text?
    let onClose: @MainActor () -> Void

    public init(model: ProgressModel, doneTitle: Text? = nil, onClose: @escaping @MainActor () -> Void) {
        self.model = model
        self.doneTitle = doneTitle
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MercurySpacing.m) {
            Text(model.title).font(.headline)
            ProgressView(value: model.fractionComplete)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.stepTitles.enumerated()), id: \.offset) { index, title in
                    HStack(spacing: MercurySpacing.s) {
                        stepIcon(model.steps[index]).frame(width: 16)
                        Text(title).foregroundStyle(model.steps[index] == .failed ? MercuryColor.errorText : .primary)
                    }
                    .font(.callout)
                }
            }
            if !model.log.isEmpty {
                ScrollView {
                    Text(model.log)
                        .font(MercuryFont.monoSmall)
                        .foregroundStyle(MercuryColor.terminalText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(MercurySpacing.s)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 200)
                .background(RoundedRectangle(cornerRadius: MercuryRadius.control).fill(MercuryColor.terminalBackground))
            }
            HStack {
                switch model.outcome {
                case .running: Text("Running…", bundle: .module).foregroundStyle(.secondary)
                case .succeeded: (doneTitle ?? Text("Done", bundle: .module)).foregroundStyle(MercuryColor.okText)
                case .failed(let reason): Text(reason).foregroundStyle(MercuryColor.errorText)
                }
                Spacer()
                if model.stopHandler != nil, model.outcome == .running {
                    Button(role: .destructive) { model.stop() } label: { Text("Stop", bundle: .module) }
                        .disabled(!model.canStop)
                        .help(Text("Stop the running command", bundle: .module))
                        .accessibilityIdentifier("progress.stop")
                }
                if model.outcome == .running {
                    Button { model.runsInBackground = true; onClose() } label: { Text("Run in Background", bundle: .module) }
                        .accessibilityIdentifier("progress.background")
                }
                Button(action: onClose) { model.outcome == .running ? Text("Done", bundle: .module) : Text("Close", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.outcome == .running)
                    .accessibilityIdentifier("progress.close")
            }
            .font(.callout)
        }
        .padding(MercurySpacing.xl)
        .frame(width: 560)
    }

    @ViewBuilder private func stepIcon(_ state: ProgressModel.StepState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark").foregroundStyle(MercuryColor.ok)
        case .failed: Image(systemName: "xmark").foregroundStyle(MercuryColor.error)
        }
    }
}
