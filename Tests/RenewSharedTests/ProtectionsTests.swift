import Foundation
import Testing
@testable import RenewShared

private func reading(_ boot: String = "A", mono seconds: Double, wall: TimeInterval) -> ClockReading {
    ClockReading(bootID: boot, mono: UInt64(seconds * 1e9), wall: Date(timeIntervalSince1970: wall))
}

@Suite("Protections")
struct ProtectionsTests {
    @Test func offByDefault() throws {
        #expect(PersistedState().effectiveProtections == .off)
        // State files from before protections existed read as all off.
        let old = try Wire.decoder.decode(PersistedState.self, from: Data(#"{"alertURL":"https://ntfy.sh/x"}"#.utf8))
        #expect(old.effectiveProtections == .off)
        // Missing keys read as off.
        let partial = try Wire.decoder.decode(Protections.self, from: Data(#"{"keepRunning":true}"#.utf8))
        #expect(partial == Protections(keepRunning: true))
    }

    @Test func turnOnAnyTimeOffOnlyBetweenSessions() {
        let r = reading(mono: 10, wall: 1_000_000)
        var state = PersistedState()
        let on = Protections(keepRunning: true, lockSystemSettings: true)
        let turnedOn = try? state.setProtections(on, sessionActive: true, at: r).get().turnedOn
        #expect(turnedOn?.count == 2)
        #expect(state.protections == on)

        guard case .failure = state.setProtections(Protections(keepRunning: true), sessionActive: true, at: r) else {
            Issue.record("turning a protection off during a session should be refused")
            return
        }
        #expect(state.protections == on)

        let turnedOff = try? state.setProtections(.off, sessionActive: false, at: r).get().turnedOff
        #expect(turnedOff?.count == 2)
        #expect(state.protections == nil)
        #expect(state.effectiveProtections == .off)
    }

    @Test func coolingOffTakesADayToTurnOff() throws {
        let start = reading(mono: 10, wall: 1_000_000)
        var state = PersistedState()
        _ = state.setProtections(Protections(uninstallCoolingOff: true), sessionActive: false, at: start)

        // Asking to turn it off (allowed even during a session) starts the wait.
        let c = try state.setProtections(.off, sessionActive: true, at: start).get()
        #expect(c.coolingOffRemovalRequested)
        #expect(c.turnedOff.isEmpty)
        #expect(state.effectiveProtections.uninstallCoolingOff)
        #expect(state.coolingOffRemovalDate(at: start) == start.wall.addingTimeInterval(UninstallPolicy.delay))

        // Moving the date forward doesn't speed it up.
        let jumped = reading(mono: 70, wall: 1_000_000 + 2 * 86_400)
        let earlyApplied = state.applyDueCoolingOffRemoval(at: jumped)
        #expect(!earlyApplied)
        #expect(state.effectiveProtections.uninstallCoolingOff)

        let later = reading(mono: 10 + UninstallPolicy.delay + 1, wall: 1_000_000 + UninstallPolicy.delay + 1)
        let applied = state.applyDueCoolingOffRemoval(at: later)
        #expect(applied)
        #expect(!state.effectiveProtections.uninstallCoolingOff)
        #expect(state.coolingOffRemoval == nil)
    }

    @Test func switchingCoolingOffBackOnCancelsTheWait() throws {
        let r = reading(mono: 10, wall: 1_000_000)
        var state = PersistedState()
        _ = state.setProtections(Protections(keepRunning: true, uninstallCoolingOff: true), sessionActive: false, at: r)
        _ = try state.setProtections(Protections(keepRunning: true), sessionActive: false, at: r).get()
        #expect(state.coolingOffRemoval != nil)

        // Asking again doesn't restart the wait.
        let again = try state.setProtections(Protections(keepRunning: true), sessionActive: false,
                                             at: reading(mono: 3_000, wall: 1_003_000)).get()
        #expect(again.isEmpty)
        #expect(state.coolingOffRemovalDate(at: r) == r.wall.addingTimeInterval(UninstallPolicy.delay))

        let cancel = try state.setProtections(Protections(keepRunning: true, uninstallCoolingOff: true),
                                              sessionActive: true, at: r).get()
        #expect(cancel.coolingOffRemovalCancelled)
        #expect(state.coolingOffRemoval == nil)
        #expect(state.effectiveProtections.uninstallCoolingOff)
    }

    @Test func survivesTheWireAndCheckpoints() throws {
        let r = reading(mono: 10, wall: 1_000_000)
        var state = PersistedState()
        _ = state.setProtections(.all, sessionActive: false, at: r)
        _ = state.setProtections(Protections(keepRunning: true, lockSystemSettings: true, closeUnwatchedBrowsers: true),
                                 sessionActive: false, at: r)
        state.checkpoint(at: reading(mono: 610, wall: 1_000_600))
        let decoded = try Wire.decoder.decode(PersistedState.self, from: Wire.encoder.encode(state))
        #expect(decoded.protections == state.protections)
        #expect(decoded.coolingOffRemoval?.remaining == UninstallPolicy.delay - 600)
    }

    @Test func changingAnotherProtectionKeepsThePendingRemoval() throws {
        let r = reading(mono: 10, wall: 1_000_000)
        var state = PersistedState()
        _ = state.setProtections(Protections(uninstallCoolingOff: true), sessionActive: false, at: r)
        _ = try state.setProtections(.off, sessionActive: false, at: r).get()

        // A client builds its change on what the status reports as requested.
        let status = Status(session: nil, serverTime: r.wall, agents: [], protections: state.effectiveProtections,
                            coolingOffRemovalAt: state.coolingOffRemovalDate(at: r))
        var p = try #require(status.requestedProtections)
        #expect(!p.uninstallCoolingOff)
        p.keepRunning = true
        let c = try state.setProtections(p, sessionActive: false, at: r).get()
        #expect(!c.coolingOffRemovalCancelled)
        #expect(state.coolingOffRemoval != nil)
        #expect(state.effectiveProtections == Protections(keepRunning: true, uninstallCoolingOff: true))
    }

    @Test func coolingOffWaitsForTheSessionToEnd() throws {
        let r = reading(mono: 10, wall: 1_000_000)
        var state = PersistedState()
        _ = state.setProtections(Protections(uninstallCoolingOff: true), sessionActive: false, at: r)
        _ = try state.setProtections(.off, sessionActive: false, at: r).get()
        let due = reading(mono: 10 + UninstallPolicy.delay + 1, wall: 1_000_000 + UninstallPolicy.delay + 1)
        state.setSession(SessionInfo(startedAt: due.wall, endsAt: due.wall.addingTimeInterval(600), rules: ["x.com"]), at: due)

        let duringSession = state.applyDueCoolingOffRemoval(at: due)
        #expect(!duringSession)
        #expect(state.effectiveProtections.uninstallCoolingOff)

        let after = reading(mono: 10 + UninstallPolicy.delay + 700, wall: 1_000_000 + UninstallPolicy.delay + 700)
        let applied = state.applyDueCoolingOffRemoval(at: after)
        #expect(applied)
        #expect(!state.effectiveProtections.uninstallCoolingOff)
    }

    @Test func olderDaemonsCountAsCoolingOff() {
        let old = Status(session: nil, serverTime: Date(), agents: [])
        #expect(old.enforcesCoolingOff)
        #expect(old.requestedProtections == nil)
        #expect(!Status(session: nil, serverTime: Date(), agents: [], protections: .off).enforcesCoolingOff)
    }

    @Test func namesRoundTrip() {
        #expect(Protections.keys(named: "all")?.count == Protections.catalog.count)
        #expect(Protections.keys(named: "nope") == nil)
        var p = Protections.off
        for k in Protections.keys(named: "lock-settings") ?? [] { p[keyPath: k] = true }
        #expect(p.onNames == ["lock-settings"])
    }
}
