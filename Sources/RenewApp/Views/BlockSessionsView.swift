import SwiftUI
import RenewShared

/// Saved block sessions first, then the running block session, if any.
struct BlockSessionsView: View {
    @ObservedObject var model: AppModel
    @State private var editing: BlockSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SessionBanners(model: model)
                ForEach(model.schedulesWithNothingToBlock) { s in
                    Banner(kind: .warning, title: "“\(s.name)” won't start",
                           message: "It has nothing to block, so it isn't scheduled. Its blocklists may have been deleted or emptied.",
                           actionTitle: "Edit") { editing = s }
                }
                SavedSessionsView(model: model, editing: $editing)
                if let session = model.session {
                    Divider().padding(.vertical, 4)
                    Text("Running now")
                        .font(.title2.weight(.bold))
                    ActiveSessionView(model: model, session: session)
                }
            }
            .padding(32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Block Sessions")
        .sheet(item: $editing) { session in
            BlockSessionEditor(model: model, session: session)
        }
    }
}

/// A one-off block: pick a length and what to block, and start it now.
struct QuickBlockView: View {
    @ObservedObject var model: AppModel
    @State private var editing: BlockSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SessionBanners(model: model)
                if let session = model.session {
                    ActiveSessionView(model: model, session: session)
                } else {
                    StartSessionView(model: model) { editing = $0 }
                }
            }
            .padding(32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Quick Block")
        .sheet(item: $editing) { session in
            BlockSessionEditor(model: model, session: session)
        }
    }
}

private struct SessionBanners: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isLocalTest {
            Banner(kind: .info, title: "Local test run",
                   message: "Renew is running without its background service. Blocking works, but nothing is locked down.")
        } else if !model.isInstalled {
            Banner(kind: .info, title: "Renew isn't set up yet",
                   message: "Install the background service to start blocking.",
                   actionTitle: "Set up") { model.section = .setup }
        } else if !model.daemonReachable {
            Banner(kind: .warning, title: "The Renew service isn't responding",
                   message: "It normally restarts on its own within a few seconds. If this persists, reinstall from Setup.")
        }
        if model.isInstalled && !model.permissionWarnings.isEmpty {
            Banner(kind: .warning, title: "Permissions needed",
                   message: model.permissionWarnings.joined(separator: " · ")
                       + ". During a block session, Renew closes any browser it can't watch.",
                   actionTitle: "Fix") { model.section = .setup }
        }
    }
}

// MARK: - Start

private struct StartSessionView: View {
    @ObservedObject var model: AppModel
    /// Opens the editor with this form's choices, to save them.
    let saveAs: (BlockSession) -> Void
    @State private var extra = ""
    @State private var confirming = false
    @State private var custom = false

    private let presets = [25, 60, 120, 240]

