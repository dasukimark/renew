import SwiftUI
import RenewShared

/// Accountability: your partners, what the Monitor watches for them, and
/// what it flagged. Monitoring only makes sense with someone to tell, so it
/// lives here: it needs a partner to turn on, and while there is one it
/// can't be turned off or watch less.
struct AccountabilityView: View {
    @ObservedObject var model: AppModel

    enum Tab: String, CaseIterable, Identifiable {
        case partners = "Partners"
        case monitoring = "Monitoring"
        case flags = "Flags"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.accountabilityTab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.vertical, 10)
            Divider()
            switch model.accountabilityTab {
            case .partners: PartnersView(model: model)
            case .monitoring: MonitorSettingsView(model: model)
            case .flags: MonitorFlagsView(model: model)
            }
        }
        .navigationTitle("Accountability")
        .navigationSubtitle(summary)
    }

    /// Who you answer to and what the Monitor is doing, on every tab.
    private var summary: String {
        let settled = model.reportsPartners.filter { !model.pendingReportPartners.contains($0) }
        var parts: [String] = []
        switch settled.count {
        case 0:
            let retained = model.retainedReportPartners.filter { !model.pendingReportPartners.contains($0) }
            if retained.count == 1 {
                parts.append("Monitored by \(retained[0])")
            } else if !retained.isEmpty {
                parts.append("Monitored by \(retained.count) partners")
            } else {
                parts.append(model.pendingReportPartners.isEmpty ? "No partner" : "Partner removal pending")
            }
        case 1: parts.append("Reporting to \(settled[0])")
        default: parts.append("Reporting to \(settled.count) partners")
        }
        if model.monitorSupported {
            parts.append(model.monitor.enabled ? "Monitor on" : "Monitor off")
        }
        if model.monitoringLocked { parts.append("Locked") }
        return parts.joined(separator: " · ")
    }
}

/// Everything your accountability partners hear about: email reports (with
/// check-ins), and a history of what they were told.
private struct PartnersView: View {
    @ObservedObject var model: AppModel
    @State private var newPartner = ""
    @State private var reportURLDraft = ""
    @State private var reportTokenDraft = ""
    @State private var removing: String?
    /// The page of history shown, from 0 (newest).
    @State private var historyPage = 0
    private static let historyPageSize = 10

