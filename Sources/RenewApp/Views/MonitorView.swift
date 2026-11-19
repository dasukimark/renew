import SwiftUI
import RenewShared

// The Monitor: reads recorded activity as it arrives and flags visits that
// match its rules. renewd does the checking; these are the Monitoring and
// Flags tabs of the Accountability page (see `AccountabilityView`).

/// Shown on the Flags tab while the Monitor has nothing to check or is off.
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
                       message: model.hasPartner
                           ? "Turn it on to flag visits to explicit or watched sites, and pages whose titles contain watched words."
                           : "Add an accountability partner, then turn it on to flag visits to explicit or watched sites.",
                       button: model.hasPartner ? "Monitoring…" : "Partners…") {
                model.accountabilityTab = model.hasPartner ? .monitoring : .partners
            }
        }
    }
}

// MARK: flags

struct MonitorFlagsView: View {
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
                                  : flag.isScore ? "Several signals added up: \(flag.match)"
                                  : flag.isSiteLabel ? "The site marked this page as adult content (\(flag.match))"
                                  : flag.isPageWords ? "The page text has several explicit words: \(flag.match)"
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

struct MonitorSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var domainDraft = ""
    @State private var termDraft = ""
    @State private var explicitCount: Int?

    private var settings: MonitorSettings { model.monitor }
    private var editable: Bool { model.daemonReachable && model.monitorSupported && !model.busy }
    /// With a partner and the Monitor on, nothing can be turned off or
    /// removed (renewd refuses it too); adding still works.
    private var locked: Bool { model.monitoringLocked }
    /// Without a partner the Monitor can't be turned on, so there's nothing
    /// to set up yet. Settings left on from before stay editable.
    private var needsPartner: Bool { !model.hasPartner && !settings.enabled }

    var body: some View {
        Form {
            if needsPartner && model.daemonReachable && model.monitorSupported {
                Section {
                    InfoBanner(title: "Add a partner first",
                               message: "Monitoring tells an accountability partner what it flags, so it needs one to turn on.",
                               button: "Partners…") { model.accountabilityTab = .partners }
                }
            }
            if locked {
                Section {
                    Label("Locked while you have an accountability partner. You can add to what's watched, but not remove anything. To loosen monitoring, remove your partners on the Partners tab (they'll be asked to approve).",
                          systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
                .disabled(locked || needsPartner)
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

            Group {
                Section {
                    listToggle(MonitorSettings.explicitListName, title: "Explicit sites",
                               detail: explicitCount.map { "Preset: \($0.formatted()) adult sites from the open StevenBlack/hosts list" }
                                   ?? "Preset list of adult sites from the open StevenBlack/hosts list")
                    ForEach(model.sortedListNames, id: \.self) { name in
                        let count = model.lists[name]?.count ?? 0
                        listToggle(name, title: "\(name.capitalized) blocklist", detail: count == 1 ? "1 site" : "\(count) sites")
                    }
                    // Watched lists whose blocklist was deleted: the Monitor
                    // still has their sites, so they stay visible (and can be
                    // unchecked when not locked).
                    ForEach(deletedWatchedLists, id: \.self) { name in
                        let count = settings.listRules[name]?.count ?? 0
                        listToggle(name, title: "\(name.capitalized) blocklist (deleted)",
                                   detail: "The Monitor keeps its \(count == 1 ? "1 site" : "\(count) sites")")
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
                                    RemovableChip(text: d, remove: locked ? nil : { update { $0.customDomains.removeAll { $0 == d } } })
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
                            Text("Flag explicit content")
                            Text("Page titles with explicit words or adult site names, including disguised spellings and suggestive combinations. On sites like Reddit, X and YouTube, also reads the visible text of the page for the site's own NSFW labels and explicit words. Page text never leaves the Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(locked && settings.flagExplicitTerms)
                } header: {
                    Text("Explicit content")
                } footer: {
                    Text("Work sites (Slack, Jira, GitHub, Google Docs, Gmail…) are never flagged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
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
                                    RemovableChip(text: t, remove: locked ? nil : { update { $0.customTerms.removeAll { $0 == t } } })
                                        .disabled(!editable)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Other words")
                } footer: {
                    Text("Flags page titles containing any of these. Words match whole words, ignoring case and accents, so “sex” doesn't match “Essex”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(needsPartner)
        }
        .formStyle(.grouped)
        .disabled(!model.daemonReachable || !model.monitorSupported)
        .onAppear {
            ExplicitDomains.count { explicitCount = $0 > 0 ? $0 : nil }
        }
    }

    private var deletedWatchedLists: [String] {
        let existing = Set(model.sortedListNames.map { $0.lowercased() })
        return settings.watchLists.filter { $0 != MonitorSettings.explicitListName && !existing.contains($0) }
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
        .disabled(locked && settings.watchLists.contains(name))
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
