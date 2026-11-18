import SwiftUI
import RenewShared

struct SetupView: View {
    @ObservedObject var model: AppModel
    @State private var showingUninstall = false
    @State private var confirmingRequest = false

    var body: some View {
        Form {
            serviceSection
            permissionsSection
            protectionsSection
            uninstallSection
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .onAppear {
            model.refreshPermissions()
        }
        .sheet(isPresented: $showingUninstall) { UninstallSheet(model: model) }
    }

    // MARK: service

    private var serviceSection: some View {
        Section {
            LabeledContent("Background service") {
                if model.isLocalTest {
                    statusDot("Local test run", .secondary)
                } else if !model.isInstalled {
                    statusDot("Not installed", .secondary)
                } else if model.daemonReachable {
                    statusDot("Running", .green)
                } else {
                    statusDot("Not responding", .orange)
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
                    statusDot("Allowed", .green)
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
            Text(model.protections.closeUnwatchedBrowsers
                 ? "During a session, Renew closes any browser it isn't allowed to watch, and keeps it closed until the session ends or the permission is turned back on. Browsers it doesn't support (Opera, Orion, Zen, Tor, DuckDuckGo…) are closed during sessions too."
                 : "Renew can only block sites in browsers it's allowed to watch. Browsers it can't watch, or doesn't support (Opera, Orion, Zen, Tor, DuckDuckGo…), aren't blocked unless you turn on \"Close browsers Renew can't watch\" below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func browserControl(_ b: BrowserPermission) -> some View {
        if b.kind == .firefox {
            if model.accessibilityGranted { statusDot("Ready", .green) } else { statusDot("Needs Accessibility", .orange) }
        } else {
            switch b.state {
            case .allowed:
                statusDot("Allowed", .green)
            case .denied:
                HStack {
                    statusDot("Not allowed", .red)
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

    // MARK: protections

    private var protectionsSection: some View {
        Section {
            protectionToggle(\.keepRunning, "Keep Renew running",
                             "During a block session, Renew's background services restart each other and the app if they're stopped, and put back Renew's files if they're deleted or changed.")
            protectionToggle(\.lockSystemSettings, "Lock System Settings switches",
                             "During a block session, switches on System Settings' Login Items and Privacy & Security pages (and Renew's own, on any page) can be turned on but not off. A narrow click filter runs while System Settings is open. Needs Accessibility.")
            protectionToggle(\.closeUnwatchedBrowsers, "Close browsers Renew can't watch",
                             "During a block session, closes browsers Renew has lost permission to watch, browsers it doesn't support, and unknown apps built on Chrome's or Firefox's engine.")
            protectionToggle(\.uninstallCoolingOff, "Uninstall cooling-off",
                             "Uninstalling needs a request and a 24-hour wait. Turning this off takes 24 hours too.")
            if model.isInstalled && model.daemonReachable && !model.protectionsSupported {
                Text("The running background service predates these settings. Update Renew to change them.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Protections")
        } footer: {
            Text("All off unless you turn them on, so Renew acts like an ordinary blocker, fine for a work Mac. Blocking works either way, and a running session still can't be shortened or stopped. During a session, protections can be turned on but not off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func protectionToggle(_ key: WritableKeyPath<Protections, Bool>, _ title: String, _ detail: String) -> some View {
        let isCoolingOff = key == \Protections.uninstallCoolingOff
        let pendingRemoval = isCoolingOff ? model.coolingOffRemovalAt : nil
        // A cooling-off that's on its way out shows as off; switching it on cancels that.
        let isOn = model.requestedProtections[keyPath: key]
        let lockedOn = isOn && model.session != nil && !isCoolingOff
        let binding = Binding<Bool>(
            get: { isOn },
            set: { on in
                var p = model.requestedProtections
                p[keyPath: key] = on
                model.setProtections(p)
            })
        return Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let when = pendingRemoval {
                    Text("Stays on until \(Format.clock(when))\(model.session != nil ? ", or the end of the session if that's later" : ""). Switch it back on to cancel.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if lockedOn {
                    Text("Can be turned off after the current session ends.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .toggleStyle(.switch)
        .disabled(lockedOn || model.busy || !model.daemonReachable || !model.protectionsSupported)
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
                if model.uninstallRequest != nil && coolingOff {
                    Button("Cancel request") { model.cancelUninstall() }
                        .disabled(model.busy)
                }
                if model.uninstallUnlocked || !coolingOff {
                    Button("Uninstall…", role: .destructive) { showingUninstall = true }
                        .disabled(!model.isInstalled || model.session != nil || model.busy)
                } else if model.uninstallRequest == nil {
                    Button("Request uninstall…") { confirmingRequest = true }
                        .disabled(!model.isInstalled || !model.daemonReachable || model.busy)
                }
            }
        } footer: {
            Text(coolingOff
                 ? "Uninstalling has a 24-hour cooling-off period. Once it unlocks, it stays available for 2 days, between block sessions only."
                 : "Uninstalling is allowed between block sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Request uninstall?", isPresented: $confirmingRequest) {
            Button("Request uninstall") { model.requestUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renew keeps working as normal. You can uninstall it 24 hours from now, between block sessions.\(model.reportsPartners.isEmpty ? "" : " Your accountability partners are told.")")
        }
    }

    /// Whether uninstalling needs a request and a wait. Assumed on while the
    /// service can't be reached or predates protections, as the safe reading.
    private var coolingOff: Bool {
        !model.daemonReachable || (model.status?.enforcesCoolingOff ?? true)
    }

    private var uninstallCaption: String {
        if !coolingOff {
            return model.session != nil ? "Not available during a block session." : "Removes the app and its background service."
        }
        guard let u = model.uninstallRequest else { return "Removes the app and its background service, after a 24-hour wait." }
        if model.uninstallUnlocked {
            let until = "Available until \(Format.clock(u.expiresAt))."
            return model.session != nil ? "\(until) Not available during a block session." : until
        }
        let left = DurationText.format(Int(u.unlocksAt.timeIntervalSince(model.now)))
        return "Requested. Unlocks at \(Format.clock(u.unlocksAt)) (in \(left))."
    }
}

// MARK: - Sheets

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
