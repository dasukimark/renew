import SwiftUI
import RenewShared

/// Activity: the record of pages visited, as a dashboard and a log. Flags
/// live on the Accountability page (Monitoring and Flags tabs).
struct ActivityView: View {
    @ObservedObject var model: AppModel

    enum Tab: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case log = "Log"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.activityTab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            .padding(.vertical, 10)
            Divider()
            switch model.activityTab {
            case .dashboard: ActivityDashboardView(model: model)
            case .log: ActivityLogView(model: model)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ActivityToggle(model: model) }
        }
    }
}

// MARK: log

extension ActivityDashboardView.Selection {
    /// Whether a visit was on this site or part of a site.
    func matches(_ e: ActivityEvent) -> Bool {
        switch self {
        case .site(let s): return SiteKey.site(forHost: e.host) == s
        case .section(let s): return SiteSection.section(forHost: e.host, url: e.url) == s
        }
    }
}

private struct ActivityLogView: View {
    @ObservedObject var model: AppModel

    @State private var events: [ActivityEvent] = []
    /// `events` through the filter and search, grouped by hour. Worked out
    /// when one of those changes, not on every redraw (the app's clock
    /// redraws the page every second).
    @State private var hours: [Hour] = []
    @State private var shownCount = 0
    @State private var loadError: String?
    @State private var loaded = false
    /// Ignores replies to requests that were superseded.
    @State private var generation = 0
    /// Where the last load stopped in the day's log, so refreshes only
    /// fetch what's new.
    @State private var offset: Int?

    private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var day: Date { model.activityLogDay }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActivityNotices(model: model)
            header
            content
        }
        .padding(20)
        .onAppear { load() }
        // Opening the log again starts on today with every site, unless the
        // dashboard picks a day and site on the way in.
        .onDisappear {
            model.activityLogDay = Date()
            model.activityLogFilter = nil
        }
        .onChange(of: model.activityLogDay) { _ in events = []; refilter(); loaded = false; load() }
        .onChange(of: model.activityLogSearch) { _ in refilter() }
        .onChange(of: model.activityLogFilter) { _ in refilter() }
        .searchable(text: $model.activityLogSearch, placement: .toolbar, prompt: "Search titles and addresses")
        .onReceive(refresh) { _ in if isToday { load(incremental: true) } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            DayPickerBar(day: $model.activityLogDay)
            if let filter = model.activityLogFilter {
                RemovableChip(text: "Only \(ActivityDashboardView.name(filter))") { model.activityLogFilter = nil }
                    .help("Showing only visits to \(ActivityDashboardView.name(filter)). Click × to show all visits.")
            }
            Spacer()
            Text(countText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { load(incremental: true) } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
        }
    }

    private var search: String { model.activityLogSearch.trimmingCharacters(in: .whitespaces) }
    private var isFiltered: Bool { !search.isEmpty || model.activityLogFilter != nil }

    private var countText: String {
        let n = events.count
        let all = n == 1 ? "1 visit" : "\(n) visits"
        return isFiltered ? "\(shownCount) of \(all)" : all
    }

    /// Visits grouped by the hour they started in, newest hour first.
    private struct Hour: Identifiable {
        let start: Date
        let visits: [ActivityEvent]
        var id: Date { start }
        var seconds: Int { Int(visits.reduce(0) { $0 + $1.duration }.rounded()) }
    }

    /// Works out `hours` from the day's visits, the filter and the search.
    private func refilter() {
        let q = search
        let filter = model.activityLogFilter
        let shown = events.reversed().filter { e in
            if let filter, !filter.matches(e) { return false }
            guard !q.isEmpty else { return true }
            return e.title.localizedCaseInsensitiveContains(q) || e.url.localizedCaseInsensitiveContains(q)
                || e.browser.localizedCaseInsensitiveContains(q)
                || (SiteSection.name(SiteSection.section(forHost: e.host, url: e.url))?.localizedCaseInsensitiveContains(q) ?? false)
        }
        let cal = Calendar.current
        var out: [Hour] = []
        var current: (Date, [ActivityEvent])?
        for v in shown {
            let h = cal.dateInterval(of: .hour, for: v.start)?.start ?? v.start
            if let c = current, c.0 == h {
                current!.1.append(v)
            } else {
                if let c = current { out.append(Hour(start: c.0, visits: c.1)) }
                current = (h, [v])
            }
        }
        if let c = current { out.append(Hour(start: c.0, visits: c.1)) }
        hours = out
        shownCount = shown.count
    }

    private static let hourLabel: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        return f
    }()

    /// What's hiding the day's visits, for the no-matches message.
    private var noMatchText: String {
        let site = model.activityLogFilter.map { ActivityDashboardView.name($0) }
        switch (site, search.isEmpty) {
        case (let site?, true): return "No visits to \(site) on this day."
        case (let site?, false): return "No visits to \(site) on this day match \u{201C}\(search)\u{201D}."
        default: return "No visits on this day match \u{201C}\(search)\u{201D}."
        }
    }

    @ViewBuilder private var content: some View {
        if let loadError {
            Spacer()
            Text(loadError)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            Spacer()
        } else if events.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.secondary)
                Text(loaded ? "No visits recorded on this day." : "Loading…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        } else if hours.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                Text(noMatchText).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Show All Visits") {
                    model.activityLogSearch = ""
                    model.activityLogFilter = nil
                }
            }
            .frame(maxWidth: .infinity)
            Spacer()
        } else {
            List {
                ForEach(hours) { hour in
                    Section {
                        ForEach(Array(hour.visits.enumerated()), id: \.offset) { _, e in
                            VisitRow(start: e.start, duration: e.duration, title: e.title.isEmpty ? e.host : e.title,
                                     url: e.url, browser: e.browser) {
                                if e.blocked { FlagBadge(text: "Blocked", color: .orange) }
                            }
                        }
                    } header: {
                        HStack {
                            Text(Self.hourLabel.string(from: hour.start))
                            Spacer()
                            Text("\(hour.visits.count == 1 ? "1 visit" : "\(hour.visits.count) visits") · \(DurationText.hoursMinutes(hour.seconds))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    /// The whole day, or with `incremental` only visits added since the last load.
    private func load(incremental: Bool = false) {
        generation += 1
        let mine = generation
        let from = incremental && loaded && loadError == nil ? offset : nil
        model.loadActivity(day: day, fromOffset: from) { result in
            guard mine == generation else { return }
            loaded = true
            switch result {
            case .success(let page):
                if page.isIncremental && from != nil {
                    if !page.events.isEmpty {
                        // Visits are logged when they end, so a new one can start earlier.
                        events = Array((events + page.events).sorted { $0.start < $1.start }
                            .suffix(ActivityLogStore.maxQueryResults))
                        refilter()
                    }
                } else {
                    events = page.events
                    refilter()
                }
                offset = page.offset
                loadError = nil
            case .failure(let e):
                events = []
                refilter()
                offset = nil
                loadError = model.isInstalled || model.isLocalTest ? e.message : "Install Renew to keep an activity log."
            }
        }
    }
}
