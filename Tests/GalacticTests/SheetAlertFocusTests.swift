import AppKit
import XCTest

@testable import Galactic

/// Whether a presented confirmation sheet can actually hear the answer.
///
/// Resolving a host window and presenting a sheet on it says nothing about
/// activation, so a sheet can arrive whose default button Return cannot reach.
/// The correction is a bounded retry, and a retry has two ways to be wrong that
/// no build failure would reveal: giving up before the sheet exists, and
/// carrying on after the user has answered. Both are pinned here.
///
/// Activation itself needs a running app and is left to manual verification —
/// what is testable is the decision, which is where the subtlety lives.
final class SheetAlertFocusTests: XCTestCase {

    /// Nothing to correct, so nothing is done. Worth stating first because
    /// every other case is a deviation from it.
    func testASheetHoldingTheKeyboardIsLeftAlone() {
        XCTAssertEqual(
            SheetAlert.nudge(
                sheetIsKey: true,
                sheetIsVisible: true,
                hasAppeared: true,
                attempt: 0
            ),
            .stop
        )
    }

    /// The reported bug, in one assertion: on screen, no keyboard.
    func testASheetOnScreenWithoutTheKeyboardIsNudged() {
        XCTAssertEqual(
            SheetAlert.nudge(
                sheetIsKey: false,
                sheetIsVisible: true,
                hasAppeared: true,
                attempt: 0
            ),
            .nudge
        )
    }

    /// The failure this whole loop exists to survive. `beginSheetModal` returns
    /// before the sheet is on screen, and sheets queue behind one another on the
    /// same window — so an invisible sheet this early has not been dismissed,
    /// it has not arrived. Reading it as dismissal abandons the fix in exactly
    /// the case it was written for.
    func testASheetThatHasNotAppearedYetIsWaitedFor() {
        XCTAssertEqual(
            SheetAlert.nudge(
                sheetIsKey: false,
                sheetIsVisible: false,
                hasAppeared: false,
                attempt: 0
            ),
            .wait,
            "a sheet is presented asynchronously, so absence before it has "
                + "ever appeared means not yet rather than gone"
        )
    }

    /// The other half of that distinction, and the reason appearance is carried
    /// rather than read once: a sheet that was on screen and now is not has
    /// been answered. Continuing would re-activate the app on every remaining
    /// pass, dragging the user back from wherever they went next.
    func testASheetThatAppearedAndIsGoneStops() {
        XCTAssertEqual(
            SheetAlert.nudge(
                sheetIsKey: false,
                sheetIsVisible: false,
                hasAppeared: true,
                attempt: 0
            ),
            .stop,
            "the user answered — a loop watching only for success would go on "
                + "stealing activation after they had finished"
        )
    }

    /// A sheet that will not take the keyboard has to fail visibly rather than
    /// leave the app tugging at the screen indefinitely.
    func testAskingStopsOnceTheAttemptsAreSpent() {
        XCTAssertEqual(
            SheetAlert.nudge(
                sheetIsKey: false,
                sheetIsVisible: true,
                hasAppeared: true,
                attempt: SheetAlert.maxAttempts
            ),
            .stop
        )
    }

    /// The boundary, pinned so the bound cannot quietly become off-by-one: the
    /// last attempt still acts.
    func testTheFinalAttemptStillActs() {
        XCTAssertEqual(
            SheetAlert.nudge(
                sheetIsKey: false,
                sheetIsVisible: true,
                hasAppeared: true,
                attempt: SheetAlert.maxAttempts - 1
            ),
            .nudge
        )
    }

    /// Waiting is bounded too. A sheet that never appears — presented on a
    /// window that went away, or queued behind one nobody answers — must not
    /// leave a timer rescheduling itself forever.
    func testWaitingForASheetThatNeverAppearsAlsoStops() {
        XCTAssertEqual(
            SheetAlert.nudge(
                sheetIsKey: false,
                sheetIsVisible: false,
                hasAppeared: false,
                attempt: SheetAlert.maxAttempts
            ),
            .stop
        )
    }

    /// Success outranks exhaustion, so the loop reports done rather than
    /// giving up on the pass where both are true.
    func testHoldingTheKeyboardOutranksASpentBudget() {
        XCTAssertEqual(
            SheetAlert.nudge(
                sheetIsKey: true,
                sheetIsVisible: true,
                hasAppeared: true,
                attempt: SheetAlert.maxAttempts
            ),
            .stop
        )
    }

    /// Half a second, give or take: long enough to outlast an activation race,
    /// short enough that a sheet nobody can focus stops being fought over.
    func testTheBudgetStaysWithinAboutHalfASecond() {
        let span = Double(SheetAlert.maxAttempts) * SheetAlert.retryInterval

        XCTAssertGreaterThan(span, 0.3)
        XCTAssertLessThan(span, 0.8)
    }
}
