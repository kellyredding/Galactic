import XCTest
import JavaScriptCore
@testable import Galactic

/// The two-click delete, as a state machine.
///
/// Both card surfaces used to carry their own copy — one inlined into a single
/// method, one spread across four — and the copies had drifted into different
/// behavior. These pin the rules that were only ever written down in one of
/// them, and the overlap bug that came from the other not having them.
final class DeleteConfirmationTests: XCTestCase {

    private var context: JSContext!
    private var thrown: String?

    override func setUpWithError() throws {
        let context = try XCTUnwrap(JSContext())
        thrown = nil
        context.exceptionHandler = { [weak self] _, exception in
            self?.thrown = exception?.toString() ?? "unknown JS exception"
        }

        // The module assigns onto `window`, and the machine schedules its
        // revert with setTimeout. A bare JSContext has neither, so stand up
        // just those two — and make the clock and the timer queue drivable,
        // because every rule here is about elapsed time.
        context.evaluateScript(
            """
            var window = this;
            var __now = 0;
            var __timers = [];
            Date.now = function () { return __now; };
            var setTimeout = function (fn, ms) {
                __timers.push({ fn: fn, at: __now + ms });
                return __timers.length - 1;
            };
            var clearTimeout = function (id) {
                if (__timers[id]) __timers[id] = null;
            };
            // Advance the clock, firing whatever comes due.
            function __advance(ms) {
                __now += ms;
                for (var i = 0; i < __timers.length; i++) {
                    var t = __timers[i];
                    if (t && t.at <= __now) {
                        __timers[i] = null;
                        t.fn();
                    }
                }
            }
            """
        )
        context.evaluateScript(cardTextJS)

        // Buttons are plain objects: the machine only ever reads and writes
        // the two fields the styling helpers touch, so a DOM buys nothing.
        context.evaluateScript(
            """
            var __confirmed = [];
            var __buttons = {};
            function __button(id) {
                if (!__buttons[id]) {
                    __buttons[id] = {
                        textContent: '',
                        classList: {
                            _set: {},
                            add: function (c) { this._set[c] = true; },
                            remove: function (c) { delete this._set[c]; },
                            has: function (c) { return !!this._set[c]; }
                        }
                    };
                }
                return __buttons[id];
            }
            function __armed(id) {
                return __button(id).classList.has('confirming');
            }
            var __missing = {};
            var machine = window.GalaxyCardText.createDeleteConfirmation({
                findButton: function (id) {
                    return __missing[id] ? null : __button(id);
                },
                onConfirmed: function (id) { __confirmed.push(id); }
            });
            """
        )

        self.context = context
    }

    private func assertNoThrow() {
        if let thrown { XCTFail("JS threw: \(thrown)") }
    }

    private func run(_ script: String) -> JSValue? {
        let value = context.evaluateScript(script)
        assertNoThrow()
        return value
    }

    private var confirmed: [String] {
        run("__confirmed.join(',')")?.toString()
            .split(separator: ",").map(String.init) ?? []
    }

    private func armed(_ id: String) -> Bool {
        run("__armed('\(id)')")?.toBool() ?? false
    }

    // MARK: - The basic two clicks

    func testFirstClickArmsWithoutConfirming() {
        _ = run("machine.handleClick('a')")
        XCTAssertTrue(armed("a"), "the first click must arm the button")
        XCTAssertEqual(confirmed, [], "the first click must not delete anything")
    }

    func testSecondClickAfterTheRejectWindowConfirms() {
        _ = run("machine.handleClick('a'); __advance(600)")
        _ = run("machine.handleClick('a')")
        XCTAssertEqual(confirmed, ["a"], "a deliberate second click must confirm")
    }

    /// The reject window exists to swallow the second click of a double-click,
    /// which would otherwise arm and confirm in one gesture.
    func testSecondClickInsideTheRejectWindowIsIgnored() {
        _ = run("machine.handleClick('a'); __advance(100)")
        _ = run("machine.handleClick('a')")
        XCTAssertEqual(
            confirmed, [], "a click inside the reject window must not confirm"
        )
        XCTAssertTrue(armed("a"), "and it must leave the button armed")
    }

    /// The drain animation is the countdown as far as the user can see, so the
    /// button has to disarm exactly when it empties.
    func testArmingRevertsOnItsOwnAfterTheRevertWindow() {
        _ = run("machine.handleClick('a'); __advance(5000)")
        XCTAssertFalse(armed("a"), "the button must disarm when the timer fires")
        _ = run("machine.handleClick('a')")
        XCTAssertEqual(
            confirmed, [],
            "a click after the revert must arm afresh rather than confirm"
        )
    }

    // MARK: - The overlap rule

    /// Arming a second card disarms the first.
    func testArmingASecondCardDisarmsTheFirst() {
        _ = run("machine.handleClick('a'); __advance(100)")
        _ = run("machine.handleClick('b')")
        XCTAssertFalse(armed("a"), "the first card must disarm when another arms")
        XCTAssertTrue(armed("b"), "the second card must be the armed one")
    }

    /// The defect this consolidation fixes.
    ///
    /// One surface never disarmed the previous card, so the first card's revert
    /// timer stayed scheduled and fired while the second was armed, clearing
    /// state that no longer belonged to it. The second button went on reading
    /// "Are you sure?" while a click on it re-armed instead of confirming —
    /// visibly armed, functionally reset.
    func testTheFirstCardsTimerCannotDisarmTheSecond() {
        _ = run("machine.handleClick('a'); __advance(1000)")
        _ = run("machine.handleClick('b')")
        // Far enough for the first card's original timer to have come due.
        _ = run("__advance(4200)")
        XCTAssertTrue(
            armed("b"),
            "the first card's timer must not disarm the second"
        )
        _ = run("machine.handleClick('b')")
        XCTAssertEqual(
            confirmed, ["b"],
            "the second card must still confirm — armed and functional agree"
        )
    }

    // MARK: - In-flight and missing cards

    /// Once the host has been told, further clicks do nothing until it answers.
    func testClicksAreIgnoredWhileADeleteIsInFlight() {
        _ = run("machine.handleClick('a'); __advance(600)")
        _ = run("machine.handleClick('a')")
        _ = run("machine.handleClick('a'); __advance(600); machine.handleClick('a')")
        XCTAssertEqual(
            confirmed, ["a"], "a second delete must not be requested in flight"
        )
    }

    func testFinishReleasesTheMachine() {
        _ = run("machine.handleClick('a'); __advance(600); machine.handleClick('a')")
        _ = run("machine.finish()")
        _ = run("machine.handleClick('a'); __advance(600); machine.handleClick('a')")
        XCTAssertEqual(
            confirmed, ["a", "a"],
            "the machine must accept clicks again once the host has answered"
        )
    }

    /// A card already gone from the DOM must leave the machine idle rather
    /// than armed against a button nobody can click.
    func testAMissingButtonLeavesTheMachineUnarmed() {
        _ = run("__missing['gone'] = true; machine.handleClick('gone')")
        _ = run("__advance(600); machine.handleClick('gone')")
        XCTAssertEqual(
            confirmed, [],
            "a card with no button must not become confirmable"
        )
    }

    /// The card teardown clears without a click involved.
    func testClearDisarmsWhateverWasArmed() {
        _ = run("machine.handleClick('a')")
        _ = run("machine.clear()")
        XCTAssertFalse(armed("a"), "clear must disarm the armed button")
        _ = run("__advance(600); machine.handleClick('a')")
        XCTAssertEqual(
            confirmed, [], "and must leave the next click arming, not confirming"
        )
    }
}
