import XCTest

@testable import Galactic

/// Which place a dragged tab has earned.
///
/// This exists because the rule was wrong once in a way no test could see: it
/// lived in a view, and comparing a centre to a midline oscillated on every
/// frame the pointer held still near a boundary. The arithmetic is out here now,
/// and the anti-oscillation property is the first thing asserted.
final class FileTabRowGeometryTests: XCTestCase {

    /// Three 100pt tabs, 10pt apart, starting at 5.
    /// Slots: 0 → 5..105 (mid 55), 1 → 115..215 (mid 165), 2 → 225..325 (mid 275).
    private let row = FileTabRowGeometry(
        widths: [100, 100, 100], spacing: 10, leading: 5
    )

    // MARK: - Where the slots are

    func testTheFirstTabStartsAtTheLeadingInset() {
        XCTAssertEqual(row.minX(at: 0), 5)
    }

    func testEachSlotAddsAWidthAndASpacing() {
        XCTAssertEqual(row.minX(at: 1), 115)
        XCTAssertEqual(row.minX(at: 2), 225)
    }

    func testMidlinesSitHalfwayAcrossASlot() {
        XCTAssertEqual(row.midX(at: 0), 55)
        XCTAssertEqual(row.midX(at: 1), 165)
    }

    /// Asked for the slot past the end while a tab is in flight, which is a real
    /// state rather than a mistake.
    func testAPositionPastTheEndIsAnswerable() {
        XCTAssertEqual(row.minX(at: 3), 335)
    }

    // MARK: - Earning the next place

    /// Holding still earns nothing, wherever the tab is sitting.
    func testATabAtRestMovesNowhere() {
        for index in 0..<3 {
            XCTAssertNil(
                row.step(draggedAt: index, leadingEdge: row.minX(at: index)),
                "a tab in slot \(index) moved without being dragged"
            )
        }
    }

    /// Trailing edge past the right neighbour's midline, and not before it.
    func testGoingRightNeedsTheTrailingEdgePastTheNeighboursMidline() {
        // Tab 0 dragged right. Its trailing edge is leadingEdge + 100, and
        // slot 1's midline is 165 — so it needs a leading edge past 65.
        XCTAssertNil(row.step(draggedAt: 0, leadingEdge: 64))
        XCTAssertEqual(row.step(draggedAt: 0, leadingEdge: 66), 1)
    }

    /// Leading edge past the left neighbour's midline, and not before it.
    func testGoingLeftNeedsTheLeadingEdgePastTheNeighboursMidline() {
        // Tab 1 dragged left. Slot 0's midline is 55.
        XCTAssertNil(row.step(draggedAt: 1, leadingEdge: 56))
        XCTAssertEqual(row.step(draggedAt: 1, leadingEdge: 54), 0)
    }

    // MARK: - The property that stops it bouncing

    /// **The regression this file exists for.** Having just moved right, the tab
    /// must not immediately be eligible to move back — otherwise a pointer
    /// holding still near a boundary flips it on every frame.
    func testAStepRightIsNotImmediatelyEligibleToStepBack() {
        let edge: CGFloat = 66
        XCTAssertEqual(
            row.step(draggedAt: 0, leadingEdge: edge), 1,
            "fixture does not actually cross"
        )
        XCTAssertNil(
            row.step(draggedAt: 1, leadingEdge: edge),
            "the tab moved right and is already owed a move back — this is the "
                + "oscillation that made dragging bounce"
        )
    }

    func testAStepLeftIsNotImmediatelyEligibleToStepBack() {
        let edge: CGFloat = 54
        XCTAssertEqual(row.step(draggedAt: 1, leadingEdge: edge), 0)
        XCTAssertNil(row.step(draggedAt: 0, leadingEdge: edge))
    }

    /// **The second regression, and the one the sweep below could not see.**
    ///
    /// Re-evaluating against the row as it was *before* the move reverses a wide
    /// tab that has just passed a narrow one: the reversed condition is measured
    /// against the dragged tab's own width still sitting in the slot it left, so
    /// its midline is most of a row away. It failed in one direction only, and
    /// only for that width order, which is what made left-to-right look
    /// unimplemented while right-to-left worked.
    ///
    /// Every check below uses equal widths, where a swap changes nothing and
    /// stale geometry is indistinguishable from fresh. That is exactly why this
    /// case needs stating separately.
    func testAWideTabPassingANarrowOneStaysPast() {
        let before = FileTabRowGeometry(
            widths: [840, 150], spacing: 3, leading: 6
        )
        let edge: CGFloat = 100
        XCTAssertEqual(
            before.step(draggedAt: 0, leadingEdge: edge), 1,
            "fixture does not cross"
        )

        // Narrow-then-wide once it has moved, which is the geometry the next
        // evaluation has to be given.
        let after = FileTabRowGeometry(
            widths: [150, 840], spacing: 3, leading: 6
        )
        XCTAssertNil(
            after.step(draggedAt: 1, leadingEdge: edge),
            "a tab that just passed its neighbour is owed a move back"
        )

        // And the failing form, kept as the statement of what went wrong.
        XCTAssertEqual(
            before.step(draggedAt: 1, leadingEdge: edge), 0,
            "stale widths no longer reverse the move — has the caller stopped "
                + "re-reading them?"
        )
    }

