import SwiftUI
import RenewShared

struct FocusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                banners
                if let session = model.session {
                    ActiveSessionView(model: model, session: session)
                } else {
                    StartSessionView(model: model)
                }
            }
            .padding(32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Focus")
    }

    @ViewBuilder private var banners: some View {
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
                       + ". During a session, Renew closes any browser it can't watch.",
                   actionTitle: "Fix") { model.section = .setup }
        }
    }
}

// MARK: - Start

private struct StartSessionView: View {
    @ObservedObject var model: AppModel
    @State private var extra = ""
    @State private var confirming = false
    @State private var custom = false

    private let presets = [25, 60, 120, 240]

    private var rules: [String] { model.rules(forSelection: model.selectedLists, extra: extra) }
    private var endsAt: Date { model.now.addingTimeInterval(TimeInterval(model.durationMinutes * 60)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Start a focus session")
                    .font(.largeTitle.weight(.bold))
                Text("Choose how long and what to block. Once a session starts, it can't be stopped early.")
                    .foregroundStyle(.secondary)
            }

            Card(title: "HOW LONG") {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { m in
                        durationButton(Format.minutes(m), selected: !custom && model.durationMinutes == m) {
                            custom = false
                            model.durationMinutes = m
                        }
                    }
                    durationButton("Custom", selected: custom) { custom = true }
                }
                if custom {
                    HStack(spacing: 16) {
                        Stepper(value: hoursBinding, in: 0...23) { Text("\(model.durationMinutes / 60) h") }
                        Stepper(value: minutesBinding, in: 0...55, step: 5) { Text("\(model.durationMinutes % 60) min") }
                    }
                }
                Text("Ends at \(Format.clock(endsAt))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Card(title: "WHAT TO BLOCK") {
                ForEach(model.sortedListNames, id: \.self) { name in
                    Toggle(isOn: listBinding(name)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name.capitalized).font(.body.weight(.medium))
                            Text((model.lists[name] ?? []).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Divider()
                TextField("Also block… e.g. reddit.com, youtube.com/shorts", text: $extra)
                    .textFieldStyle(.roundedBorder)
                Button("Edit blocklists…") { model.section = .lists }
                    .buttonStyle(.link)
            }

            Button {
                confirming = true
            } label: {
                Label(rules.isEmpty ? "Choose something to block" : "Start focus session · \(rules.count) site\(rules.count == 1 ? "" : "s")",
                      systemImage: "lock.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(rules.isEmpty || model.busy || !(model.daemonReachable || model.isLocalTest) || model.durationMinutes < 1)
            .confirmationDialog("Lock in until \(Format.clock(endsAt))?", isPresented: $confirming) {
                Button("Start \(Format.minutes(model.durationMinutes)) session") {
                    model.start(minutes: model.durationMinutes, rules: rules) { ok in
                        if ok { extra = "" }
                    }
                }
            } message: {
                Text("You won't be able to stop or shorten this session. You can only add time or block more sites.")
            }
        }
        .onAppear { custom = !presets.contains(model.durationMinutes) }
    }

    private func durationButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(minWidth: 64)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func listBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { model.selectedLists.contains(name) },
                set: { on in
                    if on { model.selectedLists.insert(name) } else { model.selectedLists.remove(name) }
                })
    }

    private var hoursBinding: Binding<Int> {
        Binding(get: { model.durationMinutes / 60 },
                set: { model.durationMinutes = max(1, $0 * 60 + model.durationMinutes % 60) })
    }

    private var minutesBinding: Binding<Int> {
        Binding(get: { model.durationMinutes % 60 },
                set: { model.durationMinutes = max(1, (model.durationMinutes / 60) * 60 + $0) })
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
                    Text("Focus session ends at \(Format.clock(session.endsAt))")
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

            Label("Sessions can't be shortened or stopped. That's the point.", systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func addSite() {
        let parts = newSite.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard !parts.isEmpty else { return }
        let (valid, rejected) = canonicalRules(parts)
        if !rejected.isEmpty {
            model.errorMessage = "Not a valid site: \(rejected.joined(separator: ", "))"
            return
        }
        model.add(rules: valid) { ok in if ok { newSite = "" } }
    }
}
