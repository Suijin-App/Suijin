import Foundation

/// Number formatting for Settings → Stats & Usage, through Foundation formatters so it follows the user's locale.
/// `locale` is a parameter only so tests can pin it.
enum UsageFormat {
    /// Compact token counts: 950, 12.4K, 119.2M, 18.3B.
    static func tokens(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
    }

    /// An exact count with grouping: 12,345.
    static func count(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.locale(locale))
    }

    /// An estimated cost in US dollars ($8,397.48), or "n/a" when nothing in range has a known price.
    static func cost(_ value: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let value else { return String(localized: "n/a") }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
    }

    /// A share as a whole percentage (42%), or "n/a" when there is nothing to divide. A share just short of all of it
    /// reads ">99%" rather than rounding up to a 100% that is not true.
    static func percent(_ value: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let value else { return String(localized: "n/a") }
        if value >= 0.995, value < 1 { return ">" + (0.99).formatted(.percent.precision(.fractionLength(0)).locale(locale)) }
        return value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// A share of a whole for a legend: like `percent`, but a share too small to round to 1% reads "<1%".
    static func share(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard value > 0, value < 0.005 else { return percent(value, locale: locale) }
        return "<" + percent(0.01, locale: locale)
    }

    /// A long duration in its two largest units: "69d 9h", "3h 12m", "12m"; under a minute reads "0m".
    static func duration(seconds: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        let clamped = TimeInterval(max(0, seconds))
        // `.dropAll` turns zero into an empty string; show zero minutes instead.
        guard clamped >= 60 else {
            formatter.zeroFormattingBehavior = .default
            formatter.allowedUnits = [.minute]
            return formatter.string(from: 0) ?? "0m"
        }
        // The formatter rounds the last unit; truncate first so 69d 9h 59m reads "69d 9h", never more than worked.
        let step: TimeInterval = clamped >= 86_400 ? 3_600 : 60
        return formatter.string(from: (clamped / step).rounded(.down) * step) ?? ""
    }

    /// A short day label: "Nov 3".
    static func day(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }

    /// When usage was last read: the time for today ("2:14 PM"), the day and time otherwise ("Nov 3, 2:14 PM").
    static func updated(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                        locale: Locale = .autoupdatingCurrent) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute().locale(locale))
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))
    }
}
