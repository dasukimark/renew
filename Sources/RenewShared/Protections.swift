import Foundation

/// The optional features that make Renew hard to stop or remove. All are off
/// out of the box, so a plain install acts like an ordinary blocker that's
/// fine to use on a work Mac. Blocking itself, clock-proof countdowns and the
/// rule that a running session can't be shortened don't depend on these.
///
/// renewd owns the settings. Any of them can be turned on at any time, but
/// turned off only between block sessions. Turning off the uninstall
/// cooling-off takes the cooling-off period itself (see
/// `PersistedState.coolingOffRemoval`), or the switch would be a way around it.
public struct Protections: Codable, Equatable, Sendable {
    /// During a session, renewd and its guard bring each other and the app
    /// back if they're stopped, and put back Renew's files if they're deleted
    /// or changed.
    public var keepRunning: Bool
    /// During a session, switches in System Settings' Login Items and Privacy
    /// & Security pages (and Renew's own anywhere) turn on but not off.
    public var lockSystemSettings: Bool
    /// During a session, browsers Renew can't watch are closed: supported ones
    /// it lost permission for, unsupported ones (Opera, Tor…) and unknown
    /// apps built on Chromium or Firefox's engine.
    public var closeUnwatchedBrowsers: Bool
    /// Uninstalling needs a request and a 24-hour wait.
    public var uninstallCoolingOff: Bool

    public init(keepRunning: Bool = false, lockSystemSettings: Bool = false,
                closeUnwatchedBrowsers: Bool = false, uninstallCoolingOff: Bool = false) {
        self.keepRunning = keepRunning
        self.lockSystemSettings = lockSystemSettings
        self.closeUnwatchedBrowsers = closeUnwatchedBrowsers
        self.uninstallCoolingOff = uninstallCoolingOff
    }

    public static let off = Protections()
    public static let all = Protections(keepRunning: true, lockSystemSettings: true,
                                        closeUnwatchedBrowsers: true, uninstallCoolingOff: true)

    /// Each protection with its command-line name and a short label.
    public static let catalog: [(key: WritableKeyPath<Protections, Bool>, name: String, label: String)] = [
        (\.keepRunning, "keep-running", "Keep Renew running"),
        (\.lockSystemSettings, "lock-settings", "Lock System Settings switches"),
        (\.closeUnwatchedBrowsers, "close-browsers", "Close browsers Renew can't watch"),
        (\.uninstallCoolingOff, "cooling-off", "Uninstall cooling-off"),
    ]

    public var anyOn: Bool { self != .off }

    /// Command-line names of the protections that are on.
    public var onNames: [String] { Self.catalog.filter { self[keyPath: $0.key] }.map(\.name) }

    /// The protections a command-line name stands for ("all" is every one),
    /// or nil if there's no such name.
    public static func keys(named name: String) -> [WritableKeyPath<Protections, Bool>]? {
        if name == "all" { return catalog.map(\.key) }
        return catalog.first { $0.name == name }.map { [$0.key] }
    }

    /// Every name `keys(named:)` accepts.
    public static var allNames: [String] { catalog.map(\.name) + ["all"] }

    /// Labels of the protections that are on here but off in `new`.
    public func turnedOff(in new: Protections) -> [String] {
        Self.catalog.filter { self[keyPath: $0.key] && !new[keyPath: $0.key] }.map(\.label)
    }

    /// Labels of the protections that are off here but on in `new`.
    public func turnedOn(in new: Protections) -> [String] {
        new.turnedOff(in: self)
    }

    // Missing keys (older or hand-written files) read as off.
    private enum CodingKeys: String, CodingKey {
        case keepRunning, lockSystemSettings, closeUnwatchedBrowsers, uninstallCoolingOff
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepRunning = try c.decodeIfPresent(Bool.self, forKey: .keepRunning) ?? false
        lockSystemSettings = try c.decodeIfPresent(Bool.self, forKey: .lockSystemSettings) ?? false
        closeUnwatchedBrowsers = try c.decodeIfPresent(Bool.self, forKey: .closeUnwatchedBrowsers) ?? false
        uninstallCoolingOff = try c.decodeIfPresent(Bool.self, forKey: .uninstallCoolingOff) ?? false
    }
}
