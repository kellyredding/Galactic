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
            widths: widths, stripWidth: stripWidth
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
            widths: widths, stripWidth: stripWidth
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
            widths: widths, stripWidth: stripWidth
        )
        XCTAssertEqual(d.proposal[1], [ids[2]], "precondition: it made the row")

        // Now back up into the first row, at its left-hand end.
        d.update(
            pointer: CGPoint(x: 6, y: middleOfRow(0)),
            widths: widths, stripWidth: stripWidth
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
            widths: widths, stripWidth: stripWidth
        )

        // Up into the top row, at its far left.
        d.update(
            pointer: CGPoint(x: 6, y: middleOfRow(0)),
            widths: widths, stripWidth: stripWidth
        )

        XCTAssertEqual(
            d.proposal[0].first, ids[5],
            "arriving at the left of the row means the left of the row"
        )
        XCTAssertEqual(d.proposal[1].count, 2)
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
            widths: widths, stripWidth: stripWidth
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
            widths: widths, stripWidth: stripWidth
        )

        XCTAssertEqual(d.position(of: ids[0])?.row, 1)
    }

    // MARK: - The new-row affordance

    func testTheNewRowTargetShowsOnlyWhenARowWouldAppear() {
        let (ids, widths) = oneRow()
        var d = drag(ids[0], from: 6, arrangement: [ids])
        d.update(
            pointer: CGPoint(x: 6, y: metrics.pitch + metrics.newRowMargin / 2),
            widths: widths, stripWidth: stripWidth
        )
        // It has already made the row, so there is no further one to promise.
        XCTAssertFalse(d.isProposingNewRow(widths: widths))

        // A tab alone in the last row asking for a row below it would take its
        // own row with it and put an identical one back.
        var lone = drag(ids[4], from: 6, arrangement: [Array(ids[0..<4]), [ids[4]]])
        lone.update(
            pointer: CGPoint(
                x: 6, y: 2 * metrics.pitch + metrics.newRowMargin / 2
            ),
            widths: widths, stripWidth: stripWidth
        )
        XCTAssertFalse(lone.isProposingNewRow(widths: widths))
    }
}