    var body: some View {
        Form {
            if showTurnOnMonitoring {
                Section {
                    NoticeRow(title: "Turn on monitoring",
                              message: "Flag explicit content and email your partners. It stays on while you have a partner.",
                              button: "Turn On", icon: "eye") { turnOnMonitoring() }
                        .disabled(model.busy)
                }
            }
            partnerSection
            if showServerFields { serverSection }
            historySection
        }
        .formStyle(.grouped)
        .onAppear {
            reportURLDraft = model.reportsURL ?? ""
            model.loadPartnerHistory()
        }
        .onChange(of: model.reportsURL) { reportURLDraft = $0 ?? "" }
        .confirmationDialog("Remove \(removing ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(removingUnconfirmed ? "Remove" : "Request removal", role: .destructive) {
                if let email = removing { remove(email) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            if let email = removing, model.retainedReportPartners.contains(email) {
                Text("Renew keeps checking in while your partner reviews the new request.")
            } else if removingUnconfirmed {
                Text("They haven't confirmed being your partner, so they're removed without approval.")
            } else {
                Text("Your partner is asked to approve. Until then, reports keep going to this address.")
            }
        }
    }

    // MARK: monitoring

    /// Only with a partner who isn't being removed, and a service that
    /// keeps Activity on with the Monitor (it reports the lock).
    private var showTurnOnMonitoring: Bool {
        model.hasSettledPartner && model.daemonReachable && model.monitorListsSupported && model.activitySupported
            && model.status?.monitoringLocked != nil && !model.monitor.enabled
    }

    /// renewd turns Activity on with it: the Monitor checks what it records.
    private func turnOnMonitoring() {
        var m = model.monitor
        m.enabled = true
        m.flagExplicit = true
        model.setMonitor(m)
    }

    // MARK: partners (email reports)

    private var reportsOn: Bool { !model.reportsPartners.isEmpty }
    private var removingUnconfirmed: Bool { removing.map { model.unconfirmedReportPartners.contains($0) } ?? false }
    private var inSession: Bool { model.session != nil }
    /// Server fields only without a built-in server, or when reports
    /// already use a different one (to change its token, or leave it).
    private var showServerFields: Bool { !model.reportServerBuiltIn || model.reportsURL != nil }
    /// Leaving the URL empty means the built-in server.
    private var draftURL: String? {
        let u = reportURLDraft.trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? nil : u
    }

    private var partnerSection: some View {
        Section {
            ForEach(model.reportsPartners.filter { !model.pendingReportPartners.contains($0) }, id: \.self) { email in
                partnerRow(email) {
                    if model.unconfirmedReportPartners.contains(email) {
                        statusDot("Waiting for them to confirm", .yellow)
                    }
                    Button {
                        removing = email
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(inSession ? "Partners can be removed after the current session ends" : "Remove this partner")
                    .disabled(inSession || model.busy || !model.daemonReachable)
                }
            }
            ForEach(model.pendingReportPartners, id: \.self) { email in
                partnerRow(email) { statusDot("Removal waiting for approval", .orange) }
            }
            ForEach(model.retainedReportPartners.filter { !model.pendingReportPartners.contains($0) }, id: \.self) { email in
                partnerRow(email) {
                    statusDot("Monitoring retained", .green)
                    Button("Request Again…") { removing = email }
                        .disabled(inSession || model.busy || !model.daemonReachable)
                }
            }
            if model.reportsPartners.count < ReportDestination.maxPartners {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    TextField("Partner's email", text: $newPartner,
                              prompt: Text(reportsOn ? "Add a partner's email" : "Your partner's email"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canAdd { add() } }
                    Button("Add") { add() }
                        .disabled(!canAdd)
                }
                .disabled(!model.daemonReachable)
            }
        } header: {
            Text("Partners")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if reportsOn && inSession {
                    Text("Partners can be removed after this session.")
                }
                if !reportsOn && model.retainedReportPartners.isEmpty {
                    Text("Your partner is emailed about flags, loosened monitoring, and if Renew stops running.")
                }
                if !model.unconfirmedReportPartners.isEmpty {
                    Text("New partners get an email asking them to confirm. Until they do, you can remove them without approval.")
                }
                if !model.pendingReportPartners.isEmpty {
                    Text("Partners waiting on removal still get reports until it's approved.")
                }
                if !reportsOn && !model.retainedReportPartners.isEmpty {
                    Text("A partner declined the request. Renew continues checking in.")
                }
                if !reportsOn && !model.reportServerBuiltIn {
                    Text("No report server is set up. Enter one below.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func partnerRow<Trailing: View>(_ email: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(email)
                .textSelection(.enabled)
            Spacer()
            trailing()
        }
    }

    private var serverSection: some View {
        Section {
            TextField("Server URL", text: $reportURLDraft, prompt: Text("https://…"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(inSession && reportsOn)
            SecureField(reportsOn ? "New token" : "Token", text: $reportTokenDraft)
                .textFieldStyle(.roundedBorder)
                .disabled(inSession && reportsOn)
            if reportsOn {
                HStack {
                    Spacer()
                    Button("Save Server") { saveServer() }
                        .disabled(!canSaveServer)
                }
            }
        } header: {
            Text("Report server")
        }
    }

    private var canAdd: Bool {
        guard !model.busy, model.daemonReachable,
              let email = ReportDestination.normalizeEmail(newPartner),
              !model.reportsPartners.contains(email), !model.pendingReportPartners.contains(email) else { return false }
        // Adding to running reports keeps their server.
        if reportsOn { return true }
        if let _ = draftURL { return !reportTokenDraft.trimmingCharacters(in: .whitespaces).isEmpty }
        return model.reportServerBuiltIn
    }

    private var canSaveServer: Bool {
        guard reportsOn, !inSession, !model.busy, model.daemonReachable else { return false }
        if draftURL == nil { return model.reportServerBuiltIn && model.reportsURL != nil }
        return !reportTokenDraft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func saveServer() {
        model.setReports(partnerEmails: model.reportsPartners, url: draftURL,
                         token: draftURL == nil ? nil : reportTokenDraft) { ok in
            if ok { reportTokenDraft = "" }
            model.loadPartnerHistory()
        }
    }

    private func add() {
        let partners = model.reportsPartners + [newPartner.trimmingCharacters(in: .whitespaces)]
        // Running reports keep their server (renewd keeps its token).
        let url = reportsOn ? model.reportsURL : draftURL
        let token = reportsOn || url == nil ? nil : reportTokenDraft
        model.setReports(partnerEmails: partners, url: url, token: token) { ok in
            if ok {
                newPartner = ""
                reportTokenDraft = ""
            }
            model.loadPartnerHistory()
        }
    }

    private func remove(_ email: String) {
        if model.retainedReportPartners.contains(email) {
            model.requestMonitoringRemoval(email)
            return
        }
        let rest = model.reportsPartners.filter { $0 != email }
        model.setReports(partnerEmails: rest.isEmpty ? nil : rest, url: model.reportsURL) { _ in
            model.loadPartnerHistory()
        }
    }

    // MARK: history

    private var historySection: some View {
        Section {
            if let error = model.partnerHistoryError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if model.partnerHistory.isEmpty {
                Text(model.loadingPartnerHistory ? "Loading…" : "Nothing has been sent to your partners yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(historyEntries) { entry in
                    PartnerHistoryRow(entry: entry)
                }
                if historyPageCount > 1 { historyPager }
            }
        } header: {
            HStack {
                Text("Sent to your partners")
                Spacer()
                Button {
                    model.loadPartnerHistory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .disabled(model.loadingPartnerHistory)
            }
        }
    }

    private var historyPageCount: Int {
        max(1, (model.partnerHistory.count + Self.historyPageSize - 1) / Self.historyPageSize)
    }

    /// The page asked for, kept in range as the history changes.
    private var currentHistoryPage: Int { min(historyPage, historyPageCount - 1) }

    private var historyEntries: ArraySlice<PartnerLogEntry> {
        let all = model.partnerHistory
        let start = currentHistoryPage * Self.historyPageSize
        return all[min(start, all.count)..<min(start + Self.historyPageSize, all.count)]
    }

    private var historyPager: some View {
        let page = currentHistoryPage
        let first = page * Self.historyPageSize + 1
        let last = first + historyEntries.count - 1
        return HStack(spacing: 8) {
            Text("\(first)–\(last) of \(model.partnerHistory.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if page > 0 {
                Button("Newest") { historyPage = 0 }
                    .buttonStyle(.link)
            }
            ControlGroup {
                Button { historyPage = page - 1 } label: { Image(systemName: "chevron.left") }
                    .help("Newer")
                    .disabled(page == 0)
                Button { historyPage = page + 1 } label: { Image(systemName: "chevron.right") }
                    .help("Older")
                    .disabled(page >= historyPageCount - 1)
            }
            .fixedSize()
        }
    }
}

private struct PartnerHistoryRow: View {
    let entry: PartnerLogEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            // Outside the tap target, so the lines can be selected and copied.
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(channelName) · \(Format.clock(entry.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            statusView
            // Always takes the space, so statuses line up down the list.
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 14)
                .opacity(expandable ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .help(expandable ? (expanded ? "Show less" : "Show details") : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(expandable ? .isButton : [])
        .accessibilityHint(expandable ? (expanded ? "Hides details" : "Shows details") : "")
        .accessibilityAction { toggle() }
    }

    private func toggle() {
        guard expandable else { return }
        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
    }

    private var expandable: Bool { !entry.lines.isEmpty }

    private var icon: String {
        switch entry.channel {
        case .email: return "envelope"
        case .alert: return "bell"
        case .checkin: return "heart.text.square"
        }
    }

    private var channelName: String {
        switch entry.channel {
        case .email: return "Email"
        case .alert: return "Instant alert"
        case .checkin: return "Check-in email"
        }
    }

    @ViewBuilder private var statusView: some View {
        switch entry.status {
        // Sent is the usual case, so it stays quiet; problems stand out.
        case .sent: Text("Sent").foregroundStyle(.secondary)
        case .waiting: statusDot("Waiting", .orange)
        case .failed: statusDot("Failed", .red)
        }
    }
}
