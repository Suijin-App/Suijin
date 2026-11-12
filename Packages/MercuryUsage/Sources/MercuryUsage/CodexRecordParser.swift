import Darwin
import Foundation

/// What a Codex session file has said so far, persisted so an appended file resumes with the right model, project
/// and cumulative totals. Holds labels and numbers only, never paths or text.
struct CodexContext: Codable, Sendable, Hashable {
    var session: UInt64
    var sessionProject: String?
    var currentProject: String?
    var currentModel: String?
    var currentTurnID: String?
    var previousTotals: CodexRawUsage?

    init(path: String) {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        session = CodexContext.sessionHash(name)
    }

    static func sessionHash(_ id: String) -> UInt64 { StableHash.hash("codex-session:\(id)") }
}

/// Reads Codex rollout lines (`~/.codex/sessions/**/*.jsonl`). Port of Orca's `codex-usage-record-parser.ts`:
/// `session_meta` and `turn_context` set the session, project and model; each `event_msg` of type `token_count`
/// becomes one event whose tokens are the delta from the previous cumulative totals.
struct CodexFileParser {
    let timeZone: TimeZone
    private(set) var context: CodexContext
    private(set) var turns: [ParsedTurn] = []
    private(set) var skippedLines = 0

    init(context: CodexContext, timeZone: TimeZone) {
        self.context = context
        self.timeZone = timeZone
    }

    private static let markers = [#""token_count""#, #""turn_context""#, #""session_meta""#].map { Array($0.utf8) }

    static func mayBeRelevant(_ line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress else { return false }
        return markers.contains { marker in
            line.count >= marker.count
                && marker.withUnsafeBytes { memmem(base, line.count, $0.baseAddress!, $0.count) != nil }
        }
    }

    mutating func consume(_ line: UnsafeRawBufferPointer) {
        guard Self.mayBeRelevant(line) else { return }
        guard let record = JSONLine.object(line) else {
            skippedLines += 1
            return
        }
        if let turn = apply(record) { turns.append(turn) }
    }

    /// An unterminated last line is consumed only when it parses as a complete record.
    mutating func consumeTail(_ line: UnsafeRawBufferPointer) -> Bool {
        guard Self.mayBeRelevant(line), let record = JSONLine.object(line) else { return false }
        if let turn = apply(record) { turns.append(turn) }
        return true
    }

    private mutating func apply(_ record: [String: Any]) -> ParsedTurn? {
        guard let type = record["type"] as? String, let payload = record["payload"] as? [String: Any] else {
            return nil
        }
        switch type {
        case "session_meta":
            if let id = JSONLine.string(payload["id"]) { context.session = CodexContext.sessionHash(id) }
            context.sessionProject = JSONLine.string(payload["cwd"]).map { ProjectLabel.from(cwd: $0) }
            if context.currentProject == nil { context.currentProject = context.sessionProject }
            return nil
        case "turn_context":
            context.currentTurnID = JSONLine.string(payload["turn_id"])
            if let cwd = JSONLine.string(payload["cwd"]) {
                context.currentProject = ProjectLabel.from(cwd: cwd)
            } else if context.currentProject == nil {
                context.currentProject = context.sessionProject
            }
            context.currentModel = Self.model(in: payload) ?? context.currentModel
            return nil
        case "event_msg":
            return tokenCount(record: record, payload: payload)
        default:
            return nil
        }
    }

    private mutating func tokenCount(record: [String: Any], payload: [String: Any]) -> ParsedTurn? {
        guard payload["type"] as? String == "token_count", let timestamp = JSONLine.string(record["timestamp"]) else {
            return nil
        }
        // Rate-limit updates legitimately carry `info: null`.
        guard let info = payload["info"] as? [String: Any] else { return nil }
        let total = CodexRawUsage(info["total_token_usage"])
        let last = CodexRawUsage(info["last_token_usage"])
        guard let resolution = CodexTokenDelta.resolve(total: total, last: last, previous: context.previousTotals)
        else { return nil }
        let rawDelta: CodexRawUsage
        let nextTotals: CodexRawUsage?
        switch resolution {
        case .baseline(let totals):
            context.previousTotals = totals
            return nil
        case .event(let delta, let next):
            rawDelta = delta
            nextTotals = next
        }
        var delta = rawDelta
        delta.cachedInput = min(delta.cachedInput, delta.input)
        guard !delta.isZero else { return nil }
        context.previousTotals = nextTotals

        guard let seconds = ISOTimestamp.epochSeconds(timestamp) else {
            skippedLines += 1
            return nil
        }
        // Fork copies rewrite timestamps but keep turn IDs; last-only deltas need the timestamp to stay distinct.
        let identity = total != nil ? (context.currentTurnID ?? timestamp) : timestamp
        let key = CodexTokenDelta.eventKey(identity: identity, total: total, last: last)
        return ParsedTurn(
            key: StableHash.hash("codex:\(key)"),
            day: UsageCalendarDay(epochSeconds: seconds, timeZone: timeZone),
            session: context.session,
            model: Self.model(in: payload) ?? context.currentModel ?? "",
            project: context.currentProject ?? context.sessionProject ?? "",
            tokens: UsageTokens(
                input: delta.input - delta.cachedInput, output: delta.output, cacheRead: delta.cachedInput,
                cacheWrite: 0),
            cacheWrite1h: 0,
            // Long context is priced per request; a total-only delta may span several requests.
            longContext: last != nil && delta.input > ModelPricing.codexLongContextThreshold)
    }

    /// `model` / `model_name` directly, under `info`, or under `metadata`.
    static func model(in record: [String: Any]) -> String? {
        if let direct = JSONLine.string(record["model"]) ?? JSONLine.string(record["model_name"]) { return direct }
        if let info = record["info"] as? [String: Any] {
            if let direct = JSONLine.string(info["model"]) ?? JSONLine.string(info["model_name"]) { return direct }
            if let metadata = info["metadata"] as? [String: Any], let model = JSONLine.string(metadata["model"]) {
                return model
            }
        }
        if let metadata = record["metadata"] as? [String: Any] { return JSONLine.string(metadata["model"]) }
        return nil
    }
}
