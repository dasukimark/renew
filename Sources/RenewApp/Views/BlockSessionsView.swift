import SwiftUI
import RenewShared

/// One place for blocking: the block session running now, if any, then the
/// saved block sessions, then a collapsed one-off block for the rare times
/// none of them fits.
struct BlockSessionsView: View {
    @ObservedObject var model: AppModel
    @State private var editing: BlockSession?
    private static let oneOffID = "oneOff"

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 20) {
                        if SessionBanners.isShowing(model) || !model.schedulesWithNothingToBlock.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                SessionBanners(model: model)
                                ForEach(model.schedulesWithNothingToBlock) { s in
                                    Banner(kind: .warning, title: "“\(s.name)” won't start",
                                           message: "It has nothing to block, so it isn't scheduled. Its blocklists may have been deleted or emptied.",
                                           actionTitle: "Edit") { editing = s }
                                }
                            }
                        }
                        Text("Block sessions")
                            .font(.largeTitle.weight(.bold))
                    }

                    if let session = model.session {
                        PageSection(title: "Running now") {
                            ActiveSessionView(model: model, session: session)
                        }
                    }

                    SavedSessionsView(model: model, editing: $editing)

                    // Always in the view tree (it hides itself while a block
                    // session runs) so a half-filled form survives a
                    // scheduled session starting and ending.
                    OneOffBlockView(model: model, saveAs: { editing = $0 }) {
                        withAnimation(.easeOut(duration: 0.25)) { scroll.scrollTo(Self.oneOffID, anchor: .top) }
                    }
                    .id(Self.oneOffID)
                }
                .padding(32)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Block Sessions")
        .sheet(item: $editing) { session in
            BlockSessionEditor(model: model, session: session)
        }
    }
}

/// A heading for one part of the page, with an optional control on the right.
private struct PageSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.weight(.bold))
                Spacer()
                accessory
            }
            content
        }
    }
}

extension PageSection where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

private struct SessionBanners: View {
    @ObservedObject var model: AppModel

    /// Whether any banner shows, so the page leaves no gap when none do.
    static func isShowing(_ model: AppModel) -> Bool {
        model.isLocalTest || !model.isInstalled || !model.daemonReachable
            || (model.isInstalled && !model.permissionWarnings.isEmpty)
    }

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

/// A one-off block: how long and what to block, then Start. Used less than
/// the saved block sessions, so it stays collapsed to one row until opened.
private struct OneOffBlockView: View {
    @ObservedObject var model: AppModel
    /// Opens the editor with this form's choices, to save them.
    let saveAs: (BlockSession) -> Void
    /// Called once it opens, to bring the form into view.
    let opened: () -> Void
    @State private var expanded = false
    @State private var extra = ""
    @State private var confirming = false
    @State private var custom = false

    private let presets = [25, 60, 120, 240]

    private var rules: [String] { model.rules(forSelection: model.selectedLists, extra: extra) }
    private var endsAt: Date { model.now.addingTimeInterval(TimeInterval(model.durationMinutes * 60)) }

    var body: some View {
        if model.session == nil { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "bolt")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("One-off block").font(.headline)
                        Text("Block for a set time without saving it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded { form }
        }
        // Collapsed, it's a plain row so it doesn't compete with the saved
        // block sessions; opened, it becomes a card like them.
        .padding(.horizontal, 14)
        .padding(.vertical, expanded ? 16 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(expanded ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.secondary.opacity(expanded ? 0.15 : 0)))
        .onAppear { custom = !presets.contains(model.durationMinutes) }
        // Scroll once the expand animation has laid out the form; scrolling
        // sooner measures the collapsed row and can stop short.
        .onChange(of: expanded) { open in
            if open { DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: opened) }
        }
    }

    @ViewBuilder private var form: some View {
        let rules = self.rules
        Divider().padding(.vertical, 6)

        VStack(alignment: .leading, spacing: 12) {
            CardLabel("HOW LONG")
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

        Divider().padding(.vertical, 6)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                CardLabel("WHAT TO BLOCK")
                Spacer()
                Button("Edit blocklists…") { model.section = .lists }
                    .buttonStyle(.link)
            }
            BlocklistPicker(model: model, selection: $model.selectedLists, extra: $extra)
        }

        Divider().padding(.vertical, 6)

        HStack(spacing: 16) {
            Button("Save as a block session…") {
                saveAs(BlockSession(name: "", lists: model.selectedLists.sorted(), extraSites: parseSites(extra),
                                    timing: .length(minutes: max(1, model.durationMinutes))))
            }
            .buttonStyle(.link)
            Spacer()
            Button {
                confirming = true
            } label: {
                Label(rules.isEmpty ? "Choose something to block" : "Start block session · \(rules.count) site\(rules.count == 1 ? "" : "s")",
                      systemImage: "lock.fill")
                    .padding(.horizontal, 6)
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
    }
}

// MARK: - Active

/// The running block session: time left and when it ends, with ways to
/// make it longer or block more. Compact, so the saved list stays in view.
private struct ActiveSessionView: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo
    @State private var newSite = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 28) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: max(0.001, 1 - model.progress))
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: model.progress)
                    VStack(spacing: 2) {
                        Text(Format.countdown(model.secondsLeft))
                            .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("left")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 150, height: 150)
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ends at \(Format.clock(session.endsAt))")
                            .font(.title3.weight(.semibold))
                        Label("Can't be shortened or stopped. You can add time or block more sites.", systemImage: "lock")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        ForEach([15, 30, 60], id: \.self) { m in
                            Button("+\(Format.minutes(m))") { model.extend(minutes: m) }
                        }
                    }
                    .disabled(model.busy)
                    .help("Add time to this block session")
                }
            }

            Card(title: "BLOCKING · \(session.rules.count) SITE\(session.rules.count == 1 ? "" : "S")") {
                FlowLayout(spacing: 6) {
                    ForEach(session.rules, id: \.self) { RuleChip(rule: $0) }
                }
                Divider().padding(.vertical, 2)
                HStack {
                    TextField("Block another site… e.g. news.ycombinator.com", text: $newSite)
                        .accessibilityLabel("Block another site")
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addSite)
                    Button("Block", action: addSite)
                        .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                }
            }
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
        PageSection(title: "Saved") {
            Button {
                editing = BlockSession(name: "", lists: model.selectedLists.sorted(),
                                       timing: .schedule(window: DailyWindow(startMinute: 9 * 60, endMinute: 17 * 60),
                                                         days: .weekdays))
            } label: {
                Label("New block session", systemImage: "plus")
            }
        } content: {
            if model.savedSessions.isEmpty {
                Text("No saved block sessions yet. Create one to start it in one click, or give it set times so it starts on its own."
                     + (model.session == nil ? " For a block you won't repeat, use a one-off block below." : ""))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.savedSessions) { s in
                    SavedSessionRow(model: model, session: s) { editing = s }
                }
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
                    .help(session.enabled
                          ? "Scheduled: starts on its own at its set times, even when this window is closed, and can't be stopped once it starts"
                          : "Off: won't start on its own")
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
