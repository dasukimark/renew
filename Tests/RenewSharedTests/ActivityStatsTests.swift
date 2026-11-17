import Foundation
import Testing
@testable import RenewShared

private let utc = TimeZone(identifier: "UTC")!
private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

private func visit(_ host: String, from start: Date, seconds: TimeInterval) -> ActivityEvent {
    ActivityEvent(start: start, end: start.addingTimeInterval(seconds), browser: "Safari",
                  url: "https://\(host)/", host: host, title: host)
}

@Suite("Activity stats")
struct ActivityStatsTests {
    @Test func groupsHostsByMainSite() {
        #expect(SiteKey.site(forHost: "youtube.com") == "youtube.com")
        #expect(SiteKey.site(forHost: "www.youtube.com") == "youtube.com")
        #expect(SiteKey.site(forHost: "m.youtube.com") == "youtube.com")
        #expect(SiteKey.site(forHost: "music.youtube.com") == "youtube.com")
        #expect(SiteKey.site(forHost: "A.B.Example.COM.") == "example.com")
        #expect(SiteKey.site(forHost: "news.bbc.co.uk") == "bbc.co.uk")
        #expect(SiteKey.site(forHost: "bbc.co.uk") == "bbc.co.uk")
        #expect(SiteKey.site(forHost: "www.abc.net.au") == "abc.net.au")
        #expect(SiteKey.site(forHost: "docs.example.io") == "example.io")
        #expect(SiteKey.site(forHost: "192.168.1.20") == "192.168.1.20")
        #expect(SiteKey.site(forHost: "::1") == "::1")
        #expect(SiteKey.site(forHost: "intranet") == "intranet")
    }

    @Test func overlappingVisitsCountOnce() {
        let s = DaySummary.build(day: "2027-01-15", events: [
            visit("www.youtube.com", from: at(0), seconds: 100),
            visit("m.youtube.com", from: at(50), seconds: 100),     // overlaps by 50s
            visit("music.youtube.com", from: at(300), seconds: 60), // separate
            visit("example.com", from: at(120), seconds: 60),       // overlaps youtube in time
            visit("example.com", from: at(1_000), seconds: 0),      // empty
        ])
        #expect(s.sites == ["youtube.com": 210, "example.com": 60])
        // Union of everything: 0…180 and 300…360.
        #expect(s.totalSeconds == 240)
    }

    @Test func builderAddsUpInBatches() {
        let events = [
            visit("www.youtube.com", from: at(0), seconds: 100),
            visit("example.com", from: at(120), seconds: 60),
            visit("m.youtube.com", from: at(50), seconds: 100),
            visit("music.youtube.com", from: at(300), seconds: 60),
        ]
        var b = DaySummary.Builder()
        for e in events { b.add([e]) }
        #expect(b.summary(day: "2027-01-15") == DaySummary.build(day: "2027-01-15", events: events))
    }

    @Test func otherSitesCantCollideWithAHost() {
        #expect(DaySummary.otherSite != SiteKey.site(forHost: "other"))
        #expect(NormalizedURL("https://\(DaySummary.otherSite)/") == nil)
    }

    @Test func rangeCapKeepsTheSameSitesEveryDay() {
        // youtube.com ranks low on day 1 but has the most time overall.
        let days = [
            DaySummary(day: "2027-01-01", totalSeconds: 100, sites: ["a.test": 50, "b.test": 40, "youtube.com": 10]),
            DaySummary(day: "2027-01-02", totalSeconds: 500, sites: ["youtube.com": 500]),
        ]
        let capped = DaySummary.cappedTogether(days, limit: 2)
        #expect(capped[0].sites == ["youtube.com": 10, DaySummary.otherSite: 90])
        #expect(capped[1].sites == ["youtube.com": 500])
        #expect(capped.map(\.totalSeconds) == [100, 500])
        // A site asked for is kept even if it's small.
        #expect(DaySummary.cappedTogether(days, limit: 2, keep: "b.test")[0].sites
            == ["youtube.com": 10, "b.test": 40, DaySummary.otherSite: 50])
        // Under the cap nothing changes.
        #expect(DaySummary.cappedTogether(days, limit: 10) == days)

