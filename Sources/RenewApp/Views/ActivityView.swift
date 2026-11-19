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

private struct ActivityLogView: View {
    @ObservedObject var model: AppModel

    @State private var day = Date()
    @State private var events: [ActivityEvent] = []
    @State private var loadError: String?
    @State private var loaded = false
    /// Ignores replies to requests that were superseded.
    @State private var generation = 0
    /// Where the last load stopped in the day's log, so refreshes only
    /// fetch what's new.
    @State private var offset: Int?

    private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActivityNotices(model: model)
            header
            content
        }
        .padding(20)
        .onAppear { load() }
        .onChange(of: day) { _ in events = []; loaded = false; load() }
        .onReceive(refresh) { _ in if isToday { load(incremental: true) } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            DayPickerBar(day: $day)
            Spacer()
            Text(events.count == 1 ? "1 visit" : "\(events.count) visits")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { load(incremental: true) } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
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
        } else {
            List(Array(events.reversed().enumerated()), id: \.offset) { _, e in
                VisitRow(start: e.start, duration: e.duration, title: e.title.isEmpty ? e.host : e.title,
                         url: e.url, browser: e.browser) {
                    if e.blocked { FlagBadge(text: "Blocked", color: .orange) }
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
                    }
                } else {
                    events = page.events
                }
                offset = page.offset
                loadError = nil
            case .failure(let e):
                events = []
                offset = nil
                loadError = model.isInstalled || model.isLocalTest ? e.message : "Install Renew to keep an activity log."
            }
        }
    }
}
