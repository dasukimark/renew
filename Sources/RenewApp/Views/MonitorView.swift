import SwiftUI
import RenewShared

/// The Monitor: reads recorded activity as it arrives and flags visits that
/// match its rules. renewd does the checking; this shows the flags and edits
/// the rules.
struct MonitorView: View {
    @ObservedObject var model: AppModel

    enum Tab: String, CaseIterable, Identifiable {
        case flags = "Flags"
        case settings = "Settings"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.monitorTab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            .padding(.vertical, 10)
            Divider()
            switch model.monitorTab {
            case .flags: MonitorFlagsView(model: model)
            case .settings: MonitorSettingsView(model: model)
            }
        }
        .navigationTitle("Monitor")
    }
}

/// Shown on the Monitor page while it has nothing to check or is off.
private struct MonitorStatusBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.activitySupported && !model.activity.enabled {
            InfoBanner(title: "Monitor needs Activity on",
                       message: "The Monitor checks the pages Activity records. With Activity off, there's nothing to check.",
                       button: model.daemonReachable ? "Turn On Activity" : nil) {
                model.setActivity(ActivitySettings(enabled: true))
            }
        } else if model.monitorSupported && !model.monitor.enabled {
            InfoBanner(title: "The Monitor is off",
                       message: "Turn it on to flag visits to explicit or watched sites, and pages whose titles contain watched words.",
                       button: "Settings…") { model.monitorTab = .settings }
        }
    }
}

// MARK: flags

private struct MonitorFlagsView: View {
    @ObservedObject var model: AppModel

    @State private var day = Date()
    @State private var flags: [MonitorFlag] = []
    @State private var loadError: String?
    @State private var loaded = false
    @State private var generation = 0
    @State private var offset: Int?

    private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MonitorStatusBanner(model: model)
            HStack(spacing: 10) {
                DayPickerBar(day: $day)
                Spacer()
                Text(flags.count == 1 ? "1 flagged visit" : "\(flags.count) flagged visits")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button { load(incremental: true) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
            content
        }
        .padding(20)
        .onAppear { load() }
        .onChange(of: day) { _ in flags = []; loaded = false; load() }
        .onReceive(refresh) { _ in if isToday { load(incremental: true) } }
    }

