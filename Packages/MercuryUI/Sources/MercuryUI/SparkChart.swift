import Charts
import SwiftUI

/// A data series for a line chart (CPU, RAM, network…).
public struct SparkSeries: Identifiable {
    public let id: String
    public let label: LocalizedStringResource
    public let tone: StatusTone
    public let values: [Double]

    public init(id: String, label: LocalizedStringResource, tone: StatusTone, values: [Double]) {
        self.id = id
        self.label = label
        self.tone = tone
        self.values = values
    }
}

/// Compact Swift Charts line chart for metric cards, with a fixed Y axis of 0…`maxValue` and the native
/// chart legend under it when `showsLegend` is set.
public struct SparkChart: View {
    let series: [SparkSeries]
    let maxValue: Double
    let showsLegend: Bool

    public init(_ series: [SparkSeries], maxValue: Double = 100, showsLegend: Bool = false) {
        self.series = series
        self.maxValue = maxValue
        self.showsLegend = showsLegend
    }

    public var body: some View {
        let names = series.map { String(localized: $0.label) }
        Chart {
            ForEach(Array(series.enumerated()), id: \.element.id) { offset, s in
                ForEach(Array(s.values.enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value(Text(verbatim: "t"), index), y: .value(Text(verbatim: "v"), value))
                        .foregroundStyle(by: .value(Text(verbatim: "series"), names[offset]))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartForegroundStyleScale(domain: names, range: series.map(\.tone.color))
        .chartLegend(showsLegend ? .visible : .hidden)
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXAxis(.hidden)
        .chartYScale(domain: 0...maxValue)
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine() } }
        .frame(height: showsLegend ? 140 : 120)
        .accessibilityHidden(true)
    }
}
