import Foundation
import GRDB

/// A counter in `stat_counter`. `trackingSince` holds Unix seconds; the others are plain counts.
public enum StatKey: String, Sendable, CaseIterable {
    case agentsSpawned
    /// Total seconds agent sessions spent working (their activity was `running`).
    case agentWorkSeconds
    case prsCreated
    /// When Suijin started counting, in Unix seconds.
    case trackingSince
}

/// Suijin's own usage totals, for the Stats page.
public struct SuijinStats: Sendable, Equatable {
    public var agentsSpawned: Int64
    public var agentWorkSeconds: Int64
    public var prsCreated: Int64
    /// Nil until the first counted event (or a stored session to backfill from).
    public var trackingSince: Date?

    public init(agentsSpawned: Int64 = 0, agentWorkSeconds: Int64 = 0, prsCreated: Int64 = 0, trackingSince: Date? = nil) {
        self.agentsSpawned = agentsSpawned
        self.agentWorkSeconds = agentWorkSeconds
        self.prsCreated = prsCreated
        self.trackingSince = trackingSince
    }
}

extension SuijinStore {
    /// Adds `amount` to a counter and starts tracking (now) if it has not started yet. `trackingSince` itself is set
    /// only once and never added to, and a non-positive amount changes nothing.
    public func incrementStat(_ key: StatKey, by amount: Int64 = 1, at date: Date = Date()) throws {
        guard key != .trackingSince, amount > 0 else { return }
        try dbQueue.write { db in
            try Self.startTracking(db, at: date)
            try Self.add(db, key, amount)
        }
    }

    /// Records a pull request Suijin created. The same URL counts once; returns whether it was new.
    @discardableResult
    public func recordPullRequest(url: String, at date: Date = Date()) throws -> Bool {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return false }
        return try dbQueue.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO stat_pr (url, createdAt) VALUES (?, ?)", arguments: [url, date])
            guard db.changesCount > 0 else { return false }
            try Self.startTracking(db, at: date)
            try Self.add(db, .prsCreated, 1)
            return true
        }
    }

    public func suijinStats() throws -> SuijinStats {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM stat_counter")
            var values: [String: Int64] = [:]
            for row in rows { values[row["key"]] = row["value"] }
            return SuijinStats(
                agentsSpawned: values[StatKey.agentsSpawned.rawValue] ?? 0,
                agentWorkSeconds: values[StatKey.agentWorkSeconds.rawValue] ?? 0,
                prsCreated: values[StatKey.prsCreated.rawValue] ?? 0,
                trackingSince: values[StatKey.trackingSince.rawValue].map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
    }

    private static func add(_ db: Database, _ key: StatKey, _ amount: Int64) throws {
        try db.execute(
            sql: "INSERT INTO stat_counter (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = value + excluded.value",
            arguments: [key.rawValue, amount])
    }

    private static func startTracking(_ db: Database, at date: Date) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO stat_counter (key, value) VALUES (?, ?)",
                       arguments: [StatKey.trackingSince.rawValue, Int64(date.timeIntervalSince1970.rounded(.down))])
    }
}
