import SwiftUI
import RenewShared

/// Activity monitoring: the log of pages visited, and what gets flagged.
struct ActivityView: View {
    @ObservedObject var model: AppModel

    enum Tab: String, CaseIterable, Identifiable {
        case log = "Log"
        case settings = "Settings"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .log

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .padding(.vertical, 10)
            Divider()
            switch tab {
            case .log: ActivityLogView(model: model, openSettings: { tab = .settings })
            case .settings: ActivitySettingsView(model: model)
            }
        }
        .navigationTitle("Activity")
    }
}

// MARK: log

private struct ActivityLogView: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void

    @State private var day = Date()
    @State private var flaggedOnly = false
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
            // Not `Banner`: its fixed-size text breaks layout outside a
            // scroll view, which blanked the whole window, sidebar included.
            if !model.monitoring.enabled {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activity monitoring is off").font(.headline)
                        Text("Turn it on to record the pages you visit (address, title and time on page) and flag explicit or watched sites. It stays on this Mac.")
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Settings…", action: openSettings)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
            }
            header
            content
        }
        .padding(20)
        .onAppear { load() }
        .onChange(of: day) { _ in events = []; loaded = false; load() }
        .onChange(of: flaggedOnly) { _ in load() }
        .onReceive(refresh) { _ in if isToday { load(incremental: true) } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous day")
            DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(maxWidth: 130)
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .help("Next day")
                .disabled(isToday)
            if !isToday {
                Button("Today") { day = Date() }
            }
            Toggle("Flagged only", isOn: $flaggedOnly)
                .toggleStyle(.checkbox)
                .padding(.leading, 8)
            Spacer()
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { load(incremental: true) } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
        }
    }

    private var summary: String {
        let flagged = events.filter(\.isFlagged).count
        let visits = events.count == 1 ? "1 visit" : "\(events.count) visits"
        return flaggedOnly ? visits : "\(visits) · \(flagged) flagged"
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
                Image(systemName: "eye").font(.largeTitle).foregroundStyle(.secondary)
                Text(!loaded ? "Loading…" : flaggedOnly ? "No flagged visits on this day." : "No visits recorded on this day.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        } else {
            List(Array(events.reversed().enumerated()), id: \.offset) { _, e in
                ActivityRow(event: e)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func shiftDay(_ by: Int) {
        guard let d = Calendar.current.date(byAdding: .day, value: by, to: day), d <= Date() else { return }
        day = d
    }

    /// The whole day, or with `incremental` only visits added since the last load.
    private func load(incremental: Bool = false) {
        generation += 1
        let mine = generation
        let from = incremental && loaded && loadError == nil ? offset : nil
        model.loadActivity(day: day, flaggedOnly: flaggedOnly, fromOffset: from) { result in
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

private struct ActivityRow: View {
    let event: ActivityEvent

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.time.string(from: event.start))
                    .monospacedDigit()
                Text(DurationText.format(Int(event.duration.rounded())))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 74, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title.isEmpty ? event.host : event.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(event.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(event.browser)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if event.isFlagged {
                VStack(alignment: .trailing, spacing: 4) {
                    if event.blocked { FlagBadge(text: "Blocked", color: .orange) }
                    ForEach(event.flags, id: \.self) { f in
                        FlagBadge(text: f.label, color: .red).help(f.kind == .domain ? "Matched \(f.match)" : "Title contains “\(f.match)”")
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(event.url, forType: .string)
            }
            Button("Copy Title") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(event.title, forType: .string)
            }
        }
    }
}

private struct FlagBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: settings

private struct ActivitySettingsView: View {
    @ObservedObject var model: AppModel
    @State private var domainDraft = ""
    @State private var termDraft = ""
    @State private var explicitCount: Int?

    private var settings: MonitoringSettings { model.monitoring }
    private var editable: Bool { model.daemonReachable && model.monitoringSupported && !model.busy }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: binding(\.enabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monitor browsing")
                        Text("Records the address and title of each page you look at and how long it was in front: the active tab in Safari, Chrome, Edge, Brave, Arc, Vivaldi and Firefox, and websites in the built-in browsers of apps like T3 Code, Claude and Codex. Time away from the Mac isn't counted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                if model.isInstalled && model.daemonReachable && !model.monitoringSupported {
                    Text("The running background service predates activity monitoring. Update Renew to turn it on.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if settings.enabled && !model.permissionWarnings.isEmpty {
                    Text("Some pages can't be read: \(model.permissionWarnings.joined(separator: "; ")). See Setup.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Activity monitoring")
            } footer: {
                Text("The log is kept by Renew's background service in a folder only it can change, for \(ActivityLogStore.retentionDays) days. Nothing is sent off this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                listToggle(MonitoringSettings.explicitListName, title: "Explicit sites",
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
                Text("Uses the same rules as blocklists: a site includes its subdomains, and `keyword:` rules match anywhere in the address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: binding(\.flagExplicitTerms)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Explicit words")
                        Text("\(ExplicitTerms.preset.count) common explicit words and adult site names.")
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
                            .disabled(MonitoringSettings.cleanTerm(termDraft).isEmpty || !editable)
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
        .disabled(!model.daemonReachable || !model.monitoringSupported)
        .onAppear {
            ExplicitDomains.load { explicitCount = $0.count }
        }
    }

    private func binding(_ key: WritableKeyPath<MonitoringSettings, Bool>) -> Binding<Bool> {
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

    private func update(_ change: (inout MonitoringSettings) -> Void) {
        var m = settings
        change(&m)
        guard m != settings else { return }
        model.setMonitoring(m)
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
        let term = MonitoringSettings.cleanTerm(termDraft)
        guard !term.isEmpty else { return }
        guard term.count <= MonitoringSettings.maxTermLength else {
            model.errorMessage = "Words and phrases can be at most \(MonitoringSettings.maxTermLength) characters."
            return
        }
        update { m in if !m.customTerms.contains(term) { m.customTerms.append(term) } }
        termDraft = ""
    }
}

private struct RemovableChip: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.callout)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}
