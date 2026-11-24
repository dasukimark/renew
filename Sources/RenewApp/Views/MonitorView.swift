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
                       message: "Turn on Activity so the Monitor has pages to check.",
                       button: model.daemonReachable ? "Turn On Activity" : nil) {
                model.setActivity(ActivitySettings(enabled: true))
            }
        } else if model.monitorSupported && !model.monitor.enabled {
            InfoBanner(title: "The Monitor is off",
                       message: model.hasPartner
                           ? "Turn it on to start flagging."
                           : "Add a partner to turn it on.",
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
                if !flags.isEmpty {
                    Text(flags.count == 1 ? "1 flagged visit" : "\(flags.count) flagged visits")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
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
                if loaded && isToday && model.monitor.enabled && model.activity.enabled {
                    Text("The Monitor is checking pages as you browse.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
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
    @State private var creatingList = false
    @State private var newListName = ""
    /// The list open in the editor sheet.
    @State private var editing: MonitorListTarget?

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
                    NoticeRow(title: "Add a partner first",
                              message: "Monitoring needs a partner to report to.",
                              button: "Partners…", icon: "person.badge.plus") { model.accountabilityTab = .partners }
                }
            }
            if locked {
                Section {
                    NoticeRow(title: "Locked while you have a partner",
                              message: "You can add, but not remove.",
                              button: "Partners…", icon: "lock.fill", tint: .secondary) {
                        model.accountabilityTab = .partners
                    }
                }
            }
            Section {
                Toggle(isOn: binding(\.enabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monitor activity")
                        Text("Flags pages that match the rules below.")
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
            }

            Group {
                Section {
                    Toggle(isOn: binding(\.flagExplicit)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Flag explicit content")
                            Text("Adult sites and explicit pages.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(locked && settings.flagExplicit)
                } header: {
                    Text("Explicit content")
                }

                Section {
                    Toggle(isOn: binding(\.flagLists)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Flag sites on monitoring lists")
                            if model.daemonReachable && !model.monitorListSwitchSupported {
                                Text("Update Renew to turn this off.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled((locked && settings.flagLists) || !model.monitorListSwitchSupported)
                    Group {
                        ForEach(settings.sortedListNames, id: \.self) { name in
                            listRow(.list(name), items: settings.lists[name] ?? [])
                        }
                        if !settings.customDomains.isEmpty {
                            listRow(.other, items: settings.customDomains)
                        }
                        if settings.lists.isEmpty && settings.customDomains.isEmpty {
                            Text("No lists yet.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Still editable while off, just visibly not in use.
                    .opacity(settings.flagLists ? 1 : 0.5)
                    HStack {
                        addListMenu
                        Spacer()
                    }
                    .disabled(!editable)
                } header: {
                    Text("Monitoring lists")
                }

                Section {
                    listRow(.words, items: settings.customTerms)
                } header: {
                    Text("Watched words")
                } footer: {
                    Text("Flags page titles with these words.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(needsPartner)
        }
        .formStyle(.grouped)
        .disabled(!model.daemonReachable || !supported)
        .sheet(item: $editing) { target in
            MonitorListEditor(model: model, target: target)
        }
        .alert("New monitoring list", isPresented: $creatingList) {
            TextField("Name", text: $newListName)
            Button("Create", action: createList)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give the list a short name, like “reddit” or “streaming”.")
        }
    }

    /// One control for every way to add: a new list, a ready-made one, or
    /// sites that don't belong to a list.
    private var addListMenu: some View {
        Menu {
            Button("New List…") { newListName = ""; creatingList = true }
            Button("Sites Without a List…") { editing = .other }
            Divider()
            Section("Ready-made lists") {
                ForEach(MonitorSettings.starterLists, id: \.self) { name in
                    let sites = MonitorSettings.starter(name) ?? []
                    let have = Set(settings.lists[name] ?? [])
                    let added = !sites.isEmpty && sites.allSatisfy(have.contains)
                    Button(added ? "\(name.capitalized) (added)" : "\(name.capitalized) (\(sites.count) sites)") {
                        addStarter(name)
                    }
                    .disabled(added)
                }
            }
        } label: {
            Label("Add List", systemImage: "plus")
        }
        .fixedSize()
    }

    /// A list as one line: its name, the first few sites, and how many.
    /// Opens the editor.
    private func listRow(_ target: MonitorListTarget, items: [String]) -> some View {
        Button { editing = target } label: {
            HStack(spacing: 12) {
                Image(systemName: target.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                    Text(items.isEmpty ? target.emptyText : items.prefix(6).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 12)
                Text("\(items.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edit \(target.title)")
        .accessibilityLabel("\(target.title), \(target.count(items.count))")
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

    private func createList() {
        guard let name = MonitorSettings.cleanListName(newListName) else {
            if !newListName.trimmingCharacters(in: .whitespaces).isEmpty {
                model.errorMessage = "“\(newListName)” can't be used as a list name. Pick a name other than “explicit” or “custom”, up to \(MonitorSettings.maxListNameLength) characters."
            }
            return
        }
        guard settings.lists[name] == nil else {
            editing = .list(name)
            return
        }
        guard settings.lists.count < MonitorSettings.maxLists else {
            model.errorMessage = "You can have at most \(MonitorSettings.maxLists) monitoring lists."
            return
        }
        update { $0.lists[name] = [] }
        editing = .list(name)
    }

    /// Copies a starter's sites, merging into a list of the same name.
    private func addStarter(_ name: String) {
        guard let sites = MonitorSettings.starter(name) else { return }
        update { $0.addSites(sites, to: name) }
    }
}

// MARK: list editor

/// A monitoring list, or the sites that aren't in one.
enum MonitorListTarget: Hashable, Identifiable {
    case list(String)
    case other
    /// The one list of watched words and phrases.
    case words

    var id: String {
        switch self {
        case .list(let name): return "list:" + name
        case .other: return "other"
        case .words: return "words"
        }
    }

    var title: String {
        switch self {
        case .list(let name): return name.capitalized
        case .other: return "Other sites"
        case .words: return "Words and phrases"
        }
    }

    var symbol: String {
        switch self {
        case .list: return "list.bullet"
        case .other: return "globe"
        case .words: return "textformat"
        }
    }

    var isWords: Bool { self == .words }
    var emptyText: String { isWords ? "No words yet" : "No sites yet" }

    func count(_ n: Int) -> String {
        let noun = isWords ? "word" : "site"
        return n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}

/// Edits one monitoring list in a sheet: add sites (several at once,
/// separated by commas or spaces), remove them, or delete the list. While
/// monitoring is locked, sites can only be added.
private struct MonitorListEditor: View {
    @ObservedObject var model: AppModel
    let target: MonitorListTarget
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var filter = ""
    @State private var confirmingDelete = false
    /// Whether this list has existed while the sheet was open: a new list
    /// arrives with the next status, so only missing after that means it
    /// was deleted (from the command line or another window).
    @State private var listSeen = false

    private var settings: MonitorSettings { model.monitor }
    /// Removing is locked while a partner relies on monitoring, except
    /// for sites while lists are switched off: they aren't flagged, so
    /// removing them watches nothing less (renewd agrees).
    private var locked: Bool { model.monitoringLocked && (target.isWords || settings.flagLists) }
    private var editable: Bool {
        model.daemonReachable && model.monitorSupported && model.monitorListsSupported && !model.busy && !listGone
    }

    private var listExists: Bool {
        guard case .list(let name) = target else { return true }
        return settings.lists[name] != nil
    }

    private var listGone: Bool { listSeen && !listExists }

    private var sites: [String] {
        switch target {
        case .list(let name): return settings.lists[name] ?? []
        case .other: return settings.customDomains
        case .words: return settings.customTerms
        }
    }

    private var shown: [String] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? sites : sites.filter { $0.lowercased().contains(f) }
    }

    /// While locked only a list that watches nothing can go.
    private var canDelete: Bool {
        guard case .list = target, !listGone else { return false }
        return !locked || sites.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(target.title).font(.title2.weight(.bold))
                Text(target.count(sites.count))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }

            HStack {
                TextField(target.isWords ? "Words" : "Sites", text: $draft,
                          prompt: Text(target.isWords ? "Add words or phrases, separated by commas"
                                                      : "Add sites, e.g. example.com, news.site.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || !editable)
            }

            VStack(spacing: 0) {
                if sites.count > 8 {
                    TextField("Filter", text: $filter, prompt: Text(target.isWords ? "Filter words" : "Filter sites"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .padding(8)
                    Divider()
                }
                if listGone {
                    Text("This list was deleted.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sites.isEmpty {
                    Text(target.isWords ? "No words yet. Add the first one above." : "No sites yet. Add the first one above.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty {
                    Text(target.isWords ? "No words match “\(filter)”." : "No sites match “\(filter)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(shown, id: \.self) { site in
                        HStack {
                            Image(systemName: target.isWords ? "textformat" : RuleChip.symbol(Rule.parse(site)?.kind))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(site).textSelection(.enabled)
                            Spacer()
                            if !locked {
                                Button { remove(site) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove")
                                .disabled(!editable)
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if canDelete {
                    Button("Delete List…", role: .destructive) { confirmingDelete = true }
                        .disabled(!editable)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 440)
        .onAppear { if listExists { listSeen = true } }
        .onChange(of: listExists) { if $0 { listSeen = true } }
        .confirmationDialog("Delete the monitoring list “\(target.title)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if case .list(let name) = target { update { $0.lists[name] = nil } }
                dismiss()
            }
        } message: {
            Text("Flags already found are kept.")
        }
    }

    private var footnote: String {
        switch (locked, target.isWords) {
        case (true, true): return "Locked: you can add words, but not remove them."
        case (true, false): return "Locked: you can add sites, but not remove them."
        case (false, true): return "Matches whole words in page titles."
        case (false, false): return "Sites include their subdomains."
        }
    }

    private func update(_ change: (inout MonitorSettings) -> Void, completion: ((Bool) -> Void)? = nil) {
        var m = settings
        change(&m)
        guard m != settings else { completion?(true); return }
        model.setMonitor(m, completion: completion)
    }

    /// Clears what was typed once renewd takes it, so a refused change
    /// (too many sites, say) keeps the text to fix and try again.
    private func clearDraft(ifStill typed: String) -> (Bool) -> Void {
        { ok in if ok && draft == typed { draft = "" } }
    }

    private func add() {
        if target.isWords { addWords(); return }
        let (valid, rejected) = canonicalRules(parseSites(draft))
        if !rejected.isEmpty {
            model.errorMessage = "Not a valid site: \(rejected.joined(separator: ", "))"
            return
        }
        guard !valid.isEmpty else { return }
        let done = clearDraft(ifStill: draft)
        switch target {
        case .list(let name): update({ $0.addSites(valid, to: name) }, completion: done)
        case .other: update({ m in m.customDomains += valid.filter { !m.customDomains.contains($0) } }, completion: done)
        case .words: break
        }
    }

    /// Words and phrases are separated by commas or new lines, since a
    /// phrase has spaces.
    private func addWords() {
        let words = draft.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { MonitorSettings.cleanTerm(String($0)) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return }
        if let long = words.first(where: { $0.count > MonitorSettings.maxTermLength }) {
            model.errorMessage = "“\(long)” is too long. Words and phrases can be at most \(MonitorSettings.maxTermLength) characters."
            return
        }
        update({ m in
            for w in words where !m.customTerms.contains(w) { m.customTerms.append(w) }
        }, completion: clearDraft(ifStill: draft))
    }

    private func remove(_ site: String) {
        switch target {
        case .list(let name): update { $0.lists[name]?.removeAll { $0 == site } }
        case .other: update { $0.customDomains.removeAll { $0 == site } }
        case .words: update { $0.customTerms.removeAll { $0 == site } }
        }
    }
}
