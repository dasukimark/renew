import Charts
import SwiftUI
import RenewShared

/// Time per site: daily totals and averages over a range of days, with each
/// site broken into its parts (Gmail and Google Docs under google.com).
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
        /// Finishes "Time on websites …".
        var phrase: String {
            switch self {
            case .today: return "today"
            case .week: return "in the last 7 days"
            case .month: return "in the last 30 days"
            case .year: return "in the past year"
            }
        }
    }

    /// What the chart and summary show: one site, or one part of a site.
    enum Selection: Hashable {
        case site(String)
        case section(String)

        /// The site to keep in the reply, so it's never folded into "Other sites".
        var site: String {
            switch self {
            case .site(let s): return s
            case .section(let s): return SiteSection.site(of: s)
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
    /// What the chart and summary are showing, or nil for all sites.
    @State private var selection: Selection?
    /// Ignores replies to requests that were superseded.
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                ActivityNotices(model: model)
                header
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            content
        }
        .onChange(of: range) { _ in report = nil; loadError = nil; refreshError = nil }
        // A task, not a Timer stored on the view: the view is rebuilt every
        // second as the app's clock ticks, which would restart a timer.
        // Not on selection changes: a selected site or part is always in the
        // report already (and kept in it from then on, see `load`).
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
                placeholder(range == .today ? "No time on websites recorded today." : "No time on websites recorded \(range.phrase).",
                            icon: "chart.bar")
            } else {
                ScrollView {
                    DashboardBody(report: report, reportID: reportID, range: range, selection: selection,
                                  select: { selection = $0 },
                                  showInLog: { target, day in
                                      model.activityLogFilter = target
                                      model.activityLogDay = day
                                      model.activityLogSearch = ""
                                      model.activityTab = .log
                                  })
                        .equatable()
                        .padding([.horizontal, .bottom], 20)
                }
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
        .padding(20)
    }

    // MARK: loading

    private func load() {
        generation += 1
        let mine = generation
        let query = ActivityStatsQuery(lastDays: range.rawValue, site: selection?.site)
        model.loadActivityStats(query) { result in
            guard mine == generation else { return }
            switch result {
            case .success(let summaries):
                let r = ActivityStatsReport(query: query, summaries: summaries)
                report = r
                reportID += 1
                loadError = nil
                refreshError = nil
                switch selection {
                case .site(let s)? where r.site(s) == nil: selection = nil
                case .section(let s)? where r.section(s) == nil: selection = nil
                default: break
                }
            case .failure(let e):
                let message = model.isInstalled || model.isLocalTest ? e.message : "Install Renew to keep an activity log."
                // Keep what's on screen if a refresh fails; it's still right.
                if report == nil { loadError = message } else { refreshError = message }
            }
        }
    }

    // MARK: formatting

    static func siteName(_ site: String) -> String { site == DaySummary.otherSite ? "Other sites" : site }

    /// "Gmail", or the host when the part has no everyday name.
    static func sectionName(_ section: String) -> String { SiteSection.name(section) ?? section }

    static func name(_ selection: Selection) -> String {
        switch selection {
        case .site(let s): return siteName(s)
        case .section(let s): return sectionName(s)
        }
    }

    static func duration(_ seconds: Int) -> String { DurationText.hoursMinutes(seconds) }

    static func percent(_ share: Double) -> String { share.formatted(.percent.precision(.fractionLength(0))) }

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

    static let averageHelp = "Averages count every day from the first one with recorded activity in this range, including today and days with none."
}

/// Summary, chart and site table for one report. Equatable on its inputs, so
/// it isn't rebuilt every second when the app's clock ticks.
private struct DashboardBody: View, Equatable {
    typealias Selection = ActivityDashboardView.Selection
    typealias D = ActivityDashboardView

    let report: ActivityStatsReport
    let reportID: Int
    let range: ActivityDashboardView.Range
    let selection: Selection?
    let select: (Selection?) -> Void
    /// Opens the log on a day's visits to a site or part.
    let showInLog: (Selection, Date) -> Void

    /// The day under the pointer in the chart.
    @State private var hovered: String?
    /// Sites whose parts are showing.
    @State private var expanded: Set<String> = []

