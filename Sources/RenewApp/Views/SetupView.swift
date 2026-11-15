import SwiftUI
import RenewShared

struct SetupView: View {
    @ObservedObject var model: AppModel
    @State private var showingProfile = false
    @State private var showingUninstall = false
    @State private var confirmingRequest = false
    @State private var alertDraft = ""

    var body: some View {
        Form {
            serviceSection
            permissionsSection
            profileSection
            alertsSection
            uninstallSection
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .onAppear {
            model.refreshPermissions()
            alertDraft = model.alertURL ?? ""
        }
        .onChange(of: model.alertURL) { alertDraft = $0 ?? "" }
        .sheet(isPresented: $showingProfile) { ProfileSheet() }
        .sheet(isPresented: $showingUninstall) { UninstallSheet(model: model) }
    }

    // MARK: service

    private var serviceSection: some View {
        Section {
            LabeledContent("Background service") {
                if model.isLocalTest {
                    status("Local test run", .secondary)
                } else if !model.isInstalled {
                    status("Not installed", .secondary)
                } else if model.daemonReachable {
                    status("Running", .green)
                } else {
                    status("Not responding", .orange)
                }
            }
            if model.isInstalled {
                LabeledContent("Installed at", value: Paths.agentApp)
            }
            if !model.isRunningInstalledCopy && !model.isLocalTest {
                VStack(alignment: .leading, spacing: 8) {
                    Button(model.isInstalled ? "Update the installed Renew…" : "Install Renew…") {
                        model.install()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.session != nil)
                    Text("Copies Renew to your Applications folder and installs the background service that enforces sessions. macOS asks for your password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.session != nil {
                        Text("Updating is allowed after the current session ends.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Renew")
        }
    }

    // MARK: permissions

    private var permissionsSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "accessibility")
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility")
                    Text("Needed to watch Firefox and to close blocked tabs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.accessibilityGranted {
                    status("Allowed", .green)
                } else {
                    Button("Allow…") {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }
            }

            ForEach(model.browsers) { b in
                HStack(spacing: 12) {
                    if let icon = b.icon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.name)
                        Text(b.kind == .firefox ? "Watched through Accessibility" : "Automation: lets Renew read and replace the current tab")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    browserControl(b)
                }
            }

            HStack {
                Button("Refresh") { model.refreshPermissions() }
                Spacer()
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("During a session, Renew closes any browser it isn't allowed to watch, and keeps it closed until the session ends or the permission is turned back on. Browsers it doesn't support (Opera, Orion, Zen, Tor, DuckDuckGo…) are closed during sessions too.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func browserControl(_ b: BrowserPermission) -> some View {
        if b.kind == .firefox {
            if model.accessibilityGranted { status("Ready", .green) } else { status("Needs Accessibility", .orange) }
        } else {
            switch b.state {
            case .allowed:
                status("Allowed", .green)
            case .denied:
                HStack {
                    status("Not allowed", .red)
                    Button("Open Settings") { Permissions.openAutomationSettings() }
                }
            case .notAsked:
                Button("Allow…") { model.askAutomation(b.bundleID) }
            case .notRunning:
                Button("Open \(b.name) to check") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleID) {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.askAutomation(b.bundleID) }
                        }
                    }
                }
            case .unknown:
                Button("Check again") { model.askAutomation(b.bundleID) }
            }
        }
    }

    // MARK: profile

    private var profileSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Optional extra. The profile turns off private/incognito windows in Chrome, Edge, Brave, Vivaldi and Firefox, and locks Renew's background items on. It can only be removed with a password, which you hand to someone else. It stays in place outside sessions too, until you remove it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Create lock-down profile…") { showingProfile = true }
            }
        } header: {
            Text("Lock-down profile")
        }
    }

    // MARK: alerts

    /// Alerts can be turned on any time, but changed or turned off only
    /// between sessions (renewd enforces this too).
    private var alertsLocked: Bool { model.session != nil && model.alertURL != nil }

    private var alertsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Renew messages someone you trust if it's stopped, its files are tampered with, or the clock is changed during a focus session, and when an uninstall is requested or done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("https://ntfy.sh/your-secret-topic", text: $alertDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(alertsLocked || !model.daemonReachable)
                HStack {
                    Button(model.alertURL == nil ? "Turn on alerts" : "Save") {
                        model.setAlerts(alertDraft)
                    }
                    .disabled(alertsLocked || model.busy || !model.daemonReachable
                              || alertDraft.trimmingCharacters(in: .whitespaces).isEmpty
                              || alertDraft == (model.alertURL ?? ""))
                    if model.alertURL != nil {
                        Button("Send test") { model.testAlert() }
                            .disabled(model.busy)
                        Button("Turn off") { model.setAlerts(nil) }
                            .disabled(alertsLocked || model.busy)
                    }
                    Spacer()
                    if model.alertURL != nil { status("On", .green) } else { status("Off", .secondary) }
                }
                if alertsLocked {
                    Text("Alerts can be changed after the current session ends.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Accountability alerts")
        } footer: {
            Text("Free and no account needed: your partner installs the ntfy app and subscribes to a hard-to-guess topic, and you enter https://ntfy.sh/<that topic> here. Discord and Slack webhook URLs work too. When the destination changes or alerts are turned off, the old destination is told.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: uninstall

    private var uninstallSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall Renew")
                    Text(uninstallCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.uninstallRequest != nil {
                    Button("Cancel request") { model.cancelUninstall() }
                        .disabled(model.busy)
                }
                if model.uninstallUnlocked {
                    Button("Uninstall…", role: .destructive) { showingUninstall = true }
                        .disabled(!model.isInstalled || model.session != nil || model.busy)
                } else if model.uninstallRequest == nil {
                    Button("Request uninstall…") { confirmingRequest = true }
                        .disabled(!model.isInstalled || !model.daemonReachable || model.busy)
                }
            }
        } footer: {
            Text("Uninstalling has a 24-hour cooling-off period. Once it unlocks, it stays available for 2 days, between focus sessions only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Request uninstall?", isPresented: $confirmingRequest) {
            Button("Request uninstall") { model.requestUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renew keeps working as normal. You can uninstall it 24 hours from now, between focus sessions.\(model.alertURL != nil ? " Your accountability partner is told." : "")")
        }
    }

    private var uninstallCaption: String {
        guard let u = model.uninstallRequest else { return "Removes the app and its background service, after a 24-hour wait." }
        if model.uninstallUnlocked {
            let until = "Available until \(Format.clock(u.expiresAt))."
            return model.session != nil ? "\(until) Not available during a focus session." : until
        }
        let left = DurationText.format(Int(u.unlocksAt.timeIntervalSince(model.now)))
        return "Requested. Unlocks at \(Format.clock(u.unlocksAt)) (in \(left))."
    }

    private func status(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sheets

private struct ProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ProfileBuilder.randomPassword()
    @State private var savedURL: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lock-down profile").font(.title2.weight(.bold))
            Text("This is the profile's removal password. Write it down and give it to someone you trust, or seal it away. Without it, the profile can't be removed.")
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(password)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(password, forType: .string)
                }
                Button("New password") { password = ProfileBuilder.randomPassword(); savedURL = nil }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click **Save & open profile**. macOS saves it to Downloads and says it's ready to review.")
                Text("2. In **System Settings → General → Device Management**, double-click Renew and click Install.")
                Text("3. Come back and click **Delete profile file**, because the file contains the password in plain text.")
            }
            .font(.callout)

            if let error { Text(error).foregroundStyle(.red).font(.callout) }

            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if let url = savedURL {
                    Button("Open Device Management") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                    Button("Delete profile file") {
                        try? FileManager.default.removeItem(at: url)
                        savedURL = nil
                        dismiss()
                    }
                } else {
                    Button("Save & open profile") {
                        do {
                            let url = try ProfileBuilder.write(password: password)
                            savedURL = url
                            NSWorkspace.shared.open(url)
                        } catch {
                            self.error = "Couldn't write the profile: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Text("On recent macOS versions the background-items lock may only apply when the profile comes from a device-management (MDM) server. The password and the browser settings work either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct UninstallSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var phrase: String = {
        let words = ["anchor", "harbor", "lantern", "meadow", "quiet", "river", "summit", "willow", "ember",
                     "falcon", "granite", "horizon", "island", "juniper", "kettle", "linen", "marble", "nectar",
                     "orchard", "pebble", "quartz", "saddle", "timber", "velvet", "walnut", "zephyr"]
        return (0..<8).map { _ in words.randomElement()! }.joined(separator: " ")
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall Renew?").font(.title2.weight(.bold))
            Text("To confirm, type this phrase exactly:")
            Text(phrase)
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            TextField("Type the phrase", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Text("If you installed the lock-down profile, remove it afterwards in System Settings → General → Device Management. It needs its removal password.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Uninstall", role: .destructive) {
                    dismiss()
                    model.uninstall()
                }
                .disabled(typed.trimmingCharacters(in: .whitespaces) != phrase)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
