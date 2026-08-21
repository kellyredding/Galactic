import XCTest

@testable import Galactic

/// Whether a hovered tab has earned a tooltip.
///
/// These are the rules that are invisible in view code and that two rounds of
/// drag defects taught this file to test directly instead: what the delay is
/// for, why it is not paid twice, and what happens when SwiftUI delivers hover
/// events in the order it actually delivers them rather than the order the
/// pointer moved.
final class FileTabHoverIntentTests: XCTestCase {

    private let one = FileTab.ID()
    private let two = FileTab.ID()

    // MARK: - The wait

    func testTheFirstTooltipWaits() {
        var intent = FileTabHoverIntent()

        XCTAssertEqual(intent.enter(one), .arm(one))
        XCTAssertFalse(intent.isShowing, "nothing is up until the wait is over")
    }

    func testTheWaitEndingShowsTheTooltip() {
        var intent = FileTabHoverIntent()
        _ = intent.enter(one)

        XCTAssertEqual(intent.elapsed(for: one), .show(one))
        XCTAssertEqual(intent.shown, one)
    }

    /// The whole point of waiting: a pointer crossing the strip on its way
    /// somewhere else must leave nothing behind it.
    func testAWaitOutlivedByThePointerShowsNothing() {
        var intent = FileTabHoverIntent()
        _ = intent.enter(one)
        _ = intent.exit(one)

        XCTAssertEqual(intent.elapsed(for: one), .ignore)
        XCTAssertFalse(intent.isShowing)
    }

    /// And the same when the pointer has moved on to a different tab rather
    /// than left entirely — the stale wait must not raise a tooltip on a tab
    /// nobody is pointing at.
    func testAWaitForATabThePointerHasLeftIsIgnored() {
        var intent = FileTabHoverIntent()
        _ = intent.enter(one)
        _ = intent.enter(two)

        XCTAssertEqual(intent.elapsed(for: one), .ignore)
        XCTAssertNil(intent.shown)
    }

    // MARK: - The wait is paid once

    /// Reading along a row must not cost a pause per tab.
    func testASecondTabShowsAtOnceWhileOneIsUp() {
        var intent = FileTabHoverIntent()
        _ = intent.enter(one)
        _ = intent.elapsed(for: one)

        XCTAssertEqual(intent.enter(two), .show(two))
        XCTAssertEqual(intent.shown, two)
    }

    /// But once it is down, the next one waits again — otherwise leaving the
    /// strip and coming back is instant, which is the strobing the delay exists
    /// to prevent.
    func testTheWaitReturnsAfterTheTooltipGoesDown() {
        var intent = FileTabHoverIntent()
        _ = intent.enter(one)
        _ = intent.elapsed(for: one)
        _ = intent.exit(one)

        XCTAssertEqual(intent.enter(two), .arm(two))
    }

    // MARK: - The order SwiftUI actually delivers

    /// **The defect this type exists for.** `onHover` delivers the new tab's
    /// enter before the old tab's exit, so a hide that trusts any exit turns
    /// the tooltip off immediately after turning it on — flickering exactly
    /// while the reader is doing the thing it is for.
    func testAStaleExitDoesNotHideTheTooltipItArrivedAfter() {
        var intent = FileTabHoverIntent()
        _ = intent.enter(one)
        _ = intent.elapsed(for: one)

        _ = intent.enter(two)  // pointer moves: enter arrives first
        XCTAssertEqual(intent.exit(one), .ignore, "the old tab's late exit")
        XCTAssertEqual(intent.shown, two, "still up, and showing the new tab")
    }

    func testTheCurrentTabsExitDoesHide() {
        var intent = FileTabHoverIntent()
        _ = intent.enter(one)
        _ = intent.elapsed(for: one)

        XCTAssertEqual(intent.exit(one), .hide)
        XCTAssertFalse(intent.isShowing)
    }

    func testAnExitBeforeAnythingIsShownIsNotAHide() {
        var intent = FileTabHoverIntent()
        _ = intent.enter(one)

        XCTAssertEqual(
            intent.exit(one), .ignore, "nothing was up, so nothing to take down"
        )
    }

    // MARK: - Dragging

    /// A drag holds the pointer down and walks it across every other tab in the
    /// strip, which is the worst case for anything that appears on hover.
    func testADragTakesTheTooltipDownAndKeepsItDown() {
        var intent = FileTabHoverIntent()
        _ = intent.enter(one)
        _ = intent.elapsed(for: one)

        XCTAssertEqual(intent.suppress(), .hide)
        XCTAssertEqual(intent.enter(two), .ignore)
        XCTAssertEqual(intent.elapsed(for: two), .ignore)
    }

    func testSuppressingWithNothingUpIsNotAHide() {
        var intent = FileTabHoverIntent()

        XCTAssertEqual(intent.suppress(), .ignore)
    }

    /// A drop must not leave a tooltip sitting under the cursor: resuming
    /// re-allows hover without showing anything by itself.
    func testResumingShowsNothingUntilThePointerArrivesAgain() {
        var intent = FileTabHoverIntent()
        _ = intent.suppress()
        intent.resume()

        XCTAssertFalse(intent.isShowing)
        XCTAssertEqual(intent.enter(one), .arm(one))
    }
}