    static func == (a: Self, b: Self) -> Bool {
        a.reportID == b.reportID && a.range == b.range && a.selection == b.selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            overview(report)
            sites(report)
        }
        .onAppear {
            // Open the site of a selected part, so the selection is visible.
            if case .section(let s)? = selection { expanded.insert(SiteSection.site(of: s)) }
        }
    }

    // MARK: overview

    private func overview(_ r: ActivityStatsReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(selection.map { "Time on \(D.name($0)) \(range.phrase)" } ?? "Time on websites \(range.phrase)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if selection != nil {
                            Button { select(nil) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Show all sites")
                        }
                    }
                    Text(D.duration(selectedTotal(r)))
                        .font(.system(size: 30, weight: .semibold))
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                ForEach(facts(r), id: \.label) { f in
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(f.label).font(.caption).foregroundStyle(.secondary)
                        Text(f.value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(1)
                    }
                    .help(f.help ?? "")
                }
            }
            if range != .today { chart(r) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private struct Fact {
        let label: String
        let value: String
        var help: String?
    }

    private func selectedTotal(_ r: ActivityStatsReport) -> Int {
        switch selection {
        case .site(let s)?: return r.site(s)?.totalSeconds ?? 0
        case .section(let s)?: return r.section(s)?.totalSeconds ?? 0
        case nil: return r.totalSeconds
        }
    }

    private func facts(_ r: ActivityStatsReport) -> [Fact] {
        let avg = { (v: Double) in Fact(label: "Daily average", value: D.duration(Int(v.rounded())), help: D.averageHelp) }
        switch selection {
        case .site(let s)?:
            guard let site = r.site(s) else { return [] }
            var out = [Fact(label: "Share of time", value: D.percent(site.share))]
            if range != .today { out.insert(avg(site.dailyAverage), at: 0) }
            if site.hasBreakdown, let top = site.topPart {
                out.append(Fact(label: "Most used part", value: D.sectionName(top.section)))
            }
            return out
        case .section(let s)?:
            guard let section = r.section(s), let site = r.site(SiteSection.site(of: s)) else { return [] }
            var out = [Fact(label: "Of \(site.site)", value: D.percent(section.share),
                            help: "Share of the time on \(site.site). A visit that overlaps another part of the site counts in both.")]
            if range != .today { out.insert(avg(section.dailyAverage), at: 0) }
            return out
        case nil:
            var out = [Fact(label: "Top site", value: r.topSite.map { D.siteName($0.site) } ?? "—")]
            out.insert(range == .today ? Fact(label: "Sites visited", value: siteCount(r)) : avg(r.dailyAverage), at: 0)
            return out
        }
    }

    // MARK: chart

    private func chart(_ r: ActivityStatsReport) -> some View {
        let days: [ActivityStatsReport.Day]
        let average: Double
        switch selection {
        case .site(let s)?: days = r.days(for: s); average = r.site(s)?.dailyAverage ?? 0
        case .section(let s)?: days = r.days(forSection: s); average = r.section(s)?.dailyAverage ?? 0
        case nil: days = r.days; average = r.dailyAverage
        }
        let ticks = D.ticks(max: max(days.map(\.seconds).max() ?? 0, Int(average)))
        let readout = hovered.flatMap { key in days.first { $0.day == key } }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Spacer()
                if let readout {
                    Text("\(D.dayLabel.string(from: readout.date))  \(D.duration(readout.seconds))")
                } else if r.averageDays > 0 {
                    Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 18, y: 1)) }
                        .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: 18, height: 2)
                    Text("Average \(D.duration(Int(average.rounded()))) a day")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(height: 18)
            .help(D.averageHelp)

            Chart {
                ForEach(days, id: \.day) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Time", d.seconds))
                        .cornerRadius(range == .year ? 1 : 4)
                        .foregroundStyle(Color.accentColor.opacity(hovered == nil || hovered == d.day ? 1 : 0.4))
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
                        if let s = value.as(Int.self) { Text(D.axisLabel(s)) }
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
            .frame(height: 170)
        }
    }

    // MARK: sites

    private func sites(_ r: ActivityStatsReport) -> some View {
        let top = r.sites.first?.totalSeconds ?? 1
        let showAverage = range != .today
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sites").font(.headline)
                Text(siteCount(r))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(r.site(DaySummary.otherSite) == nil ? ""
                          : "The sites with the least time are added up under Other sites, so more were visited than are listed.")
                Spacer()
                if r.sites.contains(where: \.hasBreakdown) {
                    Button(allExpanded(r) ? "Collapse All" : "Expand All") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            expanded = allExpanded(r) ? [] : Set(r.sites.filter(\.hasBreakdown).map(\.site))
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }

            VStack(spacing: 0) {
                ColumnHeader(showAverage: showAverage)
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(Array(r.sites.enumerated()), id: \.element.site) { i, s in
                        if i > 0 { Divider().padding(.leading, 12) }
                        SiteRow(site: s, top: top, showAverage: showAverage,
                                isSelected: selection == .site(s.site),
                                isExpanded: expanded.contains(s.site),
                                toggle: { toggle(s.site) },
                                select: { select(selection == .site(s.site) ? nil : .site(s.site)) },
                                logDay: s.site == DaySummary.otherSite ? nil : logDay(r.days(for: s.site)),
                                showInLog: { day in showInLog(.site(s.site), day) })
                        if expanded.contains(s.site) {
                            ForEach(s.sections, id: \.section) { sec in
                                SectionRow(section: sec, site: s, top: top, showAverage: showAverage,
                                           isSelected: selection == .section(sec.section),
                                           select: { select(selection == .section(sec.section) ? nil : .section(sec.section)) },
                                           logDay: SiteSection.isOtherParts(sec.section) ? nil : logDay(r.days(forSection: sec.section)),
                                           showInLog: { day in showInLog(.section(sec.section), day) })
                            }
                            .transition(.opacity)
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))

            if let note = partsNote(r) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Sites listed, with a "+" when the rest are folded into Other sites.
    private func siteCount(_ r: ActivityStatsReport) -> String {
        let n = r.sites.filter { $0.site != DaySummary.otherSite }.count
        return r.site(DaySummary.otherSite) == nil ? "\(n)" : "\(n)+"
    }

    /// The last day in `days` with any time, if its visits are still kept.
    private func logDay(_ days: [ActivityStatsReport.Day]) -> Date? {
        guard let last = days.last(where: { $0.seconds > 0 })?.date else { return nil }
        let oldest = Calendar.current.date(byAdding: .day, value: -(ActivityLogStore.retentionDays - 1),
                                           to: Calendar.current.startOfDay(for: Date())) ?? .distantPast
        return last >= oldest ? last : nil
    }

    private func partsNote(_ r: ActivityStatsReport) -> String? {
        switch r.partsCoverage {
        case .all: return nil
        case .some: return "Some days in this range were recorded before Renew split sites into parts like Gmail and Google Docs. They count towards each site's total, but not towards its parts."
        case .none: return "Sites in this range aren't split into parts like Gmail and Google Docs: the days were recorded before Renew kept parts, or the background service needs updating."
        }
    }

    private func allExpanded(_ r: ActivityStatsReport) -> Bool {
        r.sites.filter(\.hasBreakdown).allSatisfy { expanded.contains($0.site) }
    }

    private func toggle(_ site: String) {
        withAnimation(.easeOut(duration: 0.18)) {
            if expanded.contains(site) { expanded.remove(site) } else { expanded.insert(site) }
        }
    }
}

// MARK: table rows

/// "Show Today's Visits in Log", or the last day with any.
private func logMenuTitle(_ day: Date) -> String {
    if Calendar.current.isDateInToday(day) { return "Show Today's Visits in Log" }
    if Calendar.current.isDateInYesterday(day) { return "Show Yesterday's Visits in Log" }
    return "Show Visits on \(ActivityDashboardView.dayLabel.string(from: day)) in Log"
}

private enum Column {
    static let disclosure: CGFloat = 18
    static let total: CGFloat = 80
    static let average: CGFloat = 80
    static let share: CGFloat = 52
}

private struct ColumnHeader: View {
    let showAverage: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Site").padding(.leading, Column.disclosure + 8).frame(maxWidth: .infinity, alignment: .leading)
            Text("Total").frame(width: Column.total, alignment: .trailing)
            if showAverage { Text("Avg / day").frame(width: Column.average, alignment: .trailing) }
            Text("Share").frame(width: Column.share, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// A bar for a row's time, against the site with the most time.
private struct TimeBar: View {
    let seconds: Int
    let top: Int
    var opacity: Double = 0.75

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.accentColor.opacity(opacity))
                .frame(width: max(2, geo.size.width * CGFloat(seconds) / CGFloat(max(1, top))))
        }
        .frame(height: 4)
    }
}

