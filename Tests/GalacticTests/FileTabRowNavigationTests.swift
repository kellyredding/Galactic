import XCTest

@testable import Galactic

/// Which tab is above or below the one selected.
final class FileTabRowNavigationTests: XCTestCase {

    private let spacing: CGFloat = 3
    private let leading: CGFloat = 6

    private func column(
        from column: Int, in current: [CGFloat], to target: [CGFloat]
    ) -> Int {
        FileTabRowNavigation.column(
            movingFrom: column, in: current, to: target,
            spacing: spacing, leading: leading
        )
    }

    /// **The reported problem.** The row below holds two wide tabs; keeping the
    /// column index would land on its second one, which sits far to the right of
    /// where the eye was. Under the third narrow tab is the *first* wide one.
    func testDroppingIntoARowOfWiderTabsLandsUnderTheEye() {
        let narrow: [CGFloat] = [60, 60, 60, 60]
        let wide: [CGFloat] = [400, 400]

        XCTAssertEqual(
            column(from: 2, in: narrow, to: wide), 0,
            "the column index would have said 2, which is not below anything"
        )
    }

    /// And the other way: from a wide tab into a row of narrow ones, the landing
    /// is whichever narrow tab is under the wide one's middle rather than its
    /// edge.
    func testDroppingIntoARowOfNarrowerTabsLandsUnderTheMiddle() {
        let wide: [CGFloat] = [400, 400]
        let narrow: [CGFloat] = [60, 60, 60, 60, 60, 60, 60]

        // The first wide tab spans 6...406, so its centre is 206. The narrow
        // tabs are 63 apart, so 206 falls in the fourth.
        XCTAssertEqual(column(from: 0, in: wide, to: narrow), 3)
    }

    /// The centre, not the leading edge — a wide tab's edge can sit under a
    /// different tab than its bulk does.
    func testTheCentreDecidesRatherThanTheLeadingEdge() {
        let current: [CGFloat] = [200]
        let target: [CGFloat] = [50, 50, 50, 50]

        // The target's tabs span 6–56, 59–109, 112–162, 165–215. The leading
        // edge, 6, is inside the first; the centre, 106, is inside the second.
        XCTAssertEqual(column(from: 0, in: current, to: target), 1)
    }

    /// Past the end of a shorter row, it clamps rather than refusing to move. A
    /// reader pressing down expects to arrive somewhere.
    func testPastTheEndOfAShorterRowClampsToItsLastTab() {
        let long: [CGFloat] = [60, 60, 60, 60, 60, 60]
        let short: [CGFloat] = [60, 60]

        XCTAssertEqual(column(from: 5, in: long, to: short), 1)
    }

    func testAnEmptyTargetRowAnswersZeroRatherThanTrapping() {
        XCTAssertEqual(column(from: 3, in: [60, 60, 60, 60], to: []), 0)
    }

    /// A column that is not in the row it claims to be from — a stale selection
    /// arriving with the geometry of a strip that has since changed.
    func testAColumnOutsideItsOwnRowIsClamped() {
        XCTAssertEqual(column(from: 9, in: [60, 60], to: [60, 60, 60]), 2)
    }
}
