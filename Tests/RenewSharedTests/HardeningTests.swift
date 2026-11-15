import Foundation
import Testing
@testable import RenewShared

private func reading(_ boot: String = "A", mono seconds: Double, wall: TimeInterval) -> ClockReading {
    ClockReading(bootID: boot, mono: UInt64(seconds * 1e9), wall: Date(timeIntervalSince1970: wall))
}

@Suite("Clock-proof countdown")
struct CountdownTests {
    @Test func ignoresDateChangesWithinABoot() {
        let c = Countdown(remaining: 3_600, at: reading(mono: 100, wall: 1_000_000))
        // 10 minutes pass, but someone moved the date a day forward.
        let later = reading(mono: 700, wall: 1_000_000 + 600 + 86_400)
        #expect(c.remaining(at: later) == 3_000)
        // ...or back.
        #expect(c.remaining(at: reading(mono: 700, wall: 900_000)) == 3_000)
    }

    @Test func creditsWallTimeAcrossARestart() {
        let c = Countdown(remaining: 3_600, at: reading(mono: 5_000, wall: 1_000_000))
        // Rebooted (new boot ID, monotonic clock restarted) 20 minutes later.
        #expect(c.remaining(at: reading("B", mono: 30, wall: 1_000_000 + 1_200)) == 2_400)
        // Clock set back while off: credits nothing.
        #expect(c.remaining(at: reading("B", mono: 30, wall: 999_000)) == 3_600)
    }

    @Test func sessionSurvivesClockJump() {
        let start = reading(mono: 10, wall: 1_000_000)
        var state = PersistedState()
        state.setSession(SessionInfo(startedAt: start.wall, endsAt: start.wall.addingTimeInterval(3_600), rules: ["x.com"]), at: start)

        let jumped = reading(mono: 70, wall: 1_000_000 + 60 + 86_400)
        let s = state.activeSession(at: jumped)
        #expect(s != nil)
        #expect(s?.endsAt == jumped.wall.addingTimeInterval(3_540))
        #expect(s.map { $0.endsAt.timeIntervalSince($0.startedAt) } == 3_600)

        let shift = state.checkpoint(at: jumped)
        #expect(shift == 86_400)
        #expect(state.session?.endsAt == jumped.wall.addingTimeInterval(3_540))

        // A date change made before a restart was already checkpointed.
        let rebooted = reading("B", mono: 20, wall: jumped.wall.timeIntervalSince1970 + 100)
        #expect(state.sessionRemaining(at: rebooted) == 3_440)
    }

    @Test func untouchedClockKeepsDatesStable() {
        let start = reading(mono: 10, wall: 1_000_000)
        var state = PersistedState()
        state.setSession(SessionInfo(startedAt: start.wall, endsAt: start.wall.addingTimeInterval(600), rules: ["x.com"]), at: start)
        let before = state.session
        // Wall and monotonic drift apart by a few milliseconds.
        state.checkpoint(at: reading(mono: 12.004, wall: 1_000_002))
        #expect(state.session == before)
    }

    @Test func expiresOnTheMonotonicClock() {
        let start = reading(mono: 0, wall: 1_000_000)
        var state = PersistedState()
        state.setSession(SessionInfo(startedAt: start.wall, endsAt: start.wall.addingTimeInterval(60), rules: ["x.com"]), at: start)
        #expect(state.activeSession(at: reading(mono: 61, wall: 999_000)) == nil)
    }

    @Test func legacyStateWithoutClockUsesEndsAt() throws {
        let json = #"{"session":{"startedAt":1000,"endsAt":5000,"rules":["x.com"]}}"#
        let state = try Wire.decoder.decode(PersistedState.self, from: Data(json.utf8))
        #expect(state.sessionClock == nil)
        #expect(state.sessionRemaining(at: reading(mono: 1, wall: 4_000)) == 1_000)
    }
}

@Suite("Uninstall cooling-off")
struct UninstallTests {
    @Test func unlocksAfterDelayAndExpires() {
        let t0 = reading(mono: 0, wall: 1_000_000)
        var state = PersistedState()
        state.uninstall = UninstallRequest(requestedAt: t0.wall,
                                           countdown: Countdown(remaining: UninstallPolicy.delay + UninstallPolicy.window, at: t0))
        let early = state.uninstallStatus(at: reading(mono: 3_600, wall: 1_000_000 + 3_600 + 86_400 * 3))
        #expect(early?.unlocked == false) // a date change doesn't unlock it
        let unlocked = state.uninstallStatus(at: reading(mono: UninstallPolicy.delay + 1, wall: 2_000_000))
        #expect(unlocked?.unlocked == true)
        #expect(state.uninstallStatus(at: reading(mono: UninstallPolicy.delay + UninstallPolicy.window + 1, wall: 0)) == nil)
    }
}