    private var rules: [String] { model.rules(forSelection: model.selectedLists, extra: extra) }
    private var endsAt: Date { model.now.addingTimeInterval(TimeInterval(model.durationMinutes * 60)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Quick block")
                    .font(.largeTitle.weight(.bold))
                Text("A one-off block session: choose how long and what to block, and start it now. Once it starts, it can't be stopped early.")
                    .foregroundStyle(.secondary)
            }

            Card(title: "HOW LONG") {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { m in
                        PillButton(title: Format.minutes(m), selected: !custom && model.durationMinutes == m) {
                            custom = false
                            model.durationMinutes = m
                        }
                    }
                    PillButton(title: "Custom", selected: custom) { custom = true }
                }
                if custom {
                    DurationPicker(minutes: $model.durationMinutes)
                }
                Text(model.durationMinutes < 1 ? "Choose at least 1 minute" : "Ends at \(Format.clock(endsAt))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Card(title: "WHAT TO BLOCK") {
                BlocklistPicker(model: model, selection: $model.selectedLists, extra: $extra)
                HStack(spacing: 16) {
                    Button("Edit blocklists…") { model.section = .lists }
                    Button("Save as a block session…") {
                        let sites = parseSites(extra)
                        saveAs(BlockSession(name: "", lists: model.selectedLists.sorted(), extraSites: sites,
                                            timing: .length(minutes: max(1, model.durationMinutes))))
                    }
                }
                .buttonStyle(.link)
            }

            Button {
                confirming = true
            } label: {
                Label(rules.isEmpty ? "Choose something to block" : "Start block session · \(rules.count) site\(rules.count == 1 ? "" : "s")",
                      systemImage: "lock.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(rules.isEmpty || model.busy || !(model.daemonReachable || model.isLocalTest) || model.durationMinutes < 1)
            .confirmationDialog("Lock in until \(Format.clock(endsAt))?", isPresented: $confirming) {
                Button("Start \(Format.minutes(model.durationMinutes)) block session") {
                    model.start(minutes: model.durationMinutes, rules: rules) { ok in
                        if ok { extra = "" }
                    }
                }
            } message: {
                Text("You won't be able to stop or shorten this block session. You can only add time or block more sites.")
            }
        }
        .onAppear { custom = !presets.contains(model.durationMinutes) }
    }
}

// MARK: - Active

private struct ActiveSessionView: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo
    @State private var newSite = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Spacer()
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 14)
                        Circle()
                            .trim(from: 0, to: max(0.001, 1 - model.progress))
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: model.progress)
                        VStack(spacing: 4) {
                            Text(Format.countdown(model.secondsLeft))
                                .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
                            Text("left")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 240, height: 240)
                    Text("Block session ends at \(Format.clock(session.endsAt))")
                        .font(.headline)
                }
                Spacer()
            }
            .padding(.vertical, 8)

            Card(title: "BLOCKING") {
                FlowLayout(spacing: 6) {
                    ForEach(session.rules, id: \.self) { RuleChip(rule: $0) }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                Card(title: "ADD TIME") {
                    HStack {
                        ForEach([15, 30, 60], id: \.self) { m in
                            Button("+\(Format.minutes(m))") { model.extend(minutes: m) }
                        }
                    }
                    .disabled(model.busy)
                }
                Card(title: "BLOCK ANOTHER SITE") {
                    HStack {
                        TextField("e.g. news.ycombinator.com", text: $newSite)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addSite)
                        Button("Block", action: addSite)
                            .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                    }
                }
            }

            Label("Block sessions can't be shortened or stopped. That's the point.", systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func addSite() {
        let parts = parseSites(newSite)
        guard !parts.isEmpty else { return }
        let (valid, rejected) = canonicalRules(parts)
        if !rejected.isEmpty {
            model.errorMessage = "Not a valid site: \(rejected.joined(separator: ", "))"
            return
        }
        model.add(rules: valid) { ok in if ok { newSite = "" } }
    }
}

// MARK: - Saved

