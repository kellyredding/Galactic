import AppKit
import XCTest
@testable import Galactic

/// Opening a scrollback surface by scrolling up, and not re-opening it with
/// the tail of the gesture that closed it.
///
/// The interesting cases are the refusals. Entry that fires when it should is
/// visible immediately; entry that fires when it should not looks like the app
/// ignoring a dismissal, or like a surface appearing for no reason at all.
final class ScrollToEnterScrollbackTests: XCTestCase {

    /// Short enough to keep the suite quick, long enough that arming and
    /// checking in the same runloop lands well inside it.
    private let window: TimeInterval = 0.2

    private var enabled: StubConfiguration {
        var configuration = StubConfiguration()
        configuration.scrollToEnterScrollback = true
        return configuration
    }

    private let optedOut = StubConfiguration()

    /// Let the main queue drain, plus optionally wait out a duration.
    private func settle(_ seconds: TimeInterval = 0) {
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.02) {
            done.fulfill()
        }
        wait(for: [done], timeout: seconds + 2)
    }

    // MARK: - The entry rule

    func testScrollEntersWhenEnabledWithContentAboveTheFold() {
        let entry = ScrollToEnterScrollback(window: window)

        XCTAssertTrue(
            entry.shouldEnter(
                configuration: enabled, isSurfaceOpen: false, hasContent: true
            )
        )
    }

    /// The opt-out an app takes by supplying a value rather than by omitting
    /// the mechanism.
    func testScrollNeverEntersWhenTheAppOptedOut() {
        let entry = ScrollToEnterScrollback(window: window)

        XCTAssertFalse(
            entry.shouldEnter(
                configuration: optedOut, isSurfaceOpen: false, hasContent: true
            ),
            "an app answering false must never open a surface by scroll"
        )
    }

    /// An ordinary gesture on a terminal with nothing above the fold is not a
    /// request for anything.
    func testScrollDoesNotEnterWithNothingToScrollBackTo() {
        let entry = ScrollToEnterScrollback(window: window)

        XCTAssertFalse(
            entry.shouldEnter(
                configuration: enabled, isSurfaceOpen: false, hasContent: false
            )
        )
    }

    func testScrollDoesNotEnterWhileTheSurfaceIsAlreadyOpen() {
        let entry = ScrollToEnterScrollback(window: window)

        XCTAssertFalse(
            entry.shouldEnter(
                configuration: enabled, isSurfaceOpen: true, hasContent: true
            )
        )
    }

    // MARK: - The cooldown

    /// The behaviour the cooldown exists for: momentum still arriving after a
    /// dismiss must not open the surface again.
    func testMomentumAfterADismissDoesNotReEnter() {
        let entry = ScrollToEnterScrollback(window: window)

        entry.beginCooldown(configuration: enabled)

        XCTAssertFalse(
            entry.shouldEnter(
                configuration: enabled, isSurfaceOpen: false, hasContent: true
            ),
            "the tail of the dismissing gesture must be ignored"
        )
    }

    /// The wheel case — no phases will ever arrive, so the clock is the only
    /// thing that can clear the gate.
    func testTheCooldownClearsOnceTheWindowElapses() {
        let entry = ScrollToEnterScrollback(window: window)

        entry.beginCooldown(configuration: enabled)
        settle(window)

        XCTAssertTrue(
            entry.shouldEnter(
                configuration: enabled, isSurfaceOpen: false, hasContent: true
            ),
            "a deliberate scroll after the momentum has died must still open"
        )
    }

    /// The trackpad case — the gesture reports its own end, and a long glide
    /// should not be cut short by a clock that has not run out yet.
    func testTheEndOfTheGestureClearsTheCooldownEarly() {
        let entry = ScrollToEnterScrollback(window: window)

        entry.beginCooldown(configuration: enabled)
        entry.endCooldown()

        XCTAssertFalse(entry.isCoolingDown)
        XCTAssertTrue(
            entry.shouldEnter(
                configuration: enabled, isSurfaceOpen: false, hasContent: true
            )
        )
    }

    /// An app that cannot enter by scroll has nothing to be protected from, so
    /// it should not be installing an application-wide scroll monitor on every
    /// dismissal.
    func testNoCooldownIsArmedWhenTheAppOptedOut() {
        let entry = ScrollToEnterScrollback(window: window)

        entry.beginCooldown(configuration: optedOut)

        XCTAssertFalse(entry.isCoolingDown)
    }

    /// Two dismissals inside one window. The second re-arm must leave exactly
    /// one cooldown running, not stack a second on top of it.
    func testReArmingReplacesTheCooldownRatherThanStackingOne() {
        let entry = ScrollToEnterScrollback(window: window)

        entry.beginCooldown(configuration: enabled)
        entry.beginCooldown(configuration: enabled)

        XCTAssertTrue(entry.isCoolingDown)

        settle(window)

        XCTAssertFalse(
            entry.isCoolingDown,
            "the surviving cooldown must still clear itself on the clock"
        )
    }

    // MARK: - What counts as the end of a gesture

    func testMomentumEndingIsTheEndOfTheGesture() {
        XCTAssertTrue(
            ScrollToEnterScrollback.gestureHasEnded(
                momentumPhase: .ended, phase: []
            )
        )
    }

    /// Fingers lifting while momentum is still running is the end of the
    /// *touch*, not of the gesture — the surface would re-open under the glide.
    func testFingersLiftingMidGlideIsNotTheEnd() {
        XCTAssertFalse(
            ScrollToEnterScrollback.gestureHasEnded(
                momentumPhase: .changed, phase: .ended
            )
        )
    }

    /// A drag that stops without being thrown produces no momentum at all, so
    /// its own end is the only end there is.
    func testADragThatWasNotThrownEndsWithItsPhase() {
        XCTAssertTrue(
            ScrollToEnterScrollback.gestureHasEnded(
                momentumPhase: [], phase: .ended
            )
        )
    }

    func testAGestureStillInProgressHasNotEnded() {
        XCTAssertFalse(
            ScrollToEnterScrollback.gestureHasEnded(
                momentumPhase: [], phase: .changed
            )
        )
    }
}
