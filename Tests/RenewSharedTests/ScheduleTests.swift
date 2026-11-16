import Foundation
import Testing
@testable import RenewShared

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    c.locale = Locale(identifier: "en_US")
    c.firstWeekday = 1
    return c
}()

/// 2026-11-16 is a Monday.
private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func schedule(_ start: Int, _ end: Int, _ days: Weekdays) -> Schedule {
    Schedule(name: "t", window: DailyWindow(startMinute: start, endMinute: end), days: days, rules: ["x.com"])
}

@Suite("Scheduled block sessions")
struct ScheduleTests {
    @Test func weekdayWindow() {
        let s = schedule(9 * 60, 17 * 60, .weekdays)
        #expect(s.activeWindowEnd(at: at(2026, 11, 16, 10), calendar: cal) == at(2026, 11, 16, 17))
        #expect(s.activeWindowEnd(at: at(2026, 11, 16, 9), calendar: cal) == at(2026, 11, 16, 17))
        #expect(s.activeWindowEnd(at: at(2026, 11, 16, 8, 59), calendar: cal) == nil)
        #expect(s.activeWindowEnd(at: at(2026, 11, 16, 17), calendar: cal) == nil)
        // Saturday isn't a weekday.
        #expect(s.activeWindowEnd(at: at(2026, 11, 14, 10), calendar: cal) == nil)
    }

    @Test func overnightWindowBelongsToTheDayItStarts() {
        let s = schedule(22 * 60, 6 * 60, .friday)
        // Friday 2026-11-13 22:00 → Saturday 06:00.
        #expect(s.activeWindowEnd(at: at(2026, 11, 13, 23), calendar: cal) == at(2026, 11, 14, 6))
        #expect(s.activeWindowEnd(at: at(2026, 11, 14, 3), calendar: cal) == at(2026, 11, 14, 6))
        // Saturday night's window would start on Saturday, which isn't enabled.
        #expect(s.activeWindowEnd(at: at(2026, 11, 15, 3), calendar: cal) == nil)
        // Friday early morning belongs to Thursday's window.
        #expect(s.activeWindowEnd(at: at(2026, 11, 13, 3), calendar: cal) == nil)
        #expect(s.window.lengthMinutes == 8 * 60)
    }

    @Test func survivesDaylightSavingChange() {
        // 2026-03-08 (Sunday): 2:00 → 3:00 in New York.
        let s = schedule(60, 4 * 60, .sunday)
        let end = s.activeWindowEnd(at: at(2026, 3, 8, 3, 30), calendar: cal)
        #expect(end == at(2026, 3, 8, 4))
        // A window starting inside the skipped hour still opens.
        let skipped = schedule(2 * 60 + 30, 5 * 60, .sunday)
        #expect(skipped.activeWindowEnd(at: at(2026, 3, 8, 4), calendar: cal) == at(2026, 3, 8, 5))
    }

    @Test func nextStart() {
        let s = schedule(9 * 60, 17 * 60, .weekdays)
        // Saturday noon → Monday 9:00.
        #expect(s.nextStart(after: at(2026, 11, 14, 12), calendar: cal) == at(2026, 11, 16, 9))
        // Monday 10:00, inside a window → Tuesday 9:00.
        #expect(s.nextStart(after: at(2026, 11, 16, 10), calendar: cal) == at(2026, 11, 17, 9))
        #expect(s.nextStart(after: at(2026, 11, 16, 8), calendar: cal) == at(2026, 11, 16, 9))
    }

    @Test func invalidSchedulesNeverStart() {
        #expect(schedule(9 * 60, 9 * 60, .everyDay).activeWindowEnd(at: at(2026, 11, 16, 9), calendar: cal) == nil)
        #expect(schedule(9 * 60, 17 * 60, []).nextStart(after: at(2026, 11, 16, 8), calendar: cal) == nil)
        #expect(!Weekdays(rawValue: 1 << 7).isValid)
    }

