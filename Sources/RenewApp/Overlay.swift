import AppKit
import RenewShared

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Full-screen "blocked" pop-up on every display. Used for Firefox, for
/// redirects that failed, and when an unsupported browser is quit.
final class OverlayController: NSObject {
    private var panels: [NSPanel] = []
    private var countdownLabels: [NSTextField] = []
    private var hideTimer: Timer?
    private var tickTimer: Timer?
    private var endsAt: Date?

    var isVisible: Bool { !panels.isEmpty }

    func show(title: String, detail: String, endsAt: Date?) {
        hide()
        self.endsAt = endsAt
        for screen in NSScreen.screens {
            panels.append(makePanel(on: screen, title: title, detail: detail))
        }
        NSApp.activate(ignoringOtherApps: true)
        for p in panels { p.orderFrontRegardless() }
        panels.first?.makeKey()
        updateCountdown()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateCountdown() }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in self?.hide() }
    }

    @objc func hide() {
        hideTimer?.invalidate()
        tickTimer?.invalidate()
        hideTimer = nil
        tickTimer = nil
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
        countdownLabels.removeAll()
    }

    private func updateCountdown() {
        guard let endsAt else {
            countdownLabels.forEach { $0.stringValue = "" }
            return
        }
        let left = Int(endsAt.timeIntervalSinceNow)
        let text = left > 0 ? "Focus session ends in \(DurationText.format(left))" : "Focus session finished"
        countdownLabels.forEach { $0.stringValue = text }
    }

    private func makePanel(on screen: NSScreen, title: String, detail: String) -> NSPanel {
        let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 0.94)
        panel.setFrame(screen.frame, display: false)

        let icon = NSImageView()
        if let img = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Blocked") {
            icon.image = img.withSymbolConfiguration(.init(pointSize: 64, weight: .semibold))
            icon.contentTintColor = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.35, alpha: 1)
        }

        let titleLabel = label(title, size: 40, weight: .bold, color: .white)
        let detailLabel = label(detail, size: 18, weight: .regular, color: NSColor(white: 0.75, alpha: 1))
        detailLabel.preferredMaxLayoutWidth = min(640, screen.frame.width - 80)
        let countdown = label("", size: 16, weight: .medium, color: NSColor(white: 0.6, alpha: 1))
        countdown.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        countdownLabels.append(countdown)

        let button = NSButton(title: "Back to work", target: self, action: #selector(hide))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"

        let stack = NSStackView(views: [icon, titleLabel, detailLabel, countdown, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(28, after: countdown)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.contentView = content
        return panel
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .center
        l.isSelectable = false
        return l
    }
}