        let report = ActivityStatsReport(query: ActivityStatsQuery(from: "2027-01-01", to: "2027-01-02"),
                                         summaries: [DaySummary(day: "2027-01-01", totalSeconds: 100,
                                                                sites: [DaySummary.otherSite: 90, "a.test": 10])],
                                         timeZone: utc)
        #expect(report.topSite?.site == "a.test")
    }

    @Test func capsSitesPerDay() {
        let events = (0..<10).map { visit("site\($0).test", from: at(Double($0) * 100), seconds: Double(10 + $0)) }
        let s = DaySummary.build(day: "2027-01-15", events: events).capped(4)
        #expect(s.sites.count == 4)
        #expect(s.sites["site9.test"] == 19 && s.sites["site8.test"] == 18 && s.sites["site7.test"] == 17)
        #expect(s.sites[DaySummary.otherSite] == (10...16).reduce(0, +))
        #expect(s.totalSeconds == (10...19).reduce(0, +))
    }

    @Test func queryValidation() {
        #expect(ActivityStatsQuery(from: "2027-01-01", to: "2027-01-03").dayKeys(timeZone: utc)
            == ["2027-01-01", "2027-01-02", "2027-01-03"])
        #expect(ActivityStatsQuery(from: "2027-01-01", to: "2027-01-01").dayKeys(timeZone: utc) == ["2027-01-01"])
        #expect(ActivityStatsQuery(from: "2027-01-03", to: "2027-01-01").dayKeys(timeZone: utc) == nil)
        #expect(ActivityStatsQuery(from: "2027-02-30", to: "2027-03-01").dayKeys(timeZone: utc) == nil)
        #expect(ActivityStatsQuery(from: "nope", to: "2027-03-01").dayKeys(timeZone: utc) == nil)
        #expect(ActivityStatsQuery(from: "2026-01-01", to: "2026-12-31").dayKeys(timeZone: utc)?.count == 365)
        #expect(ActivityStatsQuery(from: "2028-01-01", to: "2028-12-31").dayKeys(timeZone: utc)?.count == 366)
        #expect(ActivityStatsQuery(from: "2026-01-01", to: "2027-01-02").dayKeys(timeZone: utc) == nil)

        // Across a daylight-saving change, every day appears once.
        let ny = TimeZone(identifier: "America/New_York")!
        #expect(ActivityStatsQuery(from: "2027-03-13", to: "2027-03-15").dayKeys(timeZone: ny)
            == ["2027-03-13", "2027-03-14", "2027-03-15"])

        let week = ActivityStatsQuery(lastDays: 7, endingAt: ActivityLogStore.date(ofDay: "2027-01-10", timeZone: utc)!
            .addingTimeInterval(3_600), timeZone: utc)
        #expect(week == ActivityStatsQuery(from: "2027-01-04", to: "2027-01-10"))
    }

    @Test func reportTotalsAndAverages() {
        let q = ActivityStatsQuery(from: "2027-01-01", to: "2027-01-05")
        let report = ActivityStatsReport(query: q, summaries: [
            DaySummary(day: "2027-01-02", totalSeconds: 600, sites: ["youtube.com": 400, "example.com": 200]),
            DaySummary(day: "2027-01-04", totalSeconds: 300, sites: ["youtube.com": 300]),
            DaySummary(day: "2026-12-01", totalSeconds: 9_999, sites: ["youtube.com": 9_999]), // outside the range
        ], timeZone: utc)
        #expect(report.days.map(\.day) == ["2027-01-01", "2027-01-02", "2027-01-03", "2027-01-04", "2027-01-05"])
        #expect(report.days.map(\.seconds) == [0, 600, 0, 300, 0])
        #expect(report.totalSeconds == 900)
        // From the first day with data (the 2nd) through the 5th.
        #expect(report.averageDays == 4)
        #expect(report.dailyAverage == 225)
        #expect(report.sites.map(\.site) == ["youtube.com", "example.com"])
        let yt = report.site("youtube.com")!
        #expect(yt.totalSeconds == 700)
        #expect(yt.dailyAverage == 175)
        #expect(abs(yt.share - 700.0 / 900.0) < 1e-9)
        #expect(report.days(for: "youtube.com").map(\.seconds) == [0, 400, 0, 300, 0])
        #expect(report.days(for: "nowhere.test").map(\.seconds) == [0, 0, 0, 0, 0])

        let empty = ActivityStatsReport(query: q, summaries: [], timeZone: utc)
        #expect(empty.isEmpty && empty.averageDays == 0 && empty.dailyAverage == 0)
        #expect(empty.days.count == 5)
    }

    @Test func shortDurations() {
        #expect(DurationText.hoursMinutes(-5) == "0s")
        #expect(DurationText.hoursMinutes(45) == "45s")
        #expect(DurationText.hoursMinutes(12 * 60 + 30) == "12m")
        #expect(DurationText.hoursMinutes(3 * 3_600 + 5 * 60) == "3h 05m")
        #expect(DurationText.hoursMinutes(150 * 3_600) == "150h 00m")
    }

    @Test func summariesAreCachedAndOutliveTheLog() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("renew-stats-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: dir) }
        let store = ActivityLogStore(directory: dir)
        let now = Date()
        let start = now.addingTimeInterval(-120)
        let day = ActivityLogStore.dayKey(start)
        let q = ActivityStatsQuery(from: day, to: day)

        #expect(store.summaries(q, uid: 501)?.isEmpty == true)
        store.append([visit("www.youtube.com", from: start, seconds: 30)], uid: 501, now: now)
        #expect(store.summaries(q, uid: 501) == [DaySummary(day: day, totalSeconds: 30, sites: ["youtube.com": 30])])

        let summaryPath = dir + "/501/summary/\(day).json"
        #expect((try fm.attributesOfItem(atPath: summaryPath)[.posixPermissions] as? Int) == 0o600)

        // The log grew, so the summary is rebuilt.
        store.append([visit("example.com", from: start.addingTimeInterval(40), seconds: 20)], uid: 501, now: now)
        let updated = DaySummary(day: day, totalSeconds: 50, sites: ["youtube.com": 30, "example.com": 20])
        #expect(store.summaries(q, uid: 501) == [updated])
        // Other users see nothing.
        #expect(store.summaries(q, uid: 502)?.isEmpty == true)
        // Bad ranges are refused.
        #expect(store.summaries(ActivityStatsQuery(from: day, to: "2000-01-01"), uid: 501) == nil)

        // A fresh store (renewd restarted) reads the saved summary.
        #expect(ActivityLogStore(directory: dir).summaries(q, uid: 501) == [updated])

        // Past the log's retention the visits go but the totals stay.
        let logPath = dir + "/501/\(day).jsonl"
        #expect(store.prune(now: now.addingTimeInterval(40 * 86_400)) == 1)
        #expect(!fm.fileExists(atPath: logPath))
        #expect(store.summaries(q, uid: 501) == [updated])

        // A year on, the totals go too.
        store.prune(now: now.addingTimeInterval(400 * 86_400))
        #expect(!fm.fileExists(atPath: summaryPath))
        #expect(store.summaries(q, uid: 501)?.isEmpty == true)
    }

    @Test func pruneSummarisesLogsNotYetSummarised() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("renew-stats-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: dir) }
        let store = ActivityLogStore(directory: dir)
        let now = Date()
        let start = now.addingTimeInterval(-120)
        let day = ActivityLogStore.dayKey(start)
        store.append([visit("example.com", from: start, seconds: 15)], uid: 501, now: now)
        // Nobody asked for stats before the log expired.
        #expect(store.prune(now: now.addingTimeInterval(40 * 86_400)) == 1)
        #expect(store.summaries(ActivityStatsQuery(from: day, to: day), uid: 501)
            == [DaySummary(day: day, totalSeconds: 15, sites: ["example.com": 15])])
    }
}
