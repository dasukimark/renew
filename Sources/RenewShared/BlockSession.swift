import Foundation

/// Days of the week a schedule runs on. Bit `n` is `Calendar` weekday `n + 1`
/// (Sunday = bit 0).
public struct Weekdays: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let sunday = Weekdays(rawValue: 1 << 0)
    public static let monday = Weekdays(rawValue: 1 << 1)
    public static let tuesday = Weekdays(rawValue: 1 << 2)
    public static let wednesday = Weekdays(rawValue: 1 << 3)
    public static let thursday = Weekdays(rawValue: 1 << 4)
    public static let friday = Weekdays(rawValue: 1 << 5)
    public static let saturday = Weekdays(rawValue: 1 << 6)

    public static let weekdays: Weekdays = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekend: Weekdays = [.saturday, .sunday]
    public static let everyDay: Weekdays = [.weekdays, .weekend]

    /// `weekday` as `Calendar` numbers it: 1 = Sunday … 7 = Saturday.
    public init(calendarWeekday weekday: Int) {
        self.init(rawValue: (1...7).contains(weekday) ? 1 << (weekday - 1) : 0)
    }

    public func contains(calendarWeekday weekday: Int) -> Bool {
        contains(Weekdays(calendarWeekday: weekday))
    }

    public var isValid: Bool { rawValue & Weekdays.everyDay.rawValue != 0 && rawValue & ~Weekdays.everyDay.rawValue == 0 }

    /// Calendar weekdays (1...7) in this set, in the locale's week order.
    public func calendarWeekdays(_ calendar: Calendar = .current) -> [Int] {
        Weekdays.orderedCalendarWeekdays(calendar).filter { contains(calendarWeekday: $0) }
    }

    /// 1...7 starting from the locale's first weekday.
    public static func orderedCalendarWeekdays(_ calendar: Calendar = .current) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    /// "Every day", "Weekdays", "Weekends", "Mon–Thu", or "Mon, Wed, Fri".
    public func summary(_ calendar: Calendar = .current) -> String {
        if self == .everyDay { return "Every day" }
        if self == .weekdays { return "Weekdays" }
        if self == .weekend { return "Weekends" }
        let names = calendar.shortWeekdaySymbols
        let ordered = Weekdays.orderedCalendarWeekdays(calendar)
        let picked = ordered.enumerated().filter { contains(calendarWeekday: $0.element) }
        guard !picked.isEmpty else { return "No days" }
        // A consecutive run of 3+ days reads better as a range.
        let positions = picked.map(\.offset)
        if positions.count >= 3, positions.last! - positions.first! == positions.count - 1 {
            return "\(names[picked.first!.element - 1])–\(names[picked.last!.element - 1])"
        }
        return picked.map { names[$0.element - 1] }.joined(separator: ", ")
    }
}

/// A daily time window in minutes after midnight. An end at or before the
/// start means the window runs past midnight into the next day.
public struct DailyWindow: Codable, Equatable, Hashable, Sendable {
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public var isOvernight: Bool { endMinute <= startMinute }

    public var isValid: Bool {
        (0..<1_440).contains(startMinute) && (0..<1_440).contains(endMinute) && startMinute != endMinute
    }

    /// Length of the window in minutes.
    public var lengthMinutes: Int {
        isOvernight ? 1_440 - startMinute + endMinute : endMinute - startMinute
    }

    /// "9:00 AM–5:00 PM" in the current locale.
    public func text(_ calendar: Calendar = .current) -> String {
        "\(Self.timeText(startMinute, calendar))–\(Self.timeText(endMinute, calendar))"
    }

    public static func timeText(_ minute: Int, _ calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        let day = calendar.startOfDay(for: Date())
        let date = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) ?? day
        return f.string(from: date)
    }
}

/// How a saved block session decides when to block.
public enum BlockTiming: Codable, Equatable, Hashable, Sendable {
    /// Started by hand; blocks for this long.
    case length(minutes: Int)
    /// Starts on its own during `window` on `days`.
    case schedule(window: DailyWindow, days: Weekdays)
}

