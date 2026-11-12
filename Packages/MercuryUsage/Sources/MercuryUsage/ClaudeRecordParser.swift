import Darwin
import Foundation

/// One billable request (Claude) or token-count event (Codex), already reduced to numbers and labels.
struct ParsedTurn: Sendable, Hashable {
    /// Hash of the deduplication key; nil when the record has no stable identity (then it is always counted).
    var key: UInt64?
    var day: UsageCalendarDay
    var session: UInt64
    /// Raw model ID; empty when unknown.
    var model: String
    /// Project folder name; empty when unknown.
    var project: String
    var tokens: UsageTokens
    /// Part of `tokens.cacheWrite` written with the one-hour TTL (Claude only).
    var cacheWrite1h: Int
    /// The Codex request exceeded the long-context threshold.
    var longContext: Bool
}

/// Result of looking at one line.
enum RecordOutcome {
    /// Not a usage record (most lines).
    case irrelevant
    /// Looked like a usage record but could not be parsed; counted and reported as skipped.
    case malformed
    case turn(ParsedTurn)
}

/// Reads Claude Code transcript lines (`~/.claude/projects/**/*.jsonl`). Port of Orca's
/// `transcript-record-parser.ts`: only `type == "assistant"` records with `message.usage` count, and rows of one
/// response (same `message.id` + `requestId`, written once per content block) collapse into one turn that keeps the
/// largest value of each counter.
struct ClaudeFileParser {
    let fallbackSessionID: String
    let timeZone: TimeZone
    private(set) var turns: [ParsedTurn] = []
    private(set) var skippedLines = 0
    private var indexByKey: [UInt64: Int] = [:]

    init(path: String, timeZone: TimeZone) {
        fallbackSessionID = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        self.timeZone = timeZone
    }

    /// Only assistant records carry usage; skipping other lines before JSON parsing keeps large tool results cheap.
    /// Claude Code writes compact JSON, and the parsed `type` remains authoritative.
    private static let marker = Array(#""type":"assistant""#.utf8)

    static func mayBeUsageRecord(_ line: UnsafeRawBufferPointer) -> Bool {
        guard line.count >= marker.count, let base = line.baseAddress else { return false }
        return marker.withUnsafeBytes { needle in
            memmem(base, line.count, needle.baseAddress!, needle.count) != nil
        }
    }

    mutating func consume(_ line: UnsafeRawBufferPointer) {
        guard Self.mayBeUsageRecord(line) else { return }
        switch Self.parse(line, fallbackSessionID: fallbackSessionID, timeZone: timeZone) {
        case .irrelevant: break
        case .malformed: skippedLines += 1
        case .turn(let turn): add(turn)
        }
    }

    /// An unterminated last line is consumed only when it is a complete usage record.
    mutating func consumeTail(_ line: UnsafeRawBufferPointer) -> Bool {
        guard Self.mayBeUsageRecord(line) else { return false }
        switch Self.parse(line, fallbackSessionID: fallbackSessionID, timeZone: timeZone) {
        case .malformed: return false
        case .irrelevant: return true
        case .turn(let turn):
            add(turn)
            return true
        }
    }

    private mutating func add(_ turn: ParsedTurn) {
        guard let key = turn.key else {
            turns.append(turn)
            return
        }
        if let index = indexByKey[key] {
            // Later streaming rows can carry more complete usage for the same response.
            turns[index].tokens = turns[index].tokens.fieldMax(turn.tokens)
            turns[index].cacheWrite1h = max(turns[index].cacheWrite1h, turn.cacheWrite1h)
            return
        }
        indexByKey[key] = turns.count
        turns.append(turn)
    }

    static func parse(_ line: UnsafeRawBufferPointer, fallbackSessionID: String, timeZone: TimeZone) -> RecordOutcome {
        guard let record = JSONLine.object(line) else { return .malformed }
        guard record["type"] as? String == "assistant" else { return .irrelevant }
        let message = record["message"] as? [String: Any]
        guard let usage = message?["usage"] as? [String: Any] else { return .irrelevant }
        let input = JSONLine.count(usage["input_tokens"])
        let output = JSONLine.count(usage["output_tokens"])
        let cacheRead = JSONLine.count(usage["cache_read_input_tokens"])
        let cacheWrite = JSONLine.count(usage["cache_creation_input_tokens"])
        guard input + output + cacheRead + cacheWrite > 0 else { return .irrelevant }
        // The 1h TTL split of the cache writes; capped so the implied 5m remainder stays nonnegative.
        let split = usage["cache_creation"] as? [String: Any]
        let cacheWrite1h = min(JSONLine.count(split?["ephemeral_1h_input_tokens"]), cacheWrite)

        guard let timestamp = JSONLine.string(record["timestamp"]), let seconds = ISOTimestamp.epochSeconds(timestamp)
        else { return .malformed }
        let session = JSONLine.string(record["sessionId"]) ?? fallbackSessionID
        return .turn(
            ParsedTurn(
                key: dedupeKey(record: record, message: message).map { StableHash.hash("claude:\($0)") },
                day: UsageCalendarDay(epochSeconds: seconds, timeZone: timeZone),
                session: StableHash.hash("claude-session:\(session)"),
                model: JSONLine.string(message?["model"]) ?? "",
                project: ProjectLabel.from(cwd: JSONLine.string(record["cwd"])),
                tokens: UsageTokens(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite),
                cacheWrite1h: cacheWrite1h, longContext: false))
    }

    /// Forks and resumed sessions copy earlier rows into new files; message IDs (or row UUIDs) identify them there.
    static func dedupeKey(record: [String: Any], message: [String: Any]?) -> String? {
        let messageID = JSONLine.string(message?["id"])
        let requestID = JSONLine.string(record["requestId"])
        if let messageID, let requestID { return "\(messageID):\(requestID)" }
        if let messageID { return "msg:\(messageID)" }
        if let uuid = JSONLine.string(record["uuid"]) { return "uuid:\(uuid)" }
        return nil
    }
}

/// Small helpers over `JSONSerialization` output.
enum JSONLine {
    static func object(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress, line.count > 1 else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A finite, nonnegative integer counter; anything else counts as 0.
    static func count(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        let double = number.doubleValue
        guard double.isFinite, double > 0 else { return 0 }
        return double >= 9e18 ? Int.max / 4 : number.intValue
    }

    /// A trimmed, non-empty string.
    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
