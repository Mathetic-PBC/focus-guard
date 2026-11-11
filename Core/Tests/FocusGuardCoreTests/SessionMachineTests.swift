import XCTest
@testable import FocusGuardCore

final class SessionMachineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let deep = "deep"
    let writing = "writing"

    func env(hold: Bool = false, known: Set<String> = ["deep", "writing"]) -> SessionEnvironment {
        SessionEnvironment(
            cooldown: { known.contains($0) ? 120 : nil },
            canHold: { _ in hold })
    }

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testFocusOnStartsBlocking() {
        var m = SessionMachine()
        XCTAssertEqual(m.handle(.observed(deep), now: t0, env: env()), [.startBlocking(deep)])
        XCTAssertEqual(m.state, .active(profileID: deep))
    }

    func testUnknownProfileIsIgnored() {
        var m = SessionMachine()
        XCTAssertEqual(m.handle(.observed("gone"), now: t0, env: env()), [])
        XCTAssertEqual(m.state, .idle)
    }

    func testFocusOffStartsCooldownAndKeepsBlocking() {
        var m = SessionMachine()
        _ = m.handle(.observed(deep), now: t0, env: env())
        let effects = m.handle(.observed(nil), now: at(10), env: env())
        XCTAssertEqual(effects, [.showCooldown(profileID: deep, until: at(130))])
        XCTAssertEqual(m.state, .coolingDown(profileID: deep, until: at(130)))
        XCTAssertFalse(effects.contains(.stopBlocking))
    }

    func testBlockingEndsOnlyWhenCooldownRunsOut() {
        var m = SessionMachine()
        _ = m.handle(.observed(deep), now: t0, env: env())
        _ = m.handle(.observed(nil), now: at(10), env: env())
        XCTAssertEqual(m.handle(.tick, now: at(129), env: env()), [])
        XCTAssertEqual(m.handle(.tick, now: at(130), env: env()), [.hideCooldown, .stopBlocking])
        XCTAssertEqual(m.state, .idle)
    }

    func testStayFocusedCancelsCooldown() {
        var m = SessionMachine()
        _ = m.handle(.observed(deep), now: t0, env: env())
        _ = m.handle(.observed(nil), now: at(10), env: env())
        XCTAssertEqual(m.handle(.cancelCooldown, now: at(60), env: env()), [.hideCooldown])
        XCTAssertEqual(m.state, .active(profileID: deep))
        XCTAssertEqual(m.handle(.tick, now: at(500), env: env()), [])
        XCTAssertEqual(m.state, .active(profileID: deep))
    }

    func testSwitchingFocusBackOnByHandCancelsCooldown() {
        var m = SessionMachine()
        _ = m.handle(.observed(deep), now: t0, env: env())
        _ = m.handle(.observed(nil), now: at(10), env: env())
        XCTAssertEqual(m.handle(.observed(deep), now: at(12), env: env()), [.hideCooldown])
        XCTAssertEqual(m.state, .active(profileID: deep))
    }

    func testHoldSwitchesFocusBackOnWithoutCancelling() {
        var m = SessionMachine()
        let e = env(hold: true)
        _ = m.handle(.observed(deep), now: t0, env: e)
        XCTAssertEqual(
            m.handle(.observed(nil), now: at(10), env: e),
            [.showCooldown(profileID: deep, until: at(130)), .holdFocus(deep)])
        // The Focus returns because we asked for it. The countdown must go on.
        XCTAssertEqual(m.handle(.observed(deep), now: at(12), env: e), [])
        XCTAssertEqual(m.state, .coolingDown(profileID: deep, until: at(130)))
    }

    func testHeldFocusIsReleasedWhenCooldownEnds() {
        var m = SessionMachine()
        let e = env(hold: true)
        _ = m.handle(.observed(deep), now: t0, env: e)
        _ = m.handle(.observed(nil), now: at(10), env: e)
        _ = m.handle(.observed(deep), now: at(12), env: e)
        XCTAssertEqual(
            m.handle(.tick, now: at(130), env: e),
            [.hideCooldown, .stopBlocking, .releaseFocus(deep)])
        XCTAssertEqual(m.state, .idle)
        // The Focus is still reported on for a moment. It must not restart the session.
        XCTAssertEqual(m.handle(.observed(deep), now: at(131), env: e), [])
        XCTAssertEqual(m.state, .idle)
        // Once seen off, the next switch-on is a new session.
        XCTAssertEqual(m.handle(.observed(nil), now: at(132), env: e), [])
        XCTAssertEqual(m.handle(.observed(deep), now: at(200), env: e), [.startBlocking(deep)])
    }

    func testSwitchingOffAgainDuringHeldCooldownHoldsAgain() {
        var m = SessionMachine()
        let e = env(hold: true)
        _ = m.handle(.observed(deep), now: t0, env: e)
        _ = m.handle(.observed(nil), now: at(10), env: e)
        _ = m.handle(.observed(deep), now: at(12), env: e)
        XCTAssertEqual(m.handle(.observed(nil), now: at(40), env: e), [.holdFocus(deep)])
        XCTAssertEqual(m.handle(.observed(deep), now: at(42), env: e), [])
        XCTAssertEqual(m.state, .coolingDown(profileID: deep, until: at(130)))
    }

    func testReturnOutsideHoldWindowCountsAsChangeOfMind() {
        var m = SessionMachine()
        let e = env(hold: true)
        _ = m.handle(.observed(deep), now: t0, env: e)
        _ = m.handle(.observed(nil), now: at(10), env: e)
        _ = m.handle(.tick, now: at(10 + SessionMachine.holdWindow + 1), env: e)
        XCTAssertEqual(m.handle(.observed(deep), now: at(60), env: e), [.hideCooldown])
        XCTAssertEqual(m.state, .active(profileID: deep))
    }

    func testStayFocusedAsksForFocusBackWhenItIsOff() {
        var m = SessionMachine()
        let e = env(hold: true)
        _ = m.handle(.observed(deep), now: t0, env: e)
        _ = m.handle(.observed(nil), now: at(10), env: e)
        _ = m.handle(.tick, now: at(40), env: e)
        XCTAssertEqual(m.handle(.cancelCooldown, now: at(50), env: e), [.hideCooldown, .holdFocus(deep)])
        XCTAssertEqual(m.handle(.observed(deep), now: at(52), env: e), [])
        XCTAssertEqual(m.state, .active(profileID: deep))
    }

    func testEndSessionFromMenuAlsoWaits() {
        var m = SessionMachine()
        _ = m.handle(.observed(deep), now: t0, env: env())
        XCTAssertEqual(
            m.handle(.requestEnd, now: at(5), env: env()),
            [.showCooldown(profileID: deep, until: at(125))])
        XCTAssertEqual(
            m.handle(.tick, now: at(125), env: env()),
            [.hideCooldown, .stopBlocking, .releaseFocus(deep)])
        // The Focus is still on in macOS. It stays ignored until it goes off.
        XCTAssertEqual(m.suppressed, deep)
    }

    func testSwitchingToAnotherConnectedFocusWaitsThenChangesRules() {
        var m = SessionMachine()
        _ = m.handle(.observed(deep), now: t0, env: env())
        _ = m.handle(.observed(writing), now: at(10), env: env())
        XCTAssertEqual(m.state, .coolingDown(profileID: deep, until: at(130)))
        XCTAssertEqual(m.handle(.tick, now: at(130), env: env()), [.hideCooldown, .startBlocking(writing)])
        XCTAssertEqual(m.state, .active(profileID: writing))
    }

    func testRestartDuringCooldownDoesNotShortenIt() {
        var m = SessionMachine(restoring: .coolingDown(profileID: deep, until: at(20)), suppressed: nil)
        XCTAssertEqual(m.state, .active(profileID: deep))
        // The cool-down that was about to finish is gone. A full one starts.
        XCTAssertEqual(
            m.handle(.observed(nil), now: at(19), env: env()),
            [.showCooldown(profileID: deep, until: at(139))])
    }

    func testRestartWhileFocusStillOnStaysActive() {
        var m = SessionMachine(restoring: .active(profileID: deep), suppressed: nil)
        XCTAssertEqual(m.handle(.observed(deep), now: t0, env: env()), [])
        XCTAssertEqual(m.state, .active(profileID: deep))
    }

    func testDeletedProfileEndsSessionWithoutCooldown() {
        var m = SessionMachine()
        _ = m.handle(.observed(deep), now: t0, env: env())
        XCTAssertEqual(m.handle(.observed(nil), now: at(10), env: env(known: [])), [.stopBlocking])
        XCTAssertEqual(m.state, .idle)
    }
}
