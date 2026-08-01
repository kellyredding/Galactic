import XCTest
@testable import Galactic

/// The zoom window, and the agreement that matters most: the menu item's
/// enabled state and the zoom itself have to share one idea of where the
/// boundary is. If `canIncrease` says yes where `increased` has already
/// stopped, the item stays enabled forever and pressing it does nothing —
/// which reads as the shortcut being broken rather than as the size being at
/// its limit.
final class TerminalFontSizeBoundsTests: XCTestCase {

    private let bounds = TerminalFontSizeBounds.standard

    func testTheStandardWindowIsTenToTwentyFourInSinglePoints() {
        XCTAssertEqual(bounds.range, 10...24)
        XCTAssertEqual(bounds.step, 1)
    }

    // MARK: - Stepping

    func testIncreasingMovesOneStep() {
        XCTAssertEqual(bounds.increased(from: 13), 14)
    }

    func testDecreasingMovesOneStep() {
        XCTAssertEqual(bounds.decreased(from: 13), 12)
    }

    func testIncreasingStopsAtTheCeiling() {
        XCTAssertEqual(bounds.increased(from: 24), 24)
        XCTAssertEqual(
            bounds.increased(from: 23.5), 24,
            "a size between the last step and the ceiling lands on the ceiling "
                + "rather than overshooting it"
        )
    }

    func testDecreasingStopsAtTheFloor() {
        XCTAssertEqual(bounds.decreased(from: 10), 10)
        XCTAssertEqual(bounds.decreased(from: 10.5), 10)
    }

    // MARK: - Agreement with the menu state

    func testTheCeilingIsWhereIncreasingStopsBeingOffered() {
        XCTAssertTrue(bounds.canIncrease(from: 23))
        XCTAssertFalse(
            bounds.canIncrease(from: 24),
            "offering a step that cannot move reads as a broken shortcut"
        )
    }

    func testTheFloorIsWhereDecreasingStopsBeingOffered() {
        XCTAssertTrue(bounds.canDecrease(from: 11))
        XCTAssertFalse(bounds.canDecrease(from: 10))
    }

    /// Walks the whole window and asserts the two never disagree: wherever a
    /// step is offered it must move, and wherever it is refused it must not.
    func testOfferingAndMovingAgreeAcrossTheWholeWindow() {
        var size = bounds.range.lowerBound
        while size <= bounds.range.upperBound {
            XCTAssertEqual(
                bounds.canIncrease(from: size),
                bounds.increased(from: size) != size,
                "increase disagreed at \(size)"
            )
            XCTAssertEqual(
                bounds.canDecrease(from: size),
                bounds.decreased(from: size) != size,
                "decrease disagreed at \(size)"
            )
            size += 0.5
        }
    }

    // MARK: - Sizes arriving from elsewhere

    func testAStoredSizeAboveTheWindowIsPulledIn() {
        XCTAssertEqual(bounds.clamped(40), 24)
    }

    func testAStoredSizeBelowTheWindowIsPulledIn() {
        XCTAssertEqual(bounds.clamped(4), 10)
    }

    func testASizeInsideTheWindowIsLeftAlone() {
        XCTAssertEqual(bounds.clamped(13), 13)
    }

    // MARK: - A different window

    func testACustomWindowGovernsItsOwnSteps() {
        let coarse = TerminalFontSizeBounds(range: 12...16, step: 2)

        XCTAssertEqual(coarse.increased(from: 12), 14)
        XCTAssertEqual(
            coarse.increased(from: 15), 16,
            "a step that would overshoot lands on the ceiling"
        )
        XCTAssertFalse(coarse.canIncrease(from: 16))
    }
}
