import XCTest

@testable import Galactic

/// How tall the picker's list is allowed to be.
///
/// Arithmetic, so it is checkable: the panel used to stop at ten rows whatever
/// the window offered, which wasted most of a tall window and is the whole
/// reason this is a function rather than a constant.
final class FilePickerLayoutTests: XCTestCase {

    private typealias Metrics = FilePickerView.Metrics

    private func height(rows: Int, available: CGFloat) -> CGFloat {
        Metrics.listHeight(rows: rows, available: available)
    }

    /// A short list is as tall as its rows and no taller — the panel hugs its
    /// content rather than reserving a screen for three results.
    func testAShortListIsAsTallAsItsRows() {
        XCTAssertEqual(height(rows: 3, available: 2_000), 3 * Metrics.rowHeight)
    }

    /// And a long one grows into whatever the window has, rather than stopping
    /// at a fixed number of rows.
    func testALongListUsesTheRoomTheWindowOffers() {
        let tall = height(rows: 10_000, available: 2_000)
        let short = height(rows: 10_000, available: 600)

        XCTAssertGreaterThan(tall, short, "more window, more list")
        XCTAssertLessThan(tall, 2_000, "and never more than there is")
    }

    /// The cap leaves room for everything above the list, so the card cannot be
    /// asked for more height than the window has.
    func testTheListLeavesRoomForTheChromeAboveIt() {
        let available: CGFloat = 800

        let used = height(rows: 10_000, available: available)
            + Metrics.chromeHeight + Metrics.topInset

        XCTAssertLessThanOrEqual(used, available)
    }

    /// A window too short to hold the minimum still shows the minimum. A sliver
    /// of a list is worse than one that overflows a little: there is nothing to
    /// choose from in two rows.
    func testAVeryShortWindowStillShowsTheMinimumRows() {
        XCTAssertEqual(
            height(rows: 10_000, available: 40),
            CGFloat(Metrics.minimumRows) * Metrics.rowHeight
        )
    }

    /// Before the first layout pass there is no height to divide up, and
    /// dividing zero gives every list nothing — a panel of no rows for a frame.
    func testAnUnmeasuredAreaFallsBackToTheMinimum() {
        XCTAssertEqual(
            height(rows: 10_000, available: 0),
            CGFloat(Metrics.minimumRows) * Metrics.rowHeight
        )
    }

    /// An empty list still occupies one row, so the empty state has somewhere
    /// to be drawn.
    func testAnEmptyListIsStillOneRowTall() {
        XCTAssertEqual(height(rows: 0, available: 2_000), Metrics.rowHeight)
    }
}
