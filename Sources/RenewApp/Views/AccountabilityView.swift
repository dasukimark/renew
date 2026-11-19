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
    @State private var confirmingOff = false

    var body: some View {
        Form {
            if showTurnOnMonitoring {
                Section {
                    InfoBanner(title: "Turn on monitoring",
                               message: "Flag visits to explicit sites and explicit content, and email your partners about them. Once it's on, it can't be turned off or watch less while you have a partner.",
                               button: "Turn On") { turnOnMonitoring() }
                        .disabled(model.busy)
                }
            }
            partnerSection
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
            Button("Request removal", role: .destructive) {
                if let email = removing { remove(email) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            if let email = removing, model.retainedReportPartners.contains(email) {
                Text("Renew keeps checking in while your partner reviews the new request.")
            } else {
                Text("Your partner is emailed a link to approve. Reports keep going to this address until a partner approves; if they decline, nothing changes.")
            }
        }
        .confirmationDialog("Turn off email reports?", isPresented: $confirmingOff) {
            Button("Turn off", role: .destructive) {
                model.setReports(partnerEmails: nil) { _ in model.loadPartnerHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your partners are emailed a link to approve. Reports keep going to them until one approves; if they decline, nothing changes.")
        }
    }

    // MARK: monitoring

    /// Only with a partner who isn't being removed, and a service that
    /// keeps Activity on with the Monitor (it reports the lock).
    private var showTurnOnMonitoring: Bool {
        model.hasSettledPartner && model.daemonReachable && model.monitorSupported && model.activitySupported
            && model.status?.monitoringLocked != nil && !model.monitor.enabled
    }

    /// renewd turns Activity on with it: the Monitor checks what it records.
    private func turnOnMonitoring() {
        var m = model.monitor
        m.enabled = true
        if !m.watchLists.contains(MonitorSettings.explicitListName) { m.watchLists.append(MonitorSettings.explicitListName) }
        m.flagExplicitTerms = true
        model.setMonitor(m)
    }

    // MARK: partners (email reports)

    private var reportsOn: Bool { !model.reportsPartners.isEmpty }
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
                HStack {
                    Text(email)
                        .textSelection(.enabled)
                    Spacer()
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
                HStack {
                    Text(email)
                        .textSelection(.enabled)
                    Spacer()
                    statusDot("Removal waiting for approval", .orange)
                }
            }
            ForEach(model.retainedReportPartners.filter { !model.pendingReportPartners.contains($0) }, id: \.self) { email in
                HStack {
                    Text(email)
                        .textSelection(.enabled)
                    Spacer()
                    statusDot("Monitoring retained", .green)
                    Button("Request again") { removing = email }
                        .disabled(inSession || model.busy || !model.daemonReachable)
                }
            }
            if model.reportsPartners.count < ReportDestination.maxPartners {
                HStack {
                    TextField("Partner's email address", text: $newPartner)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canAdd { add() } }
                    Button(reportsOn ? "Add" : "Turn on reports") { add() }
                        .disabled(!canAdd)
                }
                .disabled(!model.daemonReachable)
            }
            if showServerFields {
                TextField("Report server URL", text: $reportURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(inSession && reportsOn)
                SecureField(reportsOn ? "New report token" : "Report token", text: $reportTokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(inSession && reportsOn)
                if reportsOn {
                    Button("Save server") { saveServer() }
                        .disabled(!canSaveServer)
                }
            }
            if reportsOn {
                HStack {
                    Button("Turn off") { confirmingOff = true }
                        .disabled(inSession || model.busy || !model.daemonReachable)
                    Button("Send test") {
                        model.testReport()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { model.loadPartnerHistory() }
                    }
                    .disabled(model.busy)
                    Spacer()
                    statusDot("On", .green)
                }
            }
            if reportsOn && inSession {
                Text("Partners can be added during a session, and removed after it ends.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Partners")
        } footer: {
            if !model.pendingReportPartners.isEmpty {
                Text("Addresses waiting for approval still get email reports and check-in alerts until a partner approves removing them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !reportsOn && !model.retainedReportPartners.isEmpty {
                Text("A partner declined the request. Renew continues checking in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !reportsOn && !model.reportServerBuiltIn {
                Text("No report server is set up on this Mac. See server/reports/README.md, or enter a server's URL and token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                ForEach(model.partnerHistory) { entry in
                    PartnerHistoryRow(entry: entry)
                }
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
        } footer: {
            Text("The last \(PartnerLog.maxEntries), newest first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PartnerHistoryRow: View {
    let entry: PartnerLogEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .lineLimit(expanded ? nil : 1)
                        .fixedSize(horizontal: false, vertical: expanded)
                    Text("\(channelName) · \(Format.clock(entry.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusView
                if !entry.lines.isEmpty {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help(expanded ? "Show less" : "Show details")
                }
            }
            if expanded && !entry.lines.isEmpty {
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
        case .sent: statusDot("Sent", .green)
        case .waiting: statusDot("Waiting", .orange)
        case .failed: statusDot("Failed", .red)
        }
    }
}