/// A row's background: the selection, else a hover highlight.
private struct RowBackground: ViewModifier {
    let isSelected: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(isSelected ? Color.accentColor.opacity(0.16) : hovering ? Color.secondary.opacity(0.07) : Color.clear)
            .onHover { hovering = $0 }
    }
}

private struct SiteRow: View {
    let site: ActivityStatsReport.Site
    let top: Int
    let showAverage: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    let select: () -> Void
    /// The day "Show in Log" opens, or nil if there's none to show.
    let logDay: Date?
    let showInLog: (Date) -> Void

    private var name: String { ActivityDashboardView.siteName(site.site) }

    /// The biggest parts, for a collapsed row: "Gmail, Google Docs +2".
    private var partsPreview: String? {
        guard site.hasBreakdown, !isExpanded else { return nil }
        // The site's own pages (youtube.com under youtube.com) go without saying.
        let others = site.sections.filter { $0.section != site.site && !SiteSection.isOtherParts($0.section) }
        let names = others.prefix(2).map { ActivityDashboardView.sectionName($0.section) }
        let more = others.count - names.count
        return names.joined(separator: ", ") + (more > 0 ? " +\(more)" : "")
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if site.hasBreakdown {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: Column.disclosure, height: Column.disclosure)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide the parts of \(name)" : "Show the parts of \(name)")
                } else {
                    Color.clear
                }
            }
            .frame(width: Column.disclosure)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(name)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(site.site == DaySummary.otherSite ? .secondary : .primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let partsPreview {
                        Text(partsPreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                TimeBar(seconds: site.totalSeconds, top: top)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(ActivityDashboardView.duration(site.totalSeconds))
                .frame(width: Column.total, alignment: .trailing)
            if showAverage {
                Text(ActivityDashboardView.duration(Int(site.dailyAverage.rounded())))
                    .foregroundStyle(.secondary)
                    .frame(width: Column.average, alignment: .trailing)
            }
            Text(ActivityDashboardView.percent(site.share))
                .foregroundStyle(.secondary)
                .frame(width: Column.share, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .modifier(RowBackground(isSelected: isSelected))
        .onTapGesture(perform: select)
        .help(isSelected ? "Click to show all sites" : "Click to chart only \(name)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: isExpanded ? "Hide parts" : "Show parts") { if site.hasBreakdown { toggle() } }
        .contextMenu {
            Button(isSelected ? "Show All Sites" : "Chart Only \(name)", action: select)
            if site.hasBreakdown { Button(isExpanded ? "Hide Parts" : "Show Parts", action: toggle) }
            if let logDay { Button(logMenuTitle(logDay)) { showInLog(logDay) } }
        }
    }
}

/// One part of a site (Gmail under google.com), indented under it.
private struct SectionRow: View {
    let section: ActivityStatsReport.Section
    let site: ActivityStatsReport.Site
    let top: Int
    let showAverage: Bool
    let isSelected: Bool
    let select: () -> Void
    let logDay: Date?
    let showInLog: (Date) -> Void

    private var friendly: String? { SiteSection.name(section.section) }
    private var name: String { friendly ?? section.section }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(name)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if friendly != nil && !SiteSection.isOtherParts(section.section) {
                        Text(section.section)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                TimeBar(seconds: section.totalSeconds, top: top, opacity: 0.4)
            }
            .padding(.leading, Column.disclosure + 8 + 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(ActivityDashboardView.duration(section.totalSeconds))
                .frame(width: Column.total, alignment: .trailing)
            if showAverage {
                Text(ActivityDashboardView.duration(Int(section.dailyAverage.rounded())))
                    .foregroundStyle(.secondary)
                    .frame(width: Column.average, alignment: .trailing)
            }
            Text(ActivityDashboardView.percent(site.share * section.share))
                .foregroundStyle(.secondary)
                .frame(width: Column.share, alignment: .trailing)
                .help("\(ActivityDashboardView.percent(section.share)) of \(site.site)")
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.035))
        .contentShape(Rectangle())
        .modifier(RowBackground(isSelected: isSelected))
        .onTapGesture(perform: select)
        .help(isSelected ? "Click to show all sites" : "Click to chart only \(name)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button(isSelected ? "Show All Sites" : "Chart Only \(name)", action: select)
            if let logDay { Button(logMenuTitle(logDay)) { showInLog(logDay) } }
        }
    }
}
