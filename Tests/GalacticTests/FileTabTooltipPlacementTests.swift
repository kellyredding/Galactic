import XCTest

@testable import Galactic

/// Where the strip's tooltip sits.
///
/// The reason these exist rather than the arithmetic living in the view: a
/// tooltip on a tab near the right edge ran off the window and was invisible,
/// which is the single outcome it must never have, and nothing in the view
/// could have caught it.
final class FileTabTooltipPlacementTests: XCTestCase {

    private let padding: CGFloat = 6
    private let inset: CGFloat = 12

    private func x(
        tab: CGFloat, tooltip: CGFloat, strip: CGFloat = 800
    ) -> CGFloat {
        FileTabTooltipPlacement.x(
            tabLeadingEdge: tab,
            tooltipWidth: tooltip,
            stripWidth: strip,
            inset: inset,
            padding: padding
        )
    }

    // MARK: - Left of the edge, nothing moves

    /// The common case: room to spare, so the panel sits where it wants — a
    /// little right of the tab, which is what keeps it from reading as the tab.
    func testAPanelWithRoomSitsInsetFromItsTab() {
        XCTAssertEqual(x(tab: 100, tooltip: 200), 112)
    }

    func testTheInsetIsKeptEvenAtTheLeftmostTab() {
        XCTAssertEqual(x(tab: padding, tooltip: 200), padding + inset)
    }

    // MARK: - The edge case this type exists for

    /// A tab near the right edge with a long path: the panel is pulled back
    /// exactly as far as the edge demands, and its trailing edge lands on the
    /// strip's padding.
    func testAPanelThatWouldOverflowIsPulledBackToTheEdge() {
        let placed = x(tab: 700, tooltip: 300, strip: 800)

        XCTAssertEqual(placed, 800 - 6 - 300, "flush against the right padding")
        XCTAssertEqual(placed + 300, 800 - padding)
    }

    /// And no further than that. Clamping must not become flipping — the panel
    /// stays beside its tab rather than jumping to the other side of it.
    func testAPanelIsPulledBackNoFurtherThanNecessary() {
        let barely = x(tab: 500, tooltip: 300, strip: 800)

        XCTAssertEqual(barely, 494, "pulled back 18pt, not to some anchor")
        XCTAssertLessThan(barely, 500 + inset)
    }

    /// Width decides, not which half the tab is in. A short path on a
    /// right-hand tab does not move at all — which is the case the
    /// half-of-the-window heuristic would have moved for no reason.
    func testAShortPanelOnARightHandTabDoesNotMove() {
        XCTAssertEqual(x(tab: 700, tooltip: 60, strip: 800), 712)
    }

    /// And the converse: a path long enough to overflow from a *left*-hand tab
    /// is clamped too. The overflow comes from the content's width, so a rule
    /// reading only which half the tab sits in would have missed this entirely
    /// — the tab here is as far left as tabs get.
    func testALongPanelOnALeftHandTabIsStillClamped() {
        let placed = x(tab: 20, tooltip: 770, strip: 800)

        XCTAssertEqual(placed, 800 - 6 - 770, "flush against the right padding")
        XCTAssertLessThan(placed, 20 + inset, "pulled left of where it wanted")
    }

    // MARK: - Degenerate widths

    /// A path wider than the window cannot be shown whole. Pinned to the
    /// leading edge, so the part a reader scans first is the part on screen.
    func testAPanelWiderThanTheStripIsPinnedToTheLeadingEdge() {
        XCTAssertEqual(x(tab: 400, tooltip: 2_000, strip: 800), padding)
    }

    /// The strip has no width on its first pass, and clamping to zero would pin
    /// every tooltip to the left edge for a frame.
    func testAnUnmeasuredStripDoesNotClamp() {
        XCTAssertEqual(x(tab: 100, tooltip: 200, strip: 0), 112)
    }

    // MARK: - Vertical

    private func y(row: Int, rows: Int) -> CGFloat {
        FileTabTooltipPlacement.offsetFromBottom(
            aboveRow: row, rowCount: rows,
            tabHeight: 20, rowSpacing: 3, gap: 4
        )
    }

    /// Negative, because it hangs above the strip's bottom edge — and further
    /// up for an earlier row.
    func testAnEarlierRowSitsHigher() {
        XCTAssertLessThan(y(row: 0, rows: 3), y(row: 2, rows: 3))
    }

    /// Exactly one row's pitch between neighbours, so the panel tracks the row
    /// it belongs to rather than drifting.
    func testEachRowIsOnePitchApart() {
        XCTAssertEqual(y(row: 1, rows: 3) - y(row: 0, rows: 3), 23)
    }

    /// The last row's panel clears the row's top by the gap, which is what puts
    /// it over the row above instead of under the reader.
    func testTheLastRowsPanelClearsThatRowsTop() {
        let rows = 3
        let stripHeight = 2 * 3 + CGFloat(rows) * 20 + CGFloat(rows - 1) * 3
        let rowTop = 3 + CGFloat(rows - 1) * 23

        XCTAssertEqual(y(row: rows - 1, rows: rows), rowTop - 4 - stripHeight)
    }

    /// A single-row strip is the one case with nothing above it inside the
    /// strip, and the answer is still above — it overhangs, which is visible,
    /// rather than below, which is not.
    func testASingleRowPanelStillHangsAbove() {
        XCTAssertLessThan(y(row: 0, rows: 1), 0)
    }
}
