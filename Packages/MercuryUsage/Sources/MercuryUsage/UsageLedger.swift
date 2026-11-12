import Foundation

/// Identifies a day bucket.
struct BucketKey: Codable, Sendable, Hashable {
    var day: UsageCalendarDay
    var provider: UsageProvider
    var model: String
    var project: String
}

struct BucketValue: Codable, Sendable, Hashable {
    var tokens = UsageTokens.zero
    var costUSD = 0.0
    var pricedTurns = 0
    var unpricedTurns = 0
    var turns: Int { pricedTurns + unpricedTurns }
}

/// A recently counted Claude turn, kept per file so a streaming row of the same response that arrives after the
/// checkpoint raises the counted values instead of being dropped as a duplicate.
struct RecentTurn: Codable, Sendable, Hashable {
    var key: UInt64
    var bucket: BucketKey
    var tokens: UsageTokens
    var cacheWrite1h: Int
}

/// Read state of one log file.
struct FileState: Codable, Sendable, Hashable {
    var path: String
    var provider: UsageProvider
    var checkpoint: FileCheckpoint
    var skippedLines: Int
    var recent: [RecentTurn]
    var codex: CodexContext?
}

/// What reading one file produced.
struct FileScanResult: Sendable {
    var path: String
    var provider: UsageProvider
    var outcome: JSONLTailReader.Outcome
    var turns: [ParsedTurn]
    var skippedLines: Int
    var codex: CodexContext?
}

/// All aggregated usage plus the per-file read state; this is what the cache file stores.
///
/// Deduplication: every counted record's key goes into `seenKeys`, and a key seen before (a resumed or forked session
/// copying earlier rows, a Codex rollout shared between accounts, or a file read again after truncation) is not
/// counted again. Buckets of a file that disappears are kept, so history survives Claude's transcript cleanup.
struct UsageLedger: Sendable {
    static let recentLimit = 64

    var buckets: [BucketKey: BucketValue] = [:]
    var sessions: [UsageProvider: [UsageCalendarDay: Set<UInt64>]] = [:]
    var seenKeys = Set<UInt64>()
    var files: [String: FileState] = [:]
    var updatedAt: Date?

    /// Adds a file's newly read turns.
    mutating func apply(_ result: FileScanResult) {
        let previous = files[result.path]
        // Kept even after a full reread: those keys are already counted, so their streaming updates still apply.
        var recent = previous?.recent ?? []
        var recentIndex = Dictionary(recent.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { $1 })
        for turn in result.turns {
            let bucket = BucketKey(day: turn.day, provider: result.provider, model: turn.model, project: turn.project)
            guard let key = turn.key else {
                add(turn, to: bucket, provider: result.provider)
                continue
            }
            if let index = recentIndex[key] {
                raise(&recent[index], to: turn, provider: result.provider)
                continue
            }
            guard seenKeys.insert(key).inserted else { continue }
            add(turn, to: bucket, provider: result.provider)
            if result.provider == .claude {
                recent.append(RecentTurn(key: key, bucket: bucket, tokens: turn.tokens, cacheWrite1h: turn.cacheWrite1h))
                if recent.count > Self.recentLimit * 2 {
                    recent.removeFirst(recent.count - Self.recentLimit)
                    recentIndex = Dictionary(recent.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { $1 })
                } else {
                    recentIndex[key] = recent.count - 1
                }
            }
        }
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
        let resumed = result.outcome.resumed
        files[result.path] = FileState(
            path: result.path, provider: result.provider, checkpoint: result.outcome.checkpoint,
            skippedLines: (resumed ? previous?.skippedLines ?? 0 : 0) + result.skippedLines, recent: recent,
            codex: result.codex)
    }

    private mutating func add(_ turn: ParsedTurn, to bucket: BucketKey, provider: UsageProvider) {
        var value = buckets[bucket] ?? BucketValue()
        value.tokens += turn.tokens
        if let cost = ModelPricing.cost(
            provider: provider, model: turn.model, tokens: turn.tokens, cacheWrite1h: turn.cacheWrite1h,
            longContext: turn.longContext)
        {
            value.costUSD += cost
            value.pricedTurns += 1
        } else {
            value.unpricedTurns += 1
        }
        buckets[bucket] = value
        sessions[provider, default: [:]][turn.day, default: []].insert(turn.session)
    }

