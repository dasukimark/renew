import Charts
import SwiftUI
import RenewShared

/// Time per site: daily totals and averages over a range of days.
struct ActivityDashboardView: View {
    @ObservedObject var model: AppModel

    enum Range: Int, CaseIterable, Identifiable {
        case today = 1, week = 7, month = 30, year = 365
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .today: return "Today"
            case .week: return "7 days"
            case .month: return "30 days"
            case .year: return "1 year"
            }
        }
    }

    @State private var range: Range = .week
    @State private var report: ActivityStatsReport?
    /// Bumped with each new report, so the dashboard body only redraws when
    /// the data changes (not on every tick of the app's clock).
    @State private var reportID = 0
    @State private var loadError: String?
    /// The last refresh failed; the data shown is from before it.
    @State private var refreshError: String?
    /// The site the chart and tiles are showing, or nil for all sites.
    @State private var selected: String?
    /// Ignores replies to requests that were superseded.
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ActivityNotices(model: model)
            header
            content
        }
        .padding(20)
        .onChange(of: range) { _ in report = nil; loadError = nil; refreshError = nil }
        // A task, not a Timer stored on the view: the view is rebuilt every
        // second as the app's clock ticks, which would restart a timer.
        .task(id: range) {
            while !Task.isCancelled {
                load()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            if let selected {
                Button {
                    self.selected = nil
                } label: {
                    Label(Self.siteName(selected), systemImage: "xmark.circle.fill")
                }
                .help("Show all sites")
            }
            Spacer()
            if let refreshError {
                Label("Couldn't refresh", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(refreshError)
            }
            Button { load() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
        }
    }

    @ViewBuilder private var content: some View {
        if let report {
            if report.isEmpty {
                placeholder(range == .today ? "No time on websites recorded today." : "No time on websites recorded in this range.",
                            icon: "chart.bar")
            } else {
                DashboardBody(report: report, reportID: reportID, range: range, selected: selected,
                              select: { site in selected = selected == site ? nil : site })
                    .equatable()
            }
        } else if let loadError {
            placeholder(loadError, icon: "chart.bar")
        } else {
            placeholder("Loading…", icon: "chart.bar")
        }
    }

    private func placeholder(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: loading

    private func load() {
        generation += 1
        let mine = generation
        // The selected site is always kept in the reply, never folded into "Other sites".
        let query = ActivityStatsQuery(lastDays: range.rawValue, site: selected)
        model.loadActivityStats(query) { result in
            guard mine == generation else { return }
            switch result {
            case .success(let summaries):
                let r = ActivityStatsReport(query: query, summaries: summaries)
                report = r
                reportID += 1
                loadError = nil
                refreshError = nil
                if let s = selected, r.site(s) == nil { selected = nil }
            case .failure(let e):
                let message = model.isInstalled || model.isLocalTest ? e.message : "Install Renew to keep an activity log."
                // Keep what's on screen if a refresh fails; it's still right.
                if report == nil { loadError = message } else { refreshError = message }
            }
        }
    }

    // MARK: formatting

    static func siteName(_ site: String) -> String { site == DaySummary.otherSite ? "Other sites" : site }

    static func duration(_ seconds: Int) -> String { DurationText.hoursMinutes(seconds) }

    static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    /// Round y-axis ticks (in seconds) covering `max`, at most about five.
    static func ticks(max: Int) -> [Int] {
        let steps = [1, 2, 5, 10, 15, 30, 60, 120, 180, 240, 360, 480, 720].map { $0 * 60 }
        let step = steps.first { max <= $0 * 4 } ?? 1_440 * 60
        let top = Swift.max(step, Int((Double(max) / Double(step)).rounded(.up)) * step)
        return Array(stride(from: 0, through: top, by: step))
    }

    static func axisLabel(_ seconds: Int) -> String {
        if seconds == 0 { return "0" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h \(seconds % 3_600 / 60)m" }
        return "\(seconds / 60)m"
    }
}

/// Tiles, chart and site table for one report. Equatable on its inputs, so
/// it isn't rebuilt every second when the app's clock ticks.
private struct DashboardBody: View, Equatable {
    let report: ActivityStatsReport
    let reportID: Int
    let range: ActivityDashboardView.Range
    let selected: String?
    let select: (String) -> Void

    /// The day under the pointer in the chart.
    @State private var hovered: String?

    static func == (a: Self, b: Self) -> Bool {
        a.reportID == b.reportID && a.range == b.range && a.selected == b.selected
    }

    var body: some View {
        let r = report
        VStack(alignment: .leading, spacing: 14) {
            tiles(r)
            if range != .today { chartCard(r) }
            siteTable(r)
        }
    }

    // MARK: tiles

    private func tiles(_ r: ActivityStatsReport) -> some View {
        HStack(spacing: 12) {
            if let selected, let site = r.site(selected) {
                StatTile(title: "Time on \(ActivityDashboardView.siteName(selected))", value: ActivityDashboardView.duration(site.totalSeconds))
                if range == .today {
                    StatTile(title: "Share of time", value: site.share.formatted(.percent.precision(.fractionLength(0))))
                } else {
                    StatTile(title: "Daily average", value: ActivityDashboardView.duration(Int(site.dailyAverage.rounded())))
                    StatTile(title: "Share of time", value: site.share.formatted(.percent.precision(.fractionLength(0))))
                }
            } else {
                StatTile(title: "Time on websites", value: ActivityDashboardView.duration(r.totalSeconds))
                if range == .today {
                    StatTile(title: "Sites visited", value: "\(r.sites.count)")
                } else {
                    StatTile(title: "Daily average", value: ActivityDashboardView.duration(Int(r.dailyAverage.rounded())))
                }
                StatTile(title: "Top site", value: r.topSite.map { ActivityDashboardView.siteName($0.site) } ?? "—")
            }
        }
    }

    // MARK: chart

    private func chartCard(_ r: ActivityStatsReport) -> some View {
        let days = selected.map { r.days(for: $0) } ?? r.days
        let average = selected.flatMap { r.site($0)?.dailyAverage } ?? r.dailyAverage
        let ticks = ActivityDashboardView.ticks(max: max(days.map(\.seconds).max() ?? 0, Int(average)))
        let readout = hovered.flatMap { key in days.first { $0.day == key } }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selected.map { "Time on \(ActivityDashboardView.siteName($0)) per day" } ?? "Time on websites per day")
                    .font(.headline)
                Spacer()
                Text(readout.map { "\(ActivityDashboardView.dayLabel.string(from: $0.date)): \(ActivityDashboardView.duration($0.seconds))" }
                     ?? "Average \(ActivityDashboardView.duration(Int(average.rounded()))) a day")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Chart {
                ForEach(days, id: \.day) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Time", d.seconds))
                        .cornerRadius(range == .year ? 1 : 4)
                        .foregroundStyle(Color.accentColor.opacity(hovered == nil || hovered == d.day ? 1 : 0.45))
                }
                if r.averageDays > 0 {
                    RuleMark(y: .value("Average", average))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartYScale(domain: 0...(ticks.last ?? 60))
            .chartYAxis {
                AxisMarks(position: .leading, values: ticks) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel {
                        if let s = value.as(Int.self) { Text(ActivityDashboardView.axisLabel(s)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: range == .week ? 7 : 6)) { _ in
                    AxisValueLabel(format: range == .year ? .dateTime.month(.abbreviated) : .dateTime.day().month(.abbreviated))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                let x = point.x - geo[proxy.plotAreaFrame].origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    let key = ActivityLogStore.dayKey(date)
                                    hovered = days.contains { $0.day == key } ? key : nil
                                } else {
                                    hovered = nil
                                }
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 190)
            Text("Averages count every day from the first one with recorded activity in this range, including today and days with none.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: site table

    private func siteTable(_ r: ActivityStatsReport) -> some View {
        let top = r.sites.first?.totalSeconds ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Site").frame(maxWidth: .infinity, alignment: .leading)
                Text("Total").frame(width: 90, alignment: .trailing)
                if range != .today { Text("Avg / day").frame(width: 90, alignment: .trailing) }
                Text("Share").frame(width: 56, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)

            List(r.sites, id: \.site) { s in
                SiteRow(site: s, name: ActivityDashboardView.siteName(s.site), top: top, showAverage: range != .today,
                        isSelected: selected == s.site)
                    .contentShape(Rectangle())
                    .onTapGesture { select(s.site) }
                    .listRowBackground(selected == s.site ? Color.accentColor.opacity(0.15) : Color.clear)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

}

private struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SiteRow: View {
    let site: ActivityStatsReport.Site
    let name: String
    let top: Int
    let showAverage: Bool
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: max(2, geo.size.width * CGFloat(site.totalSeconds) / CGFloat(max(1, top))))
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(ActivityDashboardView.duration(site.totalSeconds))
                .frame(width: 90, alignment: .trailing)
            if showAverage {
                Text(ActivityDashboardView.duration(Int(site.dailyAverage.rounded())))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
            }
            Text(site.share.formatted(.percent.precision(.fractionLength(0))))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.vertical, 3)
        .help("Click to show only \(name)")
    }
}