/// A block session the user saved in the app: what to block and when.
public struct BlockSession: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var lists: [String]
    public var extraSites: [String]
    public var timing: BlockTiming
    /// Only meaningful for schedules: a disabled schedule doesn't start.
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, lists: [String], extraSites: [String] = [],
                timing: BlockTiming, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.lists = lists
        self.extraSites = extraSites
        self.timing = timing
        self.enabled = enabled
    }

    public var isScheduled: Bool {
        if case .schedule = timing { return true }
        return false
    }

    /// The sites this session blocks, given the current blocklists.
    public func rules(in lists: [String: [String]]) -> [String] {
        let picked = self.lists.sorted().flatMap { lists[$0] ?? [] }
        return canonicalRules(picked + extraSites).valid
    }

    /// What the daemon needs to run this session on its own, or nil if it
    /// isn't an enabled schedule with something to block.
    public func schedule(in lists: [String: [String]]) -> Schedule? {
        guard enabled, case let .schedule(window, days) = timing else { return nil }
        let schedule = Schedule(id: id, name: name, window: window, days: days, rules: rules(in: lists)).normalized()
        guard !schedule.rules.isEmpty, window.isValid, days.isValid else { return nil }
        return schedule
    }
}

/// A recurring block the daemon starts on its own. Rules are resolved when
/// the app saves it, so the daemon never reads the user's blocklists.
public struct Schedule: Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var window: DailyWindow
    public var days: Weekdays
    public var rules: [String]

    public init(id: UUID = UUID(), name: String, window: DailyWindow, days: Weekdays, rules: [String]) {
        self.id = id
        self.name = name
        self.window = window
        self.days = days
        self.rules = rules
    }

    public static let maxRules = 2_000
    public static let maxNameLength = 100

    /// The form the daemon stores: trimmed name, canonical rules within the
    /// limit. The app normalizes the same way, so both copies compare equal.
    public func normalized() -> Schedule {
        var s = self
        s.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
        s.rules = Array(canonicalRules(rules).valid.prefix(Self.maxRules))
        return s
    }

    /// Start and end of the window that begins on the day containing `day`.
    public func occurrence(onDayOf day: Date, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        let midnight = calendar.startOfDay(for: day)
        guard let start = Self.time(window.startMinute, on: midnight, calendar) else { return nil }
        let endDay = window.isOvernight ? calendar.date(byAdding: .day, value: 1, to: midnight) : midnight
        guard let endDay, let end = Self.time(window.endMinute, on: endDay, calendar), end > start else { return nil }
        return (start, end)
    }

    /// If `now` falls inside a window that started on one of `days`, when
    /// that window ends. A window started yesterday counts if it runs past
    /// midnight.
    public func activeWindowEnd(at now: Date, calendar: Calendar = .current) -> Date? {
        guard window.isValid else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  days.contains(calendarWeekday: calendar.component(.weekday, from: day)),
                  let w = occurrence(onDayOf: day, calendar: calendar) else { continue }
            if w.start <= now && now < w.end { return w.end }
        }
        return nil
    }

    /// The next time a window starts after `now`.
    public func nextStart(after now: Date, calendar: Calendar = .current) -> Date? {
        guard window.isValid, days.isValid else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  days.contains(calendarWeekday: calendar.component(.weekday, from: day)),
                  let w = occurrence(onDayOf: day, calendar: calendar), w.start > now else { continue }
            return w.start
        }
        return nil
    }

    /// "Weekdays · 9:00 AM–5:00 PM"
    public func summary(_ calendar: Calendar = .current) -> String {
        "\(days.summary(calendar)) · \(window.text(calendar))"
    }

    private static func time(_ minute: Int, on day: Date, _ calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
    }
}

/// Saved block sessions (app and CLI) in ~/.config/renew/sessions.json.
public enum BlockSessionStore {
    private struct File: Codable { var sessions: [BlockSession] }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/renew/sessions.json")
    }

    public static func all() -> [BlockSession] {
        guard let data = try? Data(contentsOf: fileURL),
              let f = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return f.sessions
    }

    public static func save(_ sessions: [BlockSession]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(File(sessions: sessions)).write(to: fileURL, options: .atomic)
    }

    /// Adds `session`, or replaces the saved one with the same id.
    @discardableResult
    public static func upsert(_ session: BlockSession) throws -> [BlockSession] {
        var sessions = all()
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.append(session)
        }
        try save(sessions)
        return sessions
    }

    /// The schedules the daemon should enforce, given the blocklists.
    public static func schedules(lists: [String: [String]] = ListStore.all()) -> [Schedule] {
        all().compactMap { $0.schedule(in: lists) }
    }

    @discardableResult
    public static func delete(_ id: UUID) throws -> [BlockSession] {
        let sessions = all().filter { $0.id != id }
        try save(sessions)
        return sessions
    }
}
