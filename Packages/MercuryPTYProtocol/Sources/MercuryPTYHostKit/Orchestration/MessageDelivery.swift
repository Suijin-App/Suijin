import Foundation
import MercuryPTYProtocol

/// The text Mercury types into agents: a worker's first prompt, and the messages delivered when a turn ends.
enum WorkerPreamble {
    /// The first prompt of a worker (or a follow-up Task for a finished one): who it is, how to reach the coordinator,
    /// then the task. The commands sit next to the rules so the agent reads both.
    static func build(taskID: String, dispatchID: String, name: String, spec: String, followUp: Bool) -> String {
        let lead = followUp
            ? "[Mercury] Your coordinator sent you a follow-up Task. Finish it with `mercury done` as before."
            : "You are a worker agent started through Mercury by another agent, your coordinator."
        return """
        \(lead)
        Worker: \(name)
        Task ID: \(taskID)
        Dispatch ID: \(dispatchID)

        Your coordinator cannot see this terminal and nobody watches it. Reach the coordinator only with the \
        `mercury` command (if it is not on PATH, run "$MERCURY_CLI" instead):

          # Ask a question, then END YOUR TURN. Mercury types the answer here when it comes.
          # Never ask in this terminal (no AskUserQuestion or other local prompts): nobody would answer.
          mercury ask --body "<your question>"

          # Finish: run exactly once, then end your turn. Use --status failed if the work is not done.
          mercury done --status success --summary "<what you did, what you found, what is left>"

        Do only this task, yourself. Never poll, sleep or loop waiting for messages: Mercury delivers them when \
        your turn ends.

        === TASK ===
        \(spec)
        """
    }
}

/// Builds the paste for one delivery and the bytes that type it.
enum MessageDelivery {
    static let pasteStart = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC [ 200 ~
    static let pasteEnd = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])   // ESC [ 201 ~
    static let submit = Data([0x0D])

    /// Bracketed paste of `text`. Escape and other control characters are removed (a message must not be able to
    /// end the paste early or send keys); newlines and tabs stay.
    static func pastePayload(_ text: String) -> Data {
        pasteStart + Data(sanitize(text).utf8) + pasteEnd
    }

    static func sanitize(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !(scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value))
        }))
    }

    /// Return goes in a separate write once the agent took the paste in: Claude can leave a draft unsent when the paste
    /// end and Return arrive together, and Codex's paste detection needs a pause. Half a second plus ingest time.
    static func submitDelay(forPasteBytes count: Int) -> TimeInterval {
        0.5 + Double(count) / 4_096_000
    }

    /// One paste for all `messages` waiting for `recipient`, oldest first.
    static func compose(_ messages: [OrchestrationMessage], recipient: String, state: OrchestrationSnapshot) -> String {
        let parts = messages.map { render($0, state: state) }
        var text = parts.count == 1
            ? parts[0]
            : "[Mercury] \(parts.count) messages for you:\n\n" + parts.joined(separator: "\n\n")
        let coordinatesWorkers = state.dispatches.contains { $0.coordinatorSessionID == recipient }
        let reportsResults = messages.contains { $0.kind == .done || $0.kind == .escalation }
        if coordinatesWorkers, reportsResults {
            let open = state.dispatches.filter { $0.coordinatorSessionID == recipient && !$0.status.isSettled }
            if open.isEmpty {
                text += "\n\n[Mercury] Every worker has reported. Tell the user the outcome of each task, with its evidence and open blockers."
            } else {
                let names = open.map { "\"\($0.name)\" (\($0.id))" }.joined(separator: ", ")
                text += "\n\n[Mercury] Still working: \(names). Handle what arrived, then end your turn; Mercury wakes you again."
            }
        }
        return text
    }

    static func render(_ message: OrchestrationMessage, state: OrchestrationSnapshot) -> String {
        let dispatch = state.dispatches.first { $0.id == message.dispatchID }
        let worker = dispatch.map { "Worker \"\($0.name)\" (dispatch \($0.id))" } ?? "Dispatch \(message.dispatchID)"
        switch message.kind {
        case .question:
            return """
            [Mercury] \(worker) asks (question \(message.id)):
            \(message.body)
            Answer with: mercury reply --id \(message.id) --body "<answer>"
            If the answer does not follow from the task or the user's instructions, ask the user first.
            """
        case .done:
            let outcome = dispatch?.status == .failed ? "failed" : "finished successfully"
            return """
            [Mercury] \(worker) \(outcome).
            Summary: \(message.body)
            """
        case .escalation:
            return """
            [Mercury] \(worker) needs attention: \(message.body)
            Steer it with: mercury send --to \(message.dispatchID) --body "<message>", or tell the user.
            """
        case .reply:
            return """
            [Mercury] Your coordinator answered your question \(message.inReplyTo ?? ""):
            \(message.body)
            Continue the task. Finish with: mercury done --status success|failed --summary "<summary>"
            """
        case .send:
            if let taskID = message.followUpTaskID {
                return WorkerPreamble.build(taskID: taskID, dispatchID: message.dispatchID,
                                            name: dispatch?.name ?? "worker", spec: message.body, followUp: true)
            }
            return """
            [Mercury] Message from your coordinator (dispatch \(message.dispatchID)):
            \(message.body)
            """
        }
    }
}