    @Test func daySummaries() {
        #expect(Weekdays.weekdays.summary(cal) == "Weekdays")
        #expect(Weekdays.everyDay.summary(cal) == "Every day")
        #expect(Weekdays([.monday, .tuesday, .wednesday, .thursday]).summary(cal) == "Mon–Thu")
        #expect(Weekdays([.monday, .wednesday]).summary(cal) == "Mon, Wed")
    }

    @Test func savedSessionResolvesRules() {
        let lists = ["social": ["x.com", "reddit.com"]]
        var s = BlockSession(name: "Work", lists: ["social", "gone"], extraSites: ["YouTube.com"],
                             timing: .schedule(window: DailyWindow(startMinute: 540, endMinute: 1_020), days: .weekdays))
        #expect(Set(s.rules(in: lists)) == ["x.com", "reddit.com", "youtube.com"])
        #expect(s.schedule(in: lists)?.id == s.id)
        s.enabled = false
        #expect(s.schedule(in: lists) == nil)
        let length = BlockSession(name: "Quick", lists: ["social"], timing: .length(minutes: 25))
        #expect(length.schedule(in: lists) == nil)
    }

    @Test func codableRoundTrips() throws {
        let s = BlockSession(name: "Evenings", lists: ["video"],
                             timing: .schedule(window: DailyWindow(startMinute: 1_200, endMinute: 360), days: [.friday, .saturday]))
        let back = try JSONDecoder().decode(BlockSession.self, from: JSONEncoder().encode(s))
        #expect(back == s)

        // State files from before schedules still load.
        let old = try Wire.decoder.decode(PersistedState.self, from: Data(#"{"alertURL":"https://ntfy.sh/x"}"#.utf8))
        #expect(old.schedules == nil)
        #expect(old.alertURL == "https://ntfy.sh/x")

        var state = PersistedState()
        state.schedules = [schedule(540, 1_020, .weekdays)]
        let reloaded = try Wire.decoder.decode(PersistedState.self, from: Wire.encoder.encode(state))
        #expect(reloaded.schedules == state.schedules)
    }

    @Test func normalizedMatchesWhatTheAppSends() {
        let raw = Schedule(name: "  Work  ", window: DailyWindow(startMinute: 540, endMinute: 1_020), days: .weekdays,
                           rules: ["X.com", "x.com", "reddit.com"])
        let n = raw.normalized()
        #expect(n.name == "Work")
        #expect(n.rules == ["x.com", "reddit.com"])
        #expect(n.normalized() == n)
        let many = Schedule(name: String(repeating: "a", count: 300), window: raw.window, days: raw.days,
                            rules: (0..<2_500).map { "site\($0).com" }).normalized()
        #expect(many.rules.count == Schedule.maxRules)
        #expect(many.name.count == Schedule.maxNameLength)
        // A saved session produces the normalized form directly.
        let saved = BlockSession(name: " Work ", lists: [], extraSites: ["X.com"],
                                 timing: .schedule(window: raw.window, days: raw.days))
        #expect(saved.schedule(in: [:]) == saved.schedule(in: [:])?.normalized())
    }

    @Test func parsesTypedSites() {
        #expect(parseSites("a.com, b.com\nc.com\td.com  e.com,,") == ["a.com", "b.com", "c.com", "d.com", "e.com"])
    }

    @Test func anchoredClockIgnoresDateChanges() {
        let r0 = ClockReading(bootID: "A", mono: 1_000_000_000, wall: Date(timeIntervalSince1970: 1_000_000))
        let anchor = WallAnchor(at: r0)
        // 60 s later, but the date was moved 8 hours forward.
        let r1 = ClockReading(bootID: "A", mono: 61_000_000_000, wall: Date(timeIntervalSince1970: 1_000_000 + 60 + 28_800))
        #expect(anchor.trustedWall(at: r1) == Date(timeIntervalSince1970: 1_000_060))
        #expect(anchor.trustedWall(at: ClockReading(bootID: "B", mono: 5, wall: Date())) == nil)
    }
}
