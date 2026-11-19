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
                           ? "Turn it on to flag explicit content, visits to sites on your monitoring lists, and pages whose titles contain watched words."
                           : "Add an accountability partner, then turn it on to flag explicit content and sites on your monitoring lists.",
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
    @State private var siteDrafts: [String: String] = [:]
    @State private var expanded: Set<String> = []
    @State private var creatingList = false
    @State private var newListName = ""
    @State private var deletingList: String?
    @State private var explicitCount: Int?

    private var settings: MonitorSettings { model.monitor }
    private var supported: Bool { model.monitorSupported && model.monitorListsSupported }
    private var editable: Bool { model.daemonReachable && supported && !model.busy }
    /// With a partner and the Monitor on, nothing can be turned off or
    /// removed (renewd refuses it too); adding still works.
    private var locked: Bool { model.monitoringLocked }
    /// Without a partner the Monitor can't be turned on, so there's nothing
    /// to set up yet. Settings left on from before stay editable.
    private var needsPartner: Bool { !model.hasPartner && !settings.enabled }

    var body: some View {
        Form {
            if needsPartner && model.daemonReachable && supported {
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
                if model.isInstalled && model.daemonReachable && !supported {
                    Text(model.monitorSupported
                         ? "The running background service predates monitoring lists. Update Renew to change these settings."
                         : "The running background service predates the Monitor. Update Renew to turn it on.")
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
                    Toggle(isOn: binding(\.flagExplicit)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Flag explicit content")
                            Text("Visits to known adult sites (\(explicitCount.map { "a preset of \($0.formatted()) sites" } ?? "a preset list") from the open StevenBlack/hosts list), page titles with explicit words or adult site names, including disguised spellings and suggestive combinations, and on sites like Reddit, X and YouTube the page's own NSFW labels and explicit words. Page text never leaves the Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(locked && settings.flagExplicit)
                } header: {
                    Text("Explicit content")
                } footer: {
                    Text("Work sites (Slack, Jira, GitHub, Google Docs, Gmail…) are never flagged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(settings.sortedListNames, id: \.self) { name in
                        listRow(name)
                    }
                    HStack {
                        Button("New List…") { newListName = ""; creatingList = true }
                        Menu("Add a Starter") {
                            ForEach(MonitorSettings.starterLists, id: \.self) { name in
                                let count = MonitorSettings.starter(name)?.count ?? 0
                                Button("\(name.capitalized) (\(count) sites)") { addStarter(name) }
                            }
                        }
                        .fixedSize()
                        Spacer()
                    }
                    .disabled(!editable)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Other sites")
                        siteField(text: $domainDraft, add: addDomain)
                        chips(settings.customDomains) { d in update { $0.customDomains.removeAll { $0 == d } } }
                    }
                } header: {
                    Text("Monitoring lists")
                } footer: {
                    Text("Monitoring lists are separate from blocklists: they're sites you still visit but want flagged for your partner. A site includes its subdomains, and `keyword:` rules match anywhere in the address.")
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
                        chips(settings.customTerms) { t in update { $0.customTerms.removeAll { $0 == t } } }
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
        .disabled(!model.daemonReachable || !supported)
        .onAppear {
            ExplicitDomains.count { explicitCount = $0 > 0 ? $0 : nil }
        }
        .alert("New monitoring list", isPresented: $creatingList) {
            TextField("Name", text: $newListName)
            Button("Create", action: createList)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give the list a short name, like “reddit” or “streaming”.")
        }
        .confirmationDialog("Delete the monitoring list “\(deletingList ?? "")”?",
                            isPresented: Binding(get: { deletingList != nil }, set: { if !$0 { deletingList = nil } })) {
            Button("Delete", role: .destructive) {
                if let name = deletingList {
                    update { $0.lists[name] = nil }
                    expanded.remove(name)
                    siteDrafts[name] = nil
                }
                deletingList = nil
            }
        } message: {
            Text("Its sites stop being flagged. Flags already found are kept.")
        }
    }

    private func listRow(_ name: String) -> some View {
        let sites = settings.lists[name] ?? []
        let isExpanded = Binding<Bool>(
            get: { expanded.contains(name) },
            set: { if $0 { expanded.insert(name) } else { expanded.remove(name) } })
        return DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                siteField(text: Binding(get: { siteDrafts[name] ?? "" }, set: { siteDrafts[name] = $0 })) {
                    addSites(to: name)
                }
                chips(sites) { site in update { $0.lists[name]?.removeAll { $0 == site } } }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text(name.capitalized)
                Text(sites.count == 1 ? "1 site" : "\(sites.count) sites")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // While locked only an empty list (watching nothing) can go.
                if !locked || sites.isEmpty {
                    Button { deletingList = name } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete list")
                        .disabled(!editable)
                }
            }
        }
    }

    private func siteField(text: Binding<String>, add: @escaping () -> Void) -> some View {
        HStack {
            TextField("Add a site, e.g. example.com", text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty || !editable)
        }
    }

    @ViewBuilder private func chips(_ items: [String], remove: @escaping (String) -> Void) -> some View {
        if !items.isEmpty {
            FlowLayout {
                ForEach(items, id: \.self) { item in
                    RemovableChip(text: item, remove: locked ? nil : { remove(item) })
                        .disabled(!editable)
                }
            }
        }
    }

    private func binding(_ key: WritableKeyPath<MonitorSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { on in update { $0[keyPath: key] = on } })
    }

    private func update(_ change: (inout MonitorSettings) -> Void) {
        var m = settings
        change(&m)
        guard m != settings else { return }
        model.setMonitor(m)
    }

    /// Valid sites typed in `text`, or nil (with an error shown) if any isn't.
    private func parsedSites(_ text: String) -> [String]? {
        let (valid, rejected) = canonicalRules(parseSites(text))
        if !rejected.isEmpty {
            model.errorMessage = "Not a valid site: \(rejected.joined(separator: ", "))"
            return nil
        }
        return valid
    }

    private func addDomain() {
        guard let valid = parsedSites(domainDraft), !valid.isEmpty else { return }
        update { m in m.customDomains += valid.filter { !m.customDomains.contains($0) } }
        domainDraft = ""
    }

    private func addSites(to name: String) {
        guard let valid = parsedSites(siteDrafts[name] ?? ""), !valid.isEmpty else { return }
        update { $0.addSites(valid, to: name) }
        siteDrafts[name] = ""
    }

    private func createList() {
        guard let name = MonitorSettings.cleanListName(newListName) else {
            if !newListName.trimmingCharacters(in: .whitespaces).isEmpty {
                model.errorMessage = "“\(newListName)” can't be used as a list name. Pick a name other than “explicit” or “custom”, up to \(MonitorSettings.maxListNameLength) characters."
            }
            return
        }
        guard settings.lists[name] == nil else {
            expanded.insert(name)
            return
        }
        guard settings.lists.count < MonitorSettings.maxLists else {
            model.errorMessage = "You can have at most \(MonitorSettings.maxLists) monitoring lists."
            return
        }
        siteDrafts[name] = nil
        expanded.insert(name)
        update { $0.lists[name] = [] }
    }

    /// Copies a starter's sites, merging into a list of the same name.
    private func addStarter(_ name: String) {
        guard let sites = MonitorSettings.starter(name) else { return }
        update { $0.addSites(sites, to: name) }
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
