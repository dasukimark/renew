import AppKit
import SwiftUI
import RenewShared

/// Set before calling NSApp.terminate when quitting is genuinely wanted
/// (uninstall, hand-over after install, logout/shutdown, dev copies).
var allowQuit = false

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let localSession: SessionInfo?
    private let launchedInBackground: Bool
    let model: AppModel
    private let monitor: Monitor
    private var statusItem: StatusItemController!
    private var window: NSWindow?
    private var statusPoll: Timer?

    init(localSession: SessionInfo?, launchedInBackground: Bool) {
        self.localSession = localSession
        self.launchedInBackground = launchedInBackground
        self.model = AppModel(isLocalTest: localSession != nil)
        self.monitor = Monitor(localSession: localSession)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in allowQuit = true }

        monitor.onStatus = { [weak self] status in self?.model.update(status: status) }
        model.requestSync = { [weak self] in self?.monitor.sync() }

        // Only the installed copy (or a local test run) watches browsers. Any other
        // copy, such as a freshly built one, is just the installer/settings UI.
        let watches = model.isRunningInstalledCopy || localSession != nil
        if watches {
            monitor.start()
            statusItem = StatusItemController(model: model) { [weak self] in self?.showWindow() }
            statusItem.install()
        } else {
            pollStatus()
            statusPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollStatus() }
        }

        if !model.isInstalled && localSession == nil { model.section = .setup }
        if !launchedInBackground { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The installed copy lives in the menu bar; Cmd-Q just closes the window.
        if allowQuit || !model.isRunningInstalledCopy || localSession != nil { return .terminateNow }
        window?.close()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Non-installed copies (the installer UI) quit when their window closes.
        !model.isRunningInstalledCopy && localSession == nil
    }

    // MARK: window

    func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Renew"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 860, height: 640))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("RenewMain")
            window = w
        }
        if model.isInstalled && !model.accessibilityGranted && model.session == nil { model.section = .setup }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        monitor.sync()
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app.
        if model.isRunningInstalledCopy || localSession != nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func pollStatus() {
        DispatchQueue.global().async { [weak self] in
            let status = (try? DaemonClient.send(Request(cmd: .status), timeout: 2))?.status
            DispatchQueue.main.async { self?.model.update(status: status) }
        }
    }

    // MARK: menus

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Renew", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Renew", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: model.isRunningInstalledCopy ? "Close Renew Window" : "Quit Renew",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