private struct SavedSessionsView: View {
    @ObservedObject var model: AppModel
    @Binding var editing: BlockSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Block sessions")
                        .font(.largeTitle.weight(.bold))
                    Text("Saved blocks you can start in one click, or schedule for set times on chosen days.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editing = BlockSession(name: "", lists: model.selectedLists.sorted(),
                                           timing: .schedule(window: DailyWindow(startMinute: 9 * 60, endMinute: 17 * 60),
                                                             days: .weekdays))
                } label: {
                    Label("New block session", systemImage: "plus")
                }
            }
            if model.savedSessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No saved block sessions yet. Create one to reuse it, or schedule it to start on its own.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.session == nil {
                        Button("Or start a one-off quick block…") { model.section = .quick }
                            .buttonStyle(.link)
                    }
                }
            } else {
                ForEach(model.savedSessions) { s in
                    SavedSessionRow(model: model, session: s) { editing = s }
                }
                Text("Scheduled block sessions start on their own, even when this window is closed, and can't be stopped once they start. You can edit or delete them any time before then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SavedSessionRow: View {
    @ObservedObject var model: AppModel
    let session: BlockSession
    let edit: () -> Void
    @State private var confirmingStart = false
    @State private var confirmingDelete = false
    @State private var confirmingEnable = false

    private var rules: [String] { model.rules(for: session) }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: session.isScheduled ? "calendar.badge.clock" : "timer")
                .font(.title2)
                .foregroundStyle(session.isScheduled && session.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(session.name.isEmpty ? "Untitled" : session.name)
                        .font(.headline)
                    if let until = activeUntil {
                        Text("Active now · until \(Format.clock(until))")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.orange)
                    }
                }
                Text(timingText)
                    .font(.callout)
                Text(listsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))
        .confirmationDialog("Delete “\(session.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.deleteSession(session.id) }
        } message: {
            Text(activeUntil != nil ? "The block session that's running now keeps going until it ends." : "This can't be undone.")
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            switch session.timing {
            case .length(let minutes):
                Button("Start") { confirmingStart = true }
                    .disabled(rules.isEmpty || model.busy || !(model.daemonReachable || model.isLocalTest))
                    .confirmationDialog(startTitle(minutes), isPresented: $confirmingStart) {
                        Button("Start \(Format.minutes(minutes)) block session") { model.start(session) }
                    } message: {
                        Text(model.session != nil
                             ? "Its sites are added to the running block session, which keeps going until at least then."
                             : "You won't be able to stop or shorten this block session.")
                    }
            case .schedule:
                Toggle("On", isOn: Binding(get: { session.enabled },
                                           set: { on in
                                               if on && model.opensNow(session) && !rules.isEmpty {
                                                   confirmingEnable = true
                                               } else {
                                                   model.setEnabled(on, for: session.id)
                                               }
                                           }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(session.enabled ? "Scheduled" : "Off: won't start on its own")
                    .confirmationDialog(enableTitle, isPresented: $confirmingEnable) {
                        Button("Turn on and start blocking") { model.setEnabled(true, for: session.id) }
                    } message: {
                        Text("This schedule's window is open now, so turning it on starts a block session right away. It can't be stopped until the window ends.")
                    }
            }
            Menu {
                Button("Edit…", action: edit)
                Button("Delete…", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var enableTitle: String {
        guard case let .schedule(window, days) = session.timing,
              let end = Schedule(name: session.name, window: window, days: days, rules: []).activeWindowEnd(at: model.now) else {
            return "Start blocking now?"
        }
        return "Block until \(Format.clock(end))?"
    }

    private func startTitle(_ minutes: Int) -> String {
        "Lock in until \(Format.clock(model.now.addingTimeInterval(TimeInterval(minutes * 60))))?"
    }

    private var timingText: String {
        switch session.timing {
        case .length(let minutes):
            return Format.minutes(minutes)
        case let .schedule(window, days):
            var text = "\(days.summary()) · \(window.text())"
            if !session.enabled {
                text += " · Off"
            } else if activeUntil == nil,
                      let next = Schedule(name: session.name, window: window, days: days, rules: []).nextStart(after: model.now) {
                text += " · Next: \(Format.dayAndTime(next))"
            }
            return text
        }
    }

    private var listsText: String {
        let lists = session.lists.sorted().map(\.capitalized)
        let extras = session.extraSites
        let parts = lists + extras
        let summary = parts.isEmpty ? "Nothing selected" : parts.joined(separator: ", ")
        return "\(summary) · \(rules.count) site\(rules.count == 1 ? "" : "s")"
    }

    /// When the window running now ends, if this schedule is active.
    private var activeUntil: Date? {
        guard model.session != nil, let s = model.enforcedSchedule(session.id) else { return nil }
        return s.activeWindowEnd(at: model.now)
    }

    private var warning: String? {
        if rules.isEmpty { return "Nothing to block. Edit it to choose blocklists or sites." }
        guard session.isScheduled, session.enabled, !model.isLocalTest else { return nil }
        if !model.isInstalled { return "Won't start until Renew is set up." }
        guard model.daemonReachable else { return nil }
        if let desired = model.desiredSchedules.first(where: { $0.id == session.id }),
           model.enforcedSchedule(session.id) != desired {
            return "The Renew service hasn't picked up the latest version yet."
        }
        return nil
    }
}
