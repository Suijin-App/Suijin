import Foundation

/// Raw Codex token counters as written in `token_count` events. `input` includes `cachedInput`, and `output` includes
/// `reasoningOutput`.
struct CodexRawUsage: Codable, Sendable, Hashable {
    var input: Int
    var cachedInput: Int
    var output: Int
    var reasoningOutput: Int
    var total: Int

    init(input: Int, cachedInput: Int, output: Int, reasoningOutput: Int, total: Int) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.reasoningOutput = reasoningOutput
        self.total = total
    }

    /// nil when `value` is not an object.
    init?(_ value: Any?) {
        guard let record = value as? [String: Any] else { return nil }
        input = JSONLine.count(record["input_tokens"])
        cachedInput = JSONLine.count(record["cached_input_tokens"] ?? record["cache_read_input_tokens"])
        output = JSONLine.count(record["output_tokens"])
        reasoningOutput = JSONLine.count(record["reasoning_output_tokens"])
        let total = JSONLine.count(record["total_tokens"])
        // Legacy logs may omit totals; reasoning is already part of output.
        self.total = total > 0 ? total : input + output
    }

    static let zero = CodexRawUsage(input: 0, cachedInput: 0, output: 0, reasoningOutput: 0, total: 0)

    var isZero: Bool { input == 0 && cachedInput == 0 && output == 0 && reasoningOutput == 0 && total == 0 }

    /// Compares the counters, ignoring `total`.
    func sameCounters(as other: CodexRawUsage) -> Bool {
        input == other.input && cachedInput == other.cachedInput && output == other.output
            && reasoningOutput == other.reasoningOutput
    }

    func isMonotonic(from previous: CodexRawUsage) -> Bool {
        input >= previous.input && cachedInput >= previous.cachedInput && output >= previous.output
            && reasoningOutput >= previous.reasoningOutput
    }

    var magnitude: Int { input + cachedInput + output + reasoningOutput }

    func subtracting(_ previous: CodexRawUsage) -> CodexRawUsage {
        CodexRawUsage(
            input: max(input - previous.input, 0), cachedInput: max(cachedInput - previous.cachedInput, 0),
            output: max(output - previous.output, 0),
            reasoningOutput: max(reasoningOutput - previous.reasoningOutput, 0), total: max(total - previous.total, 0))
    }

    func adding(_ other: CodexRawUsage) -> CodexRawUsage {
        CodexRawUsage(
            input: input + other.input, cachedInput: cachedInput + other.cachedInput, output: output + other.output,
            reasoningOutput: reasoningOutput + other.reasoningOutput, total: total + other.total)
    }

    var tuple: String { "\(input),\(cachedInput),\(output),\(reasoningOutput),\(total)" }
}

/// Turns Codex's cumulative `total_token_usage` (and per-request `last_token_usage`) into per-event deltas within one
/// session file. Port of Orca's `codex-usage-token-delta.ts`.
enum CodexTokenDelta {
    enum Resolution: Equatable {
        /// Billable increment, and the totals to compare the next event with.
        case event(delta: CodexRawUsage, nextTotals: CodexRawUsage?)
        /// Totals reset (a new baseline) without anything billable.
        case baseline(CodexRawUsage)
    }

    static func resolve(total: CodexRawUsage?, last: CodexRawUsage?, previous: CodexRawUsage?) -> Resolution? {
        if let total, let last, let previous {
            if total.sameCounters(as: previous) { return nil }
            if !total.isMonotonic(from: previous), looksLikeStaleRegression(total, previous: previous, last: last) {
                return nil
            }
            // Compaction or resume can rewrite totals; `last_token_usage` is the billable increment.
            return .event(delta: last, nextTotals: total)
        }
        if let total, let last { return .event(delta: last, nextTotals: total) }
        if let total, let previous {
            if total.sameCounters(as: previous) { return nil }
            if !total.isMonotonic(from: previous) { return .baseline(total) }
            return .event(delta: total.subtracting(previous), nextTotals: total)
        }
        if let total { return .event(delta: total, nextTotals: total) }
        if let last, let previous { return .event(delta: last, nextTotals: previous.adding(last)) }
        if let last { return .event(delta: last, nextTotals: nil) }
        return nil
    }

    /// A replayed older snapshot after a newer one: nearly the same size, or smaller than the gap a single request
    /// could explain.
    private static func looksLikeStaleRegression(_ current: CodexRawUsage, previous: CodexRawUsage, last: CodexRawUsage)
        -> Bool
    {
        let previousTotal = previous.magnitude
        let currentTotal = current.magnitude
        let lastTotal = last.magnitude
        guard previousTotal > 0, currentTotal > 0, lastTotal > 0 else { return false }
        return currentTotal * 100 >= previousTotal * 98 || currentTotal + lastTotal * 2 >= previousTotal
    }

    /// Fork copies keep turn IDs and counters but rewrite session IDs, so the key leaves the session out.
    static func eventKey(identity: String, total: CodexRawUsage?, last: CodexRawUsage?) -> String {
        "\(identity)|\(total?.tuple ?? "")|\(last?.tuple ?? "")"
    }
}