    /// The gap between the two conditions, swept. At no leading edge should a
    /// slot both want to advance and, having advanced, want to retreat.
    func testNoPositionInTheRowOscillates() {
        for step in 0...400 {
            let edge = CGFloat(step) - 50
            for index in 0..<3 {
                guard let next = row.step(draggedAt: index, leadingEdge: edge)
                else { continue }
                let back = row.step(draggedAt: next, leadingEdge: edge)
                XCTAssertNotEqual(
                    back, index,
                    "at edge \(edge), slot \(index) and \(next) trade places "
                        + "forever"
                )
            }
        }
    }

    /// A centre-against-midline rule is what oscillated. Kept as a statement of
    /// what the edge rule buys: the two thresholds are a whole tab apart, which
    /// is the room the pointer has to sit in without anything moving.
    func testTheTwoThresholdsAreAWholeTabApart() {
        // Slot 1: moves right past 165 - 100 = 65, left before 55.
        let rightward: CGFloat = 65
        let leftward: CGFloat = 55
        XCTAssertEqual(rightward - leftward, 10)
        XCTAssertNil(row.step(draggedAt: 1, leadingEdge: 60))
    }

    // MARK: - Arriving from another row

    func testABareEdgeNamesTheSlotItIsLeftOf() {
        let others = FileTabRowGeometry(
            widths: [100, 100], spacing: 10, leading: 5
        )
        XCTAssertEqual(others.slot(forLeadingEdge: 0), 0)
        XCTAssertEqual(others.slot(forLeadingEdge: 60), 1)
        XCTAssertEqual(others.slot(forLeadingEdge: 300), 2)
    }

    func testAnEmptyRowTakesTheTabAtTheFront() {
        let empty = FileTabRowGeometry(widths: [], spacing: 10, leading: 5)
        XCTAssertEqual(empty.slot(forLeadingEdge: 400), 0)
        XCTAssertNil(empty.step(draggedAt: 0, leadingEdge: 0))
    }

    // MARK: - Staying inside the strip

    func testATabCannotBeDraggedOffTheLeftEdge() {
        XCTAssertEqual(
            row.clamped(leadingEdge: -400, width: 100, stripWidth: 500), 5
        )
    }

    func testATabCannotBeDraggedOffTheRightEdge() {
        // 500 wide, 5 of inset each side, a 100pt tab: the furthest its leading
        // edge can sit is 395.
        XCTAssertEqual(
            row.clamped(leadingEdge: 900, width: 100, stripWidth: 500), 395
        )
    }

    func testAPositionInsideTheStripIsLeftAlone() {
        XCTAssertEqual(
            row.clamped(leadingEdge: 200, width: 100, stripWidth: 500), 200
        )
    }

    /// A tab wider than the strip pins to the left rather than inverting the
    /// range, which would put the upper bound left of the lower one and clamp
    /// every position to a negative.
    func testATabWiderThanTheStripPinsLeft() {
        XCTAssertEqual(
            row.clamped(leadingEdge: 300, width: 900, stripWidth: 500), 5
        )
    }

    // MARK: - Ragged widths, which is the real case

    /// Labels are sized by what fits, so widths differ. The rule is stated in
    /// terms of each neighbour's own midline for that reason.
    func testUnevenWidthsUseEachNeighboursOwnMidline() {
        let ragged = FileTabRowGeometry(
            widths: [40, 200, 60], spacing: 10, leading: 0
        )
        XCTAssertEqual(ragged.midX(at: 1), 150)
        // Tab 0 is 40 wide, so its trailing edge passes 150 at 110.
        XCTAssertNil(ragged.step(draggedAt: 0, leadingEdge: 109))
        XCTAssertEqual(ragged.step(draggedAt: 0, leadingEdge: 111), 1)
    }
}
