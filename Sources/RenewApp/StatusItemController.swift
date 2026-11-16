import AppKit
import Combine
import RenewShared

/// Menu-bar icon with the remaining time, plus quick actions.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let openWindow: () -> Void
    private var item: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel, openWindow: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        model.$now.combineLatest(model.$status)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshButton() }
            .store(in: &cancellables)
        refreshButton()
    }

    private func refreshButton() {
        guard let button = item?.button else { return }
        let active = model.session != nil
        let symbol = active ? "lock.fill" : "lock.open"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Renew")
        image?.isTemplate = true
        button.image = image
        if active {
            button.title = " " + Format.countdown(model.secondsLeft)
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            button.title = ""
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let s = model.session {
            menu.addItem(disabled("Blocking: \(Format.countdown(model.secondsLeft)) left"))
            menu.addItem(disabled("Ends at \(Format.clock(s.endsAt)) · \(s.rules.count) sites blocked"))
            menu.addItem(.separator())
            for m in [15, 30, 60] {
                menu.addItem(action("Add \(Format.minutes(m))", #selector(extend(_:)), tag: m))
            }
        } else if model.isInstalled || model.isLocalTest {
            menu.addItem(disabled("No block session"))
            menu.addItem(.separator())
            let lists = model.selectedLists.sorted().map { $0.capitalized }.joined(separator: ", ")
            if !lists.isEmpty {
                for m in [25, 60, 120] {
                    menu.addItem(action("Start \(Format.minutes(m)) · \(lists)", #selector(quickStart(_:)), tag: m))
                }
            }
        } else {
            menu.addItem(disabled("Renew isn't set up yet"))
        }
        menu.addItem(.separator())
        menu.addItem(action("Open Renew…", #selector(open), key: "o"))
        if !model.isRunningInstalledCopy || model.isLocalTest {
            menu.addItem(action("Quit Renew", #selector(quit), key: "q"))
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, tag: Int = 0, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        i.tag = tag
        return i
    }

    @objc private func open() { openWindow() }

    @objc private func extend(_ sender: NSMenuItem) { model.extend(minutes: sender.tag) }

    @objc private func quickStart(_ sender: NSMenuItem) {
        let minutes = sender.tag
        let rules = model.rules(forSelection: model.selectedLists, extra: "")
        guard !rules.isEmpty else { openWindow(); return }
        let ends = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let alert = NSAlert()
        alert.messageText = "Lock in until \(Format.clock(ends))?"
        alert.informativeText = "Blocking \(rules.count) sites for \(Format.minutes(minutes)). You won't be able to stop or shorten this session."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.start(minutes: minutes, rules: rules)
        }
    }

    @objc private func quit() {
        allowQuit = true
        NSApp.terminate(nil)
    }
}
