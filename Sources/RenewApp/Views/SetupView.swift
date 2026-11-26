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
                    Text("Copies Renew to Applications and starts the background service. Asks for your password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.session != nil {
                        Text("Available after this session ends.")
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
                    Text("Lets Renew watch Firefox and close blocked tabs.")
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
                        if b.kind == .firefox {
                            Text("Uses Accessibility")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    browserControl(b)
                }
            }
        } header: {
            HStack {
                Text("Permissions")
                Spacer()
                Button("Refresh") { model.refreshPermissions() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        } footer: {
            Text(model.protections.closeUnwatchedBrowsers
                 ? "During a session, Renew closes browsers it can't watch or doesn't support."
                 : "Browsers Renew can't watch, like Opera or Tor, aren't blocked unless \u{201C}Close browsers Renew can't watch\u{201D} is on.")
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
                             "Restarts Renew if it's quit, and restores its files if they're changed or deleted.")
            protectionToggle(\.lockSystemSettings, "Lock System Settings switches",
                             "Switches on the Login Items and Privacy & Security pages, and Renew's own, can be turned on, not off. Needs Accessibility.")
            protectionToggle(\.closeUnwatchedBrowsers, "Close browsers Renew can't watch",
                             "Closes browsers without permission, unsupported browsers, and unknown Chrome- or Firefox-based apps.")
            if model.isInstalled && model.daemonReachable && !model.protectionsSupported {
                Text("The background service is out of date. Update Renew to change these.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Protections")
        } footer: {
            Text("These apply during block sessions, and can be turned on but not off while one runs. Off by default, so Renew works like an ordinary blocker.")
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
                    Text("Stays on until \(Format.clock(when))\(model.session != nil ? " or this session ends, whichever is later" : ""). Switch on to cancel.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if lockedOn {
                    Text("Locked on until this session ends.")
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
            protectionToggle(\.uninstallCoolingOff, "Uninstall cooling-off",
                             "Uninstalling needs a request and a 24-hour wait. Turning this off takes 24 hours too.")
            if model.isInstalled && model.daemonReachable && !model.protectionsSupported {
                Text("The background service is out of date. Update Renew to change this.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
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
        } header: {
            Text("Uninstall")
        } footer: {
            if coolingOff {
                Text("Once unlocked, uninstalling stays available for 2 days, between block sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Request uninstall?", isPresented: $confirmingRequest) {
            Button("Request uninstall") { model.requestUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can uninstall 24 hours from now, between block sessions. Renew keeps working as normal.\(model.reportsPartners.isEmpty ? "" : " Your accountability partners will be told.")")
        }
    }

    /// Whether uninstalling needs a request and a wait. Assumed on while the
    /// service can't be reached or predates protections, as the safe reading.
    private var coolingOff: Bool {
        !model.daemonReachable || (model.status?.enforcesCoolingOff ?? true)
    }

    private var uninstallCaption: String {
        if !coolingOff {
            return model.session != nil ? "Not available during a block session." : "Removes the app and its background service, between block sessions."
        }
        guard let u = model.uninstallRequest else { return "Removes the app and its background service. Request it, then wait 24 hours." }
        if model.uninstallUnlocked {
            let until = "Unlocked until \(Format.clock(u.expiresAt))."
            return model.session != nil ? "\(until) Not available during a block session." : until
        }
        let left = DurationText.format(Int(u.unlocksAt.timeIntervalSince(model.now)))
        return "Requested. Unlocks at \(Format.clock(u.unlocksAt)), in \(left)."
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
