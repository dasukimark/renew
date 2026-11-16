import SwiftUI
import RenewShared

/// Creates or edits a saved block session: what to block, and either a
/// length (started by hand) or set times on chosen days (starts on its own).
struct BlockSessionEditor: View {
    @ObservedObject var model: AppModel
    let original: BlockSession
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var lists: Set<String>
    @State private var extra: String
    @State private var scheduled: Bool
    @State private var minutes: Int
    @State private var start: Date
    @State private var end: Date
    @State private var days: Weekdays
    @State private var enabled: Bool
    @State private var confirmingSave = false

    init(model: AppModel, session: BlockSession) {
        self.model = model
        original = session
        _name = State(initialValue: session.name)
        _lists = State(initialValue: Set(session.lists))
        _extra = State(initialValue: session.extraSites.joined(separator: ", "))
        _enabled = State(initialValue: session.enabled)
        switch session.timing {
        case .length(let m):
            _scheduled = State(initialValue: false)
            _minutes = State(initialValue: m)
            _start = State(initialValue: Self.date(9 * 60))
            _end = State(initialValue: Self.date(17 * 60))
            _days = State(initialValue: .weekdays)
        case let .schedule(window, days):
            _scheduled = State(initialValue: true)
            _minutes = State(initialValue: 60)
            _start = State(initialValue: Self.date(window.startMinute))
            _end = State(initialValue: Self.date(window.endMinute))
            _days = State(initialValue: days)
        }
    }

    private var isNew: Bool { !model.savedSessions.contains { $0.id == original.id } }

    private var sites: [String] {
        parseSites(extra)
    }

    private var rejectedSites: [String] { canonicalRules(sites).rejected }

    private var window: DailyWindow { DailyWindow(startMinute: Self.minute(start), endMinute: Self.minute(end)) }

    private var draft: BlockSession {
        BlockSession(id: original.id,
                     name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                     lists: lists.sorted(),
                     extraSites: canonicalRules(sites).valid,
                     timing: scheduled ? .schedule(window: window, days: days) : .length(minutes: minutes),
                     enabled: enabled)
    }

    private var problem: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give it a name." }
        if !rejectedSites.isEmpty { return "Not a valid site: \(rejectedSites.joined(separator: ", "))" }
        if draft.rules(in: model.lists).isEmpty { return "Choose a blocklist or add a site." }
        if scheduled {
            if !days.isValid { return "Choose at least one day." }
            if !window.isValid { return "Start and end times must be different." }
        } else if minutes < 1 {
            return "Choose at least 1 minute."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(isNew ? "New block session" : "Edit block session")
                        .font(.title.weight(.bold))

                    Card(title: "NAME") {
                        TextField("e.g. Work hours, Evenings, Deep work", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    Card(title: "WHEN") {
                        Picker("Timing", selection: $scheduled) {
                            Text("Length").tag(false)
                            Text("Set times").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if scheduled { scheduleControls } else { lengthControls }
                    }

                    Card(title: "WHAT TO BLOCK") {
                        BlocklistPicker(model: model, selection: $lists, extra: $extra)
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                } else {
                    let n = draft.rules(in: model.lists).count
                    Text("\(n) site\(n == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Save" : "Save changes") {
                    if startsNow { confirmingSave = true } else { save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
                .confirmationDialog(startsNowTitle, isPresented: $confirmingSave) {
                    Button("Save and start blocking") { save() }
                } message: {
                    Text("This schedule's window is open now, so saving starts a block session right away. It can't be stopped until the window ends.")
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
    }

    /// Saving this draft starts blocking at once (its window is open now).
    private var startsNow: Bool { scheduled && enabled && model.opensNow(draft) }

    private var startsNowTitle: String {
        let end = Schedule(name: name, window: window, days: days, rules: []).activeWindowEnd(at: Date())
        return "Block until \(end.map(Format.clock) ?? "the end time")?"
    }

    private func save() {
        model.saveSession(draft)
        dismiss()
    }

    // MARK: timing

    @ViewBuilder private var lengthControls: some View {
        HStack(spacing: 8) {
            ForEach([25, 60, 120, 240], id: \.self) { m in
                PillButton(title: Format.minutes(m), selected: minutes == m) { minutes = m }
            }
        }
        DurationPicker(minutes: $minutes)
        Text("Start it by hand from the list. It blocks for this long once started.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var scheduleControls: some View {
        HStack(spacing: 20) {
            DatePicker("From", selection: $start, displayedComponents: .hourAndMinute)
            DatePicker("To", selection: $end, displayedComponents: .hourAndMinute)
            if window.isOvernight && window.isValid {
                Text("ends the next day")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()

        HStack(spacing: 6) {
            ForEach(Weekdays.orderedCalendarWeekdays(), id: \.self) { wd in
                PillButton(title: Calendar.current.shortWeekdaySymbols[wd - 1],
                           selected: days.contains(calendarWeekday: wd), minWidth: 34) {
                    let day = Weekdays(calendarWeekday: wd)
                    if days.contains(day) { days.remove(day) } else { days.insert(day) }
                }
            }
        }
        HStack(spacing: 14) {
            Button("Weekdays") { days = .weekdays }
            Button("Weekends") { days = .weekend }
            Button("Every day") { days = .everyDay }
        }
        .buttonStyle(.link)

        Toggle("Scheduled (turn off to pause it without deleting)", isOn: $enabled)
            .toggleStyle(.checkbox)

        Text(scheduleExplanation)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var scheduleExplanation: String {
        guard window.isValid, days.isValid else {
            return "Starts on its own at the start time on the chosen days and blocks until the end time."
        }
        var text = "Blocks \(days.summary()) from \(DailyWindow.timeText(window.startMinute)) to \(DailyWindow.timeText(window.endMinute))"
        text += window.isOvernight ? " the next day." : "."
        let schedule = Schedule(name: name, window: window, days: days, rules: [])
        if enabled, schedule.activeWindowEnd(at: model.now) != nil {
            text += " This window is open now, so saving starts blocking right away."
        } else if enabled, let next = schedule.nextStart(after: model.now) {
            text += " Next start: \(Format.dayAndTime(next))."
        }
        return text + " Once it starts, it can't be stopped early."
    }

    // MARK: helpers

    private static func date(_ minute: Int) -> Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: cal.startOfDay(for: Date())) ?? Date()
    }

    private static func minute(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