    /// Applies the difference between a turn's counted values and a more complete row of the same response.
    private mutating func raise(_ recent: inout RecentTurn, to turn: ParsedTurn, provider: UsageProvider) {
        let tokens = recent.tokens.fieldMax(turn.tokens)
        let write1h = max(recent.cacheWrite1h, turn.cacheWrite1h)
        guard tokens != recent.tokens || write1h != recent.cacheWrite1h, var value = buckets[recent.bucket] else {
            return
        }
        value.tokens += tokens - recent.tokens
        let model = recent.bucket.model
        if let old = ModelPricing.cost(
            provider: provider, model: model, tokens: recent.tokens, cacheWrite1h: recent.cacheWrite1h,
            longContext: false),
            let new = ModelPricing.cost(
                provider: provider, model: model, tokens: tokens, cacheWrite1h: write1h, longContext: false)
        {
            value.costUSD += new - old
        }
        buckets[recent.bucket] = value
        recent.tokens = tokens
        recent.cacheWrite1h = write1h
    }

    /// Forgets the read state of files that no longer exist; their usage stays.
    mutating func dropFiles(notIn paths: Set<String>) -> Bool {
        let gone = files.keys.filter { !paths.contains($0) }
        for path in gone { files.removeValue(forKey: path) }
        return !gone.isEmpty
    }

    func snapshot(unreadableFiles: Int) -> UsageSnapshot {
        let days = buckets.map { key, value in
            UsageDay(
                day: key.day, provider: key.provider, model: key.model.isEmpty ? nil : key.model,
                project: key.project.isEmpty ? nil : key.project, tokens: value.tokens,
                costUSD: value.pricedTurns > 0 ? value.costUSD : nil, hasUnpricedTurns: value.unpricedTurns > 0,
                turns: value.turns)
        }
        .sorted {
            ($0.day, $0.provider.rawValue, $0.model ?? "", $0.project ?? "")
                < ($1.day, $1.provider.rawValue, $1.model ?? "", $1.project ?? "")
        }
        var skipped: [UsageProvider: Int] = [:]
        var counts: [UsageProvider: Int] = [:]
        for file in files.values {
            skipped[file.provider, default: 0] += file.skippedLines
            counts[file.provider, default: 0] += 1
        }
        return UsageSnapshot(
            days: days, updatedAt: updatedAt, fileCounts: counts, unreadableFiles: unreadableFiles,
            skippedLines: skipped, sessionDays: sessions)
    }
}

// MARK: - Cache file

/// The JSON written at the cache URL. Numbers, checkpoints, model names and project folder names only.
struct UsageCacheFile: Codable, Sendable {
    static let currentFormat = 1

    struct Bucket: Codable, Sendable {
        var key: BucketKey
        var value: BucketValue
    }

    struct SessionDay: Codable, Sendable {
        var provider: UsageProvider
        var day: UsageCalendarDay
        var sessions: [UInt64]
    }

    var format: Int
    var pricingRevision: String
    var updatedAt: Date?
    var buckets: [Bucket]
    var sessionDays: [SessionDay]
    /// `seenKeys` as sorted little-endian `UInt64`s (base64 in JSON, far smaller than a number array).
    var seenKeys: Data
    var files: [FileState]

    init(_ ledger: UsageLedger) {
        format = Self.currentFormat
        pricingRevision = ModelPricing.revision
        updatedAt = ledger.updatedAt
        buckets = ledger.buckets.map { Bucket(key: $0.key, value: $0.value) }
            .sorted { ($0.key.day, $0.key.provider.rawValue, $0.key.model, $0.key.project)
                < ($1.key.day, $1.key.provider.rawValue, $1.key.model, $1.key.project) }
        sessionDays = ledger.sessions.flatMap { provider, days in
            days.map { SessionDay(provider: provider, day: $0.key, sessions: $0.value.sorted()) }
        }
        .sorted { ($0.provider.rawValue, $0.day) < ($1.provider.rawValue, $1.day) }
        var keys = ledger.seenKeys.sorted().map(\.littleEndian)
        seenKeys = keys.withUnsafeMutableBytes { Data($0) }
        files = ledger.files.values.sorted { $0.path < $1.path }
    }

    /// nil when the file was written by another format or price table; the caller then rescans everything.
    func ledger() -> UsageLedger? {
        guard format == Self.currentFormat, pricingRevision == ModelPricing.revision,
            seenKeys.count % MemoryLayout<UInt64>.size == 0
        else { return nil }
        var ledger = UsageLedger()
        ledger.updatedAt = updatedAt
        ledger.buckets = Dictionary(buckets.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        for entry in sessionDays {
            ledger.sessions[entry.provider, default: [:]][entry.day, default: []].formUnion(entry.sessions)
        }
        var keys = [UInt64](repeating: 0, count: seenKeys.count / MemoryLayout<UInt64>.size)
        _ = keys.withUnsafeMutableBytes { seenKeys.copyBytes(to: $0) }
        ledger.seenKeys = Set(keys.map { UInt64(littleEndian: $0) })
        ledger.files = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { $1 })
        return ledger
    }
}
