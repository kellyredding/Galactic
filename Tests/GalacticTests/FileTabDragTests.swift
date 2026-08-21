import XCTest

@testable import Galactic

/// Dragging a tab, including between rows.
///
/// These exist because two rounds of "dragging up and down locks the tab" could
/// not be answered by reading the view it lived in. Every case here is a gesture
/// spelled out as pointer positions.
final class FileTabDragTests: XCTestCase {

    private let metrics = FileTabDrag.Metrics(
        tabSpacing: 3,
        rowSpacing: 3,
        stripPadding: 6,
        tabHeight: 20,
        newRowMargin: 14
    )

    private let stripWidth: CGFloat = 600

    /// Five tabs of 100pt each, one row.
    private func oneRow(_ count: Int = 5) -> ([FileTab.ID], [FileTab.ID: CGFloat])
    {
        let ids = (0..<count).map { _ in UUID() }
        return (ids, Dictionary(uniqueKeysWithValues: ids.map { ($0, CGFloat(100)) }))
    }

    /// The vertical middle of a row band, which is where a row change commits.
    private func middleOfRow(_ row: Int) -> CGFloat {
        metrics.rowSpacing + CGFloat(row) * metrics.pitch + metrics.tabHeight / 2
    }

    private func drag(
        _ id: FileTab.ID, from x: CGFloat, arrangement: [[FileTab.ID]]
    ) -> FileTabDrag {
        FileTabDrag(
            id: id,
            grabX: 0,
            pointer: CGPoint(x: x, y: middleOfRow(0)),
            arrangement: arrangement,
            widths: Dictionary(
                uniqueKeysWithValues: arrangement.flatMap { $0 }
                    .map { ($0, CGFloat(100)) }
            ),
            metrics: metrics
        )
    }

    // MARK: - Within one row

    func testDraggingRightPastANeighbourTakesItsPlace() {
        let (ids, widths) = oneRow()
        var d = drag(ids[0], from: 6, arrangement: [ids])

        // Far enough right that the trailing edge clears the next tab's midline.
        d.update(
            pointer: CGPoint(x: 160, y: middleOfRow(0)),
            stripWidth: stripWidth
        )

        XCTAssertEqual(d.position(of: ids[0])?.column, 1)
    }

    // MARK: - Into a new row

    /// The reported gesture: drag a tab into the margin below the strip, which
    /// makes a row for it.
    func testDraggingBelowTheLastRowMakesANewRow() {
        let (ids, widths) = oneRow()
        var d = drag(ids[2], from: 212, arrangement: [ids])

        d.update(
            pointer: CGPoint(x: 212, y: metrics.pitch + metrics.newRowMargin / 2),
            stripWidth: stripWidth
        )

        XCTAssertEqual(d.proposal.count, 2)
        XCTAssertEqual(d.proposal[1], [ids[2]])
        XCTAssertEqual(d.proposal[0], [ids[0], ids[1], ids[3], ids[4]])
    }

    /// **The bug this file was written for.** Having arrived in a new row, the
    /// tab has to keep responding to the pointer — sideways and back up — rather
    /// than locking until the gesture ends.
    func testATabInItsNewRowStillAnswersThePointer() {
        let (ids, widths) = oneRow()
        var d = drag(ids[2], from: 212, arrangement: [ids])

        d.update(
            pointer: CGPoint(x: 212, y: metrics.pitch + metrics.newRowMargin / 2),
            stripWidth: stripWidth
        )
        XCTAssertEqual(d.proposal[1], [ids[2]], "precondition: it made the row")

        // Now back up into the first row, at its left-hand end.
        d.update(
            pointer: CGPoint(x: 6, y: middleOfRow(0)),
            stripWidth: stripWidth
        )

        XCTAssertEqual(
            d.proposal.count, 1,
            "the row it had to itself is gone with it"
        )
        XCTAssertEqual(
            d.proposal[0].first, ids[2],
            "and it landed at the left-hand end, where the pointer was"
        )
    }

