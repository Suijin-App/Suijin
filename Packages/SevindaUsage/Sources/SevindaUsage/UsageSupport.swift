import Foundation

/// A day of the local calendar (the time zone in effect when the record was read), independent of any `Date`.
public struct UsageCalendarDay: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    /// `yyyymmdd`, so ordering and range checks are integer comparisons.
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public init(year: Int, month: Int, day: Int) { rawValue = year * 10_000 + month * 100 + day }

    /// The day that contains `date` in `calendar`.
    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// The local day of a UNIX time in `timeZone`, without going through `Calendar` (called for every record).
    init(epochSeconds: Double, timeZone: TimeZone) {
        let offset = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: epochSeconds)))
        let days = Int(((epochSeconds + offset) / 86_400).rounded(.down))
        let (year, month, day) = CivilDate.fromDays(days)
        self.init(year: year, month: month, day: day)
    }

    public var year: Int { rawValue / 10_000 }
    public var month: Int { rawValue / 100 % 100 }
    public var day: Int { rawValue % 100 }

    /// Start of this day in `calendar`.
    public func date(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    public static func < (lhs: UsageCalendarDay, rhs: UsageCalendarDay) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

/// Proleptic Gregorian conversions between days since 1970-01-01 and (year, month, day) (Howard Hinnant's algorithms).
enum CivilDate {
    static func fromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func toDays(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

/// Parses the ISO 8601 timestamps both CLIs write (`2026-11-12T03:04:05.678Z`, or with a `±hh:mm` offset) into UNIX
/// seconds. Hand-written because `ISO8601DateFormatter` is far too slow for hundreds of thousands of records.
enum ISOTimestamp {
    static func epochSeconds(_ text: String) -> Double? {
        var copy = text
        return copy.withUTF8 { parse(UnsafeRawBufferPointer($0)) }
    }

    static func parse(_ bytes: UnsafeRawBufferPointer) -> Double? {
        var index = 0
        func number(_ width: Int) -> Int? {
            guard index + width <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<width {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
                index += 1
            }
            return value
        }
        func expect(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
        guard let year = number(4), expect(45), let month = number(2), expect(45), let day = number(2),
            index < bytes.count, bytes[index] == 84 || bytes[index] == 32
        else { return nil }
        index += 1
        guard let hour = number(2), expect(58), let minute = number(2), expect(58), let second = number(2),
            (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }
        var fraction = 0.0
        if index < bytes.count, bytes[index] == 46 {
            index += 1
            var scale = 0.1
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        var offsetSeconds = 0
        if index < bytes.count {
            switch bytes[index] {
            case 90, 122:  // Z, z
                index += 1
            case 43, 45:  // +, -
                let sign = bytes[index] == 45 ? -1 : 1
                index += 1
                guard let hours = number(2) else { return nil }
                _ = expect(58)
                guard let minutes = number(2) else { return nil }
                offsetSeconds = sign * (hours * 3_600 + minutes * 60)
            default:
                return nil
            }
        }
        guard index == bytes.count else { return nil }
        let days = CivilDate.toDays(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Double(seconds) + fraction
    }
}

/// 64-bit FNV-1a. Stable across launches (unlike `Hasher`), so hashes can be persisted in the cache.
enum StableHash {
    static let seed: UInt64 = 0xcbf2_9ce4_8422_2325

    static func hash(_ bytes: UnsafeRawBufferPointer, seed: UInt64 = seed) -> UInt64 {
        var value = seed
        for byte in bytes {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return value
    }

    static func hash(_ string: String) -> UInt64 {
        var copy = string
        return copy.withUTF8 { hash(UnsafeRawBufferPointer($0)) }
    }
}

/// The project a working directory belongs to: its folder name, or the repository's name for a worktree.
enum ProjectLabel {
    static func from(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        let components = cwd.split(separator: "/", omittingEmptySubsequences: true)
        // Claude Code worktrees: `<repo>/.claude/worktrees/<name>`.
        if let index = components.lastIndex(of: ".claude"), index > 0, index + 1 < components.count,
            components[index + 1] == "worktrees"
        {
            return String(components[index - 1])
        }
        // Sevinda worktrees: `<parent>/<repo>-worktrees/<branch…>`.
        if let index = components.lastIndex(where: { $0.hasSuffix("-worktrees") && $0.count > "-worktrees".count }),
            index + 1 < components.count
        {
            return String(components[index].dropLast("-worktrees".count))
        }
        return components.last.map(String.init) ?? ""
    }
}
