import SwiftUI
import RenewShared

/// Everything your accountability partner hears about: email reports (with
/// check-ins), instant alerts, and a history of what they were told.
struct AccountabilityView: View {
    @ObservedObject var model: AppModel
    @State private var alertDraft = ""
    @State private var reportURLDraft = ""
    @State private var reportPartnerDraft = ""
    @State private var reportTokenDraft = ""

    var body: some View {
        Form {
            partnerSection
            alertsSection
            historySection
        }
        .formStyle(.grouped)
        .navigationTitle("Accountability")
        .onAppear {
            alertDraft = model.alertURL ?? ""
            reportURLDraft = model.reportsURL ?? ""
            reportPartnerDraft = model.reportsPartner ?? ""
            model.loadPartnerHistory()
        }
        .onChange(of: model.alertURL) { alertDraft = $0 ?? "" }
        .onChange(of: model.reportsURL) { reportURLDraft = $0 ?? "" }
        .onChange(of: model.reportsPartner) { reportPartnerDraft = $0 ?? "" }
    }

    // MARK: partner (email reports)

    private var reportsOn: Bool { model.reportsPartner != nil }
    /// Turned on any time, but changed or turned off only between sessions
    /// (renewd enforces this too).
    private var reportsLocked: Bool { model.session != nil && reportsOn }
    /// The server fields show only without a built-in server, or when
    /// reports already use a different one.
    private var showServerFields: Bool { !model.reportServerBuiltIn || model.reportsURL != nil }

    private var partnerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Renew emails your accountability partner when the Monitor flags a visit, and when Activity or the Monitor is turned off or watches less. Emails name the site, the page title, why it was flagged and when, never the full address.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Partner's email address", text: $reportPartnerDraft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(reportsLocked || !model.daemonReachable)
                if showServerFields {
                    TextField("Report server URL", text: $reportURLDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(reportsLocked || !model.daemonReachable)
                    SecureField("Report token", text: $reportTokenDraft)
                        .textFieldStyle(.roundedBorder)
                        .disabled(reportsLocked || !model.daemonReachable)
                }
                HStack {
                    Button(reportsOn ? "Save" : "Turn on reports") {
                        let custom = showServerFields && !reportURLDraft.trimmingCharacters(in: .whitespaces).isEmpty
                        model.setReports(partnerEmail: reportPartnerDraft,
                                         url: custom ? reportURLDraft : nil,
                                         token: custom ? reportTokenDraft : nil) { ok in
                            if ok { reportTokenDraft = "" }
                            model.loadPartnerHistory()
                        }
                    }
                    .disabled(reportsLocked || model.busy || !model.daemonReachable || !canSaveReports)
                    if reportsOn {
                        Button("Send test") {
                            model.testReport()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { model.loadPartnerHistory() }
                        }
                        .disabled(model.busy)
                        Button("Turn off") {
                            model.setReports(partnerEmail: nil) { _ in model.loadPartnerHistory() }
                        }
                        .disabled(reportsLocked || model.busy)
                    }
                    Spacer()
                    if reportsOn { statusDot("On", .green) } else { statusDot("Off", .secondary) }
                }
                if reportsLocked {
                    Text("Email reports can be changed after the current session ends.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Partner")
        } footer: {
            Text(model.reportServerBuiltIn
                 ? "Your partner doesn't need an account; they just get emails. Reports wait on this Mac until they're sent. When the partner changes or reports are turned off, the previous partner gets a last email.\n\nWhile this is on, Renew checks in with the report server about every 4 minutes. If it goes quiet for 10 minutes while the Mac is awake (3 if its service was stopped), or for 7 days after sleeping or shutting down, your partner is emailed. Time the Mac was in use while Renew wasn't running is reported as soon as Renew runs again."
                 : "No report server is set up on this Mac yet: deploy one (see server/reports/README.md), run configure-mac.sh and reinstall Renew, or enter a server's URL and token here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canSaveReports: Bool {
        let partner = reportPartnerDraft.trimmingCharacters(in: .whitespaces)
        guard !partner.isEmpty else { return false }
        if showServerFields {
            let url = reportURLDraft.trimmingCharacters(in: .whitespaces)
            // An empty URL means the built-in server: allowed when one is
            // installed and something changes (the partner, or leaving a
            // different server).
            if url.isEmpty { return model.reportServerBuiltIn && (partner != model.reportsPartner || model.reportsURL != nil) }
            return !reportTokenDraft.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return partner != model.reportsPartner
    }

    // MARK: instant alerts

    /// Same rule as reports (renewd enforces this too).
    private var alertsLocked: Bool { model.session != nil && model.alertURL != nil }

    private var alertsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Renew messages someone you trust if it's stopped, its files are tampered with, or the clock is changed during a block session, and when an uninstall is requested or done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("https://ntfy.sh/your-secret-topic", text: $alertDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(alertsLocked || !model.daemonReachable)
                HStack {
                    Button(model.alertURL == nil ? "Turn on alerts" : "Save") {
                        model.setAlerts(alertDraft) { _ in model.loadPartnerHistory() }
                    }
                    .disabled(alertsLocked || model.busy || !model.daemonReachable
                              || alertDraft.trimmingCharacters(in: .whitespaces).isEmpty
                              || alertDraft == (model.alertURL ?? ""))
                    if model.alertURL != nil {
                        Button("Send test") { model.testAlert() }
                            .disabled(model.busy)
                        Button("Turn off") {
                            model.setAlerts(nil) { _ in model.loadPartnerHistory() }
                        }
                        .disabled(alertsLocked || model.busy)
                    }
                    Spacer()
                    if model.alertURL != nil { statusDot("On", .green) } else { statusDot("Off", .secondary) }
                }
                if alertsLocked {
                    Text("Alerts can be changed after the current session ends.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Instant alerts")
        } footer: {
            Text("Free and no account needed: your partner installs the ntfy app and subscribes to a hard-to-guess topic, and you enter https://ntfy.sh/<that topic> here. Discord and Slack webhook URLs work too. When the destination changes or alerts are turned off, the old destination is told.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text(model.loadingPartnerHistory ? "Loading…" : "Nothing has been sent to your partner yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.partnerHistory) { entry in
                    PartnerHistoryRow(entry: entry)
                }
            }
        } header: {
            HStack {
                Text("Sent to your partner")
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
            Text("The last \(PartnerLog.maxEntries) emails, alerts and check-in emails, newest first. Check-in emails show up after Renew next reaches the report server.")
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