@Suite("Engine detection")
struct EngineTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("renew-engine-\(UUID().uuidString)")

    private func makeApp(_ name: String, files: [String], info: [String: Any] = [:]) throws -> String {
        let app = root.appendingPathComponent(name + ".app").path
        for f in files {
            let path = app + "/Contents/" + f
            if f.hasSuffix(".app") || f.hasSuffix(".framework") {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path, contents: Data())
            }
        }
        try FileManager.default.createDirectory(atPath: app + "/Contents", withIntermediateDirectories: true)
        (info as NSDictionary).write(toFile: app + "/Contents/Info.plist", atomically: true)
        return app
    }

    @Test func detectsRenamedChromiumAndGecko() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = try makeApp("Work", files: ["Frameworks/Work Framework.framework/Versions/157.0/Helpers/Work Helper (Renderer).app"])
        #expect(EngineDetector.browserEngine(bundleAt: chrome, bundleID: "com.example.work") == .chromium)
        let fox = try makeApp("Fox", files: ["MacOS/XUL"])
        #expect(EngineDetector.browserEngine(bundleAt: fox, bundleID: "com.example.fox") == .gecko)
    }

    @Test func ignoresElectronCEFAndExceptions() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = "Frameworks/X Framework.framework/Versions/1.0/Helpers/X Helper (Renderer).app"
        let electron = try makeApp("E", files: ["Frameworks/Electron Framework.framework", helper])
        #expect(EngineDetector.browserEngine(bundleAt: electron, bundleID: "com.example.e") == nil)
        let renamed = try makeApp("Codexish", files: [helper, "Resources/app.asar"], info: ["ElectronAsarIntegrity": [:]])
        #expect(EngineDetector.browserEngine(bundleAt: renamed, bundleID: "com.example.c") == nil)
        // An Electron key alone (no app.asar) doesn't pass a Chrome copy off as Electron.
        let faked = try makeApp("Faked", files: [helper], info: ["ElectronAsarIntegrity": [:]])
        #expect(EngineDetector.browserEngine(bundleAt: faked, bundleID: "com.example.f") == .chromium)
        let cef = try makeApp("S", files: ["Frameworks/Chromium Embedded Framework.framework"])
        #expect(EngineDetector.browserEngine(bundleAt: cef, bundleID: "com.example.s") == nil)
        let bird = try makeApp("T", files: ["MacOS/XUL"])
        #expect(EngineDetector.browserEngine(bundleAt: bird, bundleID: "org.mozilla.thunderbird") == nil)
        let plain = try makeApp("P", files: ["MacOS/P"])
        #expect(EngineDetector.browserEngine(bundleAt: plain, bundleID: "com.example.p") == nil)
    }

    @Test func realAppsOnThisMac() {
        // Skipped quietly where the apps aren't installed.
        let fm = FileManager.default
        if fm.fileExists(atPath: "/Applications/Google Chrome.app") {
            #expect(EngineDetector.browserEngine(bundleAt: "/Applications/Google Chrome.app", bundleID: "com.example.copy") == .chromium)
        }
        for app in ["Claude", "Slack", "Notion", "Obsidian", "Spotify", "ChatGPT", "Postman", "Bitwarden", "Safari"]
        where fm.fileExists(atPath: "/Applications/\(app).app") {
            #expect(EngineDetector.browserEngine(bundleAt: "/Applications/\(app).app", bundleID: "com.example.\(app)") == nil, "\(app)")
        }
    }
}

@Suite("Alerts")
struct AlertTests {
    @Test func validatesURLs() {
        #expect(Alerts.normalize("  https://ntfy.sh/abc ") == "https://ntfy.sh/abc")
        #expect(Alerts.normalize("ntfy.sh/abc") == nil)
        #expect(Alerts.normalize("file:///etc/passwd") == nil)
        #expect(Alerts.normalize("") == nil)
    }

    @Test func formatsForEachService() throws {
        let ntfy = try #require(Alerts.makeRequest("https://ntfy.sh/t", title: "Renew on Mark’s Mac", message: "hi"))
        #expect(ntfy.value(forHTTPHeaderField: "Title") == "Renew on Mark's Mac")
        #expect(ntfy.httpBody == Data("hi".utf8))
        let discord = try #require(Alerts.makeRequest("https://discord.com/api/webhooks/1/x", title: "T", message: "hi"))
        let body = try #require(discord.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body["content"] == "**T**\nhi")
    }
}