    @ViewBuilder private var content: some View {
        if let loadError {
            Spacer()
            Text(loadError)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            Spacer()
        } else if flags.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "flag").font(.largeTitle).foregroundStyle(.secondary)
                Text(loaded ? "Nothing flagged on this day." : "Loading…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        } else {
            List(Array(flags.reversed().enumerated()), id: \.offset) { _, f in
                VisitRow(start: f.start, duration: f.duration, title: f.title.isEmpty ? f.host : f.title,
                         url: f.url, browser: f.browser) {
                    ForEach(f.flags, id: \.self) { flag in
                        FlagBadge(text: flag.label, color: .red)
                            .help(flag.kind == .domain ? "Matched \(flag.match)"
                                  : flag.isScore ? "Title has several suggestive words: \(flag.match)"
                                  : "Title contains “\(flag.match)”")
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func load(incremental: Bool = false) {
        generation += 1
        let mine = generation
        let from = incremental && loaded && loadError == nil ? offset : nil
        model.loadMonitorFlags(day: day, fromOffset: from) { result in
            guard mine == generation else { return }
            loaded = true
            switch result {
            case .success(let page):
                if page.isIncremental && from != nil {
                    if !page.flags.isEmpty {
                        flags = Array((flags + page.flags).sorted { $0.start < $1.start }
                            .suffix(MonitorLogStore.maxQueryResults))
                    }
                } else {
                    flags = page.flags
                }
                offset = page.offset
                loadError = nil
            case .failure(let e):
                flags = []
                offset = nil
                loadError = model.isInstalled || model.isLocalTest ? e.message : "Install Renew to use the Monitor."
            }
        }
    }
}

// MARK: settings

private struct MonitorSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var domainDraft = ""
    @State private var termDraft = ""
    @State private var explicitCount: Int?

    private var settings: MonitorSettings { model.monitor }
    private var editable: Bool { model.daemonReachable && model.monitorSupported && !model.busy }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: binding(\.enabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monitor activity")
                        Text("Checks each page Activity records, as it's recorded, and flags the ones that match below. Renew's background service does the checking, and keeps the flags even if a rule changes later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                if model.isInstalled && model.daemonReachable && !model.monitorSupported {
                    Text("The running background service predates the Monitor. Update Renew to turn it on.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if settings.enabled && model.activitySupported && !model.activity.enabled {
                    HStack {
                        Text("Activity is off, so there's nothing to check.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Turn On Activity") { model.setActivity(ActivitySettings(enabled: true)) }
                            .controlSize(.small)
                            .disabled(!model.daemonReachable)
                    }
                }
            } header: {
                Text("Monitor")
            } footer: {
                Text("Flags are kept by Renew's background service in a folder only it can change, for a year. Nothing is sent off this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                listToggle(MonitorSettings.explicitListName, title: "Explicit sites",
                           detail: explicitCount.map { "Preset: \($0.formatted()) adult sites from the open StevenBlack/hosts list" }
                               ?? "Preset list of adult sites from the open StevenBlack/hosts list")
                ForEach(model.sortedListNames, id: \.self) { name in
                    let count = model.lists[name]?.count ?? 0
                    listToggle(name, title: "\(name.capitalized) blocklist", detail: count == 1 ? "1 site" : "\(count) sites")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Other sites")
                    HStack {
                        TextField("Add a site, e.g. example.com", text: $domainDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addDomain)
                        Button("Add", action: addDomain)
                            .disabled(domainDraft.trimmingCharacters(in: .whitespaces).isEmpty || !editable)
                    }
                    if !settings.customDomains.isEmpty {
                        FlowLayout {
                            ForEach(settings.customDomains, id: \.self) { d in
                                RemovableChip(text: d) { update { $0.customDomains.removeAll { $0 == d } } }
                                    .disabled(!editable)
                            }
                        }
                    }
                }
            } header: {
                Text("Flag visits to")
            } footer: {
                Text("Uses the same rules as blocklists: a site includes its subdomains, and `keyword:` rules match anywhere in the address. Changes to a watched blocklist reach the Monitor the next time Renew syncs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: binding(\.flagExplicitTerms)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Explicit words")
                        Text("Common explicit words and adult site names, including disguised spellings and suggestive combinations.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Other words")
                    HStack {
                        TextField("Add a word or phrase", text: $termDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addTerm)
                        Button("Add", action: addTerm)
                            .disabled(MonitorSettings.cleanTerm(termDraft).isEmpty || !editable)
                    }
                    if !settings.customTerms.isEmpty {
                        FlowLayout {
                            ForEach(settings.customTerms, id: \.self) { t in
                                RemovableChip(text: t) { update { $0.customTerms.removeAll { $0 == t } } }
                                    .disabled(!editable)
                            }
                        }
                    }
                }
            } header: {
                Text("Flag page titles containing")
            } footer: {
                Text("Words match whole words, ignoring case and accents, so “sex” doesn't match “Essex”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!model.daemonReachable || !model.monitorSupported)
        .onAppear {
            ExplicitDomains.count { explicitCount = $0 > 0 ? $0 : nil }
        }
    }

    private func binding(_ key: WritableKeyPath<MonitorSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { on in update { $0[keyPath: key] = on } })
    }

    private func listToggle(_ name: String, title: String, detail: String) -> some View {
        let binding = Binding<Bool>(
            get: { settings.watchLists.contains(name) },
            set: { on in
                update {
                    $0.watchLists.removeAll { $0 == name }
                    if on { $0.watchLists.append(name) }
                }
            })
        return Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func update(_ change: (inout MonitorSettings) -> Void) {
        var m = settings
        change(&m)
        guard m != settings else { return }
        model.setMonitor(m)
    }

    private func addDomain() {
        let (valid, rejected) = canonicalRules(parseSites(domainDraft))
        if !rejected.isEmpty {
            model.errorMessage = "Not a valid site: \(rejected.joined(separator: ", "))"
            return
        }
        guard !valid.isEmpty else { return }
        update { m in m.customDomains += valid.filter { !m.customDomains.contains($0) } }
        domainDraft = ""
    }

    private func addTerm() {
        let term = MonitorSettings.cleanTerm(termDraft)
        guard !term.isEmpty else { return }
        guard term.count <= MonitorSettings.maxTermLength else {
            model.errorMessage = "Words and phrases can be at most \(MonitorSettings.maxTermLength) characters."
            return
        }
        update { m in if !m.customTerms.contains(term) { m.customTerms.append(term) } }
        termDraft = ""
    }
}
