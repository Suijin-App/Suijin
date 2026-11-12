import Foundation
import MercuryPTYProtocol

/// When the broker tells a coordinator that a worker needs attention.
enum Escalation {
    /// The worker ended a turn: escalate when it neither reported `done` nor waits for an answer.
    static func reasonForTurnEnd(_ dispatch: OrchestrationDispatch) -> String? {
        guard dispatch.status == .running else { return nil }
        return "it ended its turn without reporting `mercury done` (it may be stuck, waiting on a prompt, or finished without reporting)."
    }

    /// The worker's process ended: escalate unless it already reported.
    static func reasonForExit(_ dispatch: OrchestrationDispatch, status: Int32) -> String? {
        guard !dispatch.status.isSettled else { return nil }
        let how = status == 0 ? "exited" : status > 128 ? "was killed (signal \(status - 128))" : "exited with status \(status)"
        return "its process \(how) before it reported `mercury done`."
    }

    static func reasonForStartFailure(_ error: String) -> String {
        "it could not be started: \(error)"
    }
}
