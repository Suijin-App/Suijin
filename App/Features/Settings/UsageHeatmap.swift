import Charts
import SevindaUI
import SevindaUsage
import SwiftUI

/// One day of the heatmap: its column (week, oldest first), its row (weekday from the calendar's first weekday) and
/// an intensity level 0…4.
struct UsageHeatmapCell: Identifiable, Hashable {
    let day: UsageCalendarDay
    let date: Date
    let week: Int
    let weekday: Int
    let tokens: Int
    let level: Int

    var id: Int { day.rawValue }
}

/// The last `weeks` calendar weeks up to today, one cell per day that has already begun (later days of this week are
/// left out, as a contribution graph does).
struct UsageHeatmapModel: Equatable {
    static let weeks = 6

    let cells: [UsageHeatmapCell]
    /// The first day shown (start of the oldest week).
    let start: Date
    let today: Date

    init(daily: [UsageDailyTotal], now: Date = Date(), calendar: Calendar = .current) {
        self.init(totals: Dictionary(daily.map { ($0.day, $0.tokens.total) }, uniquingKeysWith: +),
                  now: now, calendar: calendar)
    }

    /// `totals` holds the tokens per local day; days outside the six weeks are ignored.
    init(totals: [UsageCalendarDay: Int], now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let start = Self.start(now: now, calendar: calendar)

        var days: [(UsageCalendarDay, Date, Int)] = []
        var date = start
        var index = 0
        while date <= today, index < Self.weeks * 7 {
            let day = UsageCalendarDay(date, calendar: calendar)
            days.append((day, date, index))
            index += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        let peak = days.map { totals[$0.0] ?? 0 }.max() ?? 0
        cells = days.map { day, date, index in
            let tokens = totals[day] ?? 0
            return UsageHeatmapCell(
                day: day, date: date, week: index / 7, weekday: index % 7, tokens: tokens,
                level: Self.level(tokens, peak: peak))
        }
        self.start = start
        self.today = today
    }

    /// The first day shown: the start of the week `weeks - 1` weeks before the one containing `now`.
    static func start(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek
    }

    /// 0 for an idle day, otherwise 1…4 on a square-root scale of the busiest day shown, so one huge day does not
    /// wash every other active day out to the lowest step.
    static func level(_ tokens: Int, peak: Int) -> Int {
        guard tokens > 0, peak > 0 else { return 0 }
        let ratio = (Double(tokens) / Double(peak)).squareRoot()
        return min(4, max(1, Int((ratio * 4).rounded(.up))))
    }

    var activeDays: Int { cells.filter { $0.tokens > 0 }.count }
}

/// Settings → Stats & Usage → Daily intensity: a 7 × 6 grid of the last six weeks drawn with Swift Charts, first and
/// last dates below it and a Less → More legend.
struct UsageHeatmap: View {
    let model: UsageHeatmapModel
    let bestDay: UsageDailyTotal?

    private static let cellSize: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: MercurySpacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: MercurySpacing.s) {
                Text("Daily intensity").font(.headline)
                Spacer(minLength: MercurySpacing.s)
                if let bestDay, bestDay.tokens.total > 0 {
                    Text("Best: \(UsageFormat.day(bestDay.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, MercurySpacing.s)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .help(Text("\(UsageFormat.tokens(bestDay.tokens.total)) tokens"))
                }
            }
            Text("Token activity over the last six weeks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(alignment: .top, spacing: MercurySpacing.s) {
                weekdayLabels
                VStack(alignment: .leading, spacing: MercurySpacing.xs) {
                    chart
                    HStack {
                        Text(verbatim: UsageFormat.day(model.start))
                        Spacer(minLength: MercurySpacing.xs)
                        Text(verbatim: UsageFormat.day(model.today))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Self.plotWidth)
                    .accessibilityHidden(true)
                }
            }
            HStack(spacing: MercurySpacing.xs) {
                Text("Less")
                ForEach(0...4, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.color(level))
                        .frame(width: 10, height: 10)
                }
                Text("More")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityHidden(true)
        }
    }

    private static var plotWidth: CGFloat { cellSize * CGFloat(UsageHeatmapModel.weeks) }

    /// Every other weekday name beside its row.
    private var weekdayLabels: some View {
        let weekdays = Self.weekdaySymbols()
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<7, id: \.self) { row in
                Text(verbatim: row.isMultiple(of: 2) ? weekdays[row] : "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: Self.cellSize)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    /// Rows top to bottom from the first weekday: row `r` spans y `6 - r ... 7 - r` on a 0…7 scale.
    private var chart: some View {
        Chart(model.cells) { cell in
            RectangleMark(
                xStart: .value("Week", Double(cell.week) + 0.08), xEnd: .value("Week", Double(cell.week) + 0.92),
                yStart: .value("Weekday", Double(6 - cell.weekday) + 0.08),
                yEnd: .value("Weekday", Double(6 - cell.weekday) + 0.92))
            .cornerRadius(3)
            .foregroundStyle(Self.color(cell.level))
        }
        .chartXScale(domain: 0...Double(UsageHeatmapModel.weeks))
        .chartYScale(domain: 0...7.0)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(width: Self.plotWidth, height: Self.cellSize * 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Daily token activity, last six weeks"))
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: Text {
        let active = Text("Active on \(model.activeDays) of \(model.cells.count) days.")
        guard let bestDay, bestDay.tokens.total > 0 else { return active }
        return Text("\(active) Busiest day \(UsageFormat.day(bestDay.date)), \(UsageFormat.tokens(bestDay.tokens.total)) tokens.")
    }

    /// Short weekday names in row order, starting from the calendar's first weekday.
    private static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }

    /// The fill for an intensity level: a neutral fill when idle, then the accent color in rising opacity.
    static func color(_ level: Int) -> Color {
        switch level {
        case 0: Color.secondary.opacity(0.18)
        case 1: Color.accentColor.opacity(0.25)
        case 2: Color.accentColor.opacity(0.45)
        case 3: Color.accentColor.opacity(0.7)
        default: Color.accentColor
        }
    }
}