    /// Sideways movement inside a row it has just arrived in.
    func testATabArrivingInARowSettlesSidewaysInTheSameGesture() {
        let ids = (0..<6).map { _ in UUID() }
        let widths = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGFloat(100)) })
        // Two rows of three.
        var d = drag(
            ids[5], from: 212,
            arrangement: [Array(ids[0..<3]), Array(ids[3..<6])]
        )
        // The dragged tab starts in the lower row, so start the pointer there.
        d.update(
            pointer: CGPoint(x: 212, y: middleOfRow(1)),
            stripWidth: stripWidth
        )

        // Up into the top row, at its far left.
        d.update(
            pointer: CGPoint(x: 6, y: middleOfRow(0)),
            stripWidth: stripWidth
        )

        XCTAssertEqual(
            d.proposal[0].first, ids[5],
            "arriving at the left of the row means the left of the row"
        )
        XCTAssertEqual(d.proposal[1].count, 2)
    }

    // MARK: - What gets drawn where

    /// Nothing has moved until the proposal moves something.
    func testNothingIsOffsetBeforeTheProposalChanges() {
        let (ids, _) = oneRow()
        let d = drag(ids[0], from: 6, arrangement: [ids])

        XCTAssertEqual(d.offset(of: ids[2], stripWidth: stripWidth), .zero)
    }

    /// A displaced neighbour is offset by exactly the dragged tab's width and
    /// the gap it leaves — the distance it has to travel to look like it swapped.
    func testADisplacedNeighbourIsOffsetByATabAndAGap() {
        let (ids, _) = oneRow()
        var d = drag(ids[0], from: 6, arrangement: [ids])

        d.update(
            pointer: CGPoint(x: 160, y: middleOfRow(0)),
            stripWidth: stripWidth
        )
        XCTAssertEqual(
            d.position(of: ids[0])?.column, 1, "precondition: they swapped"
        )

        // ids[1] moved from the second slot to the first, so it comes back by
        // one tab and one gap.
        XCTAssertEqual(
            d.offset(of: ids[1], stripWidth: stripWidth).width,
            -(100 + metrics.tabSpacing)
        )
    }

    /// A tab asked to change rows carries a row's pitch vertically, so the
    /// movement is something a reader can follow rather than a reappearance.
    func testChangingRowsOffsetsByARowsPitch() {
        let ids = (0..<4).map { _ in UUID() }
        var d = drag(
            ids[0], from: 6,
            arrangement: [Array(ids[0..<2]), Array(ids[2..<4])]
        )

        d.update(
            pointer: CGPoint(x: 6, y: middleOfRow(1)),
            stripWidth: stripWidth
        )

        XCTAssertEqual(
            d.offset(of: ids[0], stripWidth: stripWidth).height, metrics.pitch
        )
    }

    /// The dragged tab tracks the pointer rather than its slot: easing it would
    /// put the tab behind the hand moving it, which reads as the drag dropping.
    func testTheDraggedTabFollowsThePointerRatherThanItsSlot() {
        let (ids, _) = oneRow()
        var d = drag(ids[0], from: 6, arrangement: [ids])

        d.update(
            pointer: CGPoint(x: 200, y: middleOfRow(0)),
            stripWidth: stripWidth
        )

        // Grabbed at its leading edge, so the tab's edge sits at the pointer and
        // its offset is the distance from where it started.
        XCTAssertEqual(
            d.offset(of: ids[0], stripWidth: stripWidth).width, 200 - 6
        )
    }

    // MARK: - The dead zone

    /// Entering the next band is not enough; the pointer has to reach its
    /// middle. Without this a few pixels of tremor at a boundary flips the tab
    /// between rows repeatedly.
    func testEnteringTheNextBandIsNotEnoughToChangeRows() {
        let ids = (0..<4).map { _ in UUID() }
        let widths = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGFloat(100)) })
        var d = drag(
            ids[0], from: 6,
            arrangement: [Array(ids[0..<2]), Array(ids[2..<4])]
        )

        // Just inside the second band, well short of its middle.
        d.update(
            pointer: CGPoint(x: 6, y: metrics.pitch + 1),
            stripWidth: stripWidth
        )

        XCTAssertEqual(
            d.position(of: ids[0])?.row, 0, "it has not earned the row yet"
        )
    }

    func testReachingTheMiddleOfTheNextBandChangesRows() {
        let ids = (0..<4).map { _ in UUID() }
        let widths = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGFloat(100)) })
        var d = drag(
            ids[0], from: 6,
            arrangement: [Array(ids[0..<2]), Array(ids[2..<4])]
        )

        d.update(
            pointer: CGPoint(x: 6, y: middleOfRow(1)),
            stripWidth: stripWidth
        )

        XCTAssertEqual(d.position(of: ids[0])?.row, 1)
    }

    // MARK: - The new-row affordance

    func testTheNewRowTargetShowsOnlyWhenARowWouldAppear() {
        let (ids, widths) = oneRow()
        var d = drag(ids[0], from: 6, arrangement: [ids])
        d.update(
            pointer: CGPoint(x: 6, y: metrics.pitch + metrics.newRowMargin / 2),
            stripWidth: stripWidth
        )
        // It has already made the row, so there is no further one to promise.
        XCTAssertFalse(d.isProposingNewRow())

        // A tab alone in the last row asking for a row below it would take its
        // own row with it and put an identical one back.
        var lone = drag(ids[4], from: 6, arrangement: [Array(ids[0..<4]), [ids[4]]])
        lone.update(
            pointer: CGPoint(
                x: 6, y: 2 * metrics.pitch + metrics.newRowMargin / 2
            ),
            stripWidth: stripWidth
        )
        XCTAssertFalse(lone.isProposingNewRow())
    }
}
