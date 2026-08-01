import XCTest
@testable import Galactic

/// Where the divider goes while a drag is in flight.
///
/// The behaviour worth pinning is not "the ratio changes" but *what it is
/// computed from*: every update measures from the ratio captured at drag start,
/// never from the running preview. Measuring from the preview compounds, so
/// each tick's delta lands on the previous frame's adjustment and the divider
/// accelerates away from the cursor. That bug is invisible in a single-tick
/// test and obvious in a two-tick one, which is why the repeat cases below
/// exist.
final class PaneSplitRatioTests: XCTestCase {

    private let height: CGFloat = 1000
    private let bounds = PaneSplitBounds(minRatio: 0.2, maxRatio: 0.8)
    private var minRatio: CGFloat { bounds.minRatio }
    private var maxRatio: CGFloat { bounds.maxRatio }

    private func drag(
        _ split: inout PaneSplitRatio, by delta: CGFloat
    ) {
        split.updateDrag(
            cursorDeltaY: delta, totalHeight: height, bounds: bounds
        )
    }

    // MARK: - Computing from drag start

    func testDraggingUpShrinksTheTopPane() {
        var split = PaneSplitRatio(ratio: 0.5)
        split.beginDrag()

        drag(&split, by: 100)

        XCTAssertEqual(
            split.previewRatio, 0.4,
            "a positive delta is the cursor moving up, which takes height "
                + "from the top pane"
        )
    }

    func testDraggingDownGrowsTheTopPane() {
        var split = PaneSplitRatio(ratio: 0.5)
        split.beginDrag()

        drag(&split, by: -100)

        XCTAssertEqual(split.previewRatio, 0.6)
    }

    /// The compound-update bug, in the form it actually reaches the user: the
    /// cursor is held still after a move and the same delta arrives again.
    func testTheSameDeltaTwiceDoesNotMoveTheDividerTwice() {
        var split = PaneSplitRatio(ratio: 0.5)
        split.beginDrag()

        drag(&split, by: 100)
        drag(&split, by: 100)

        XCTAssertEqual(
            split.previewRatio, 0.4,
            "the second tick must land on the drag-start ratio, not on the "
                + "first tick's result"
        )
    }

    /// The same defect from the other direction — returning to the start should
    /// return the divider to the start.
    func testReturningToTheStartDeltaReturnsToTheStartRatio() {
        var split = PaneSplitRatio(ratio: 0.5)
        split.beginDrag()

        drag(&split, by: 250)
        drag(&split, by: 0)

        XCTAssertEqual(split.previewRatio, 0.5)
    }

    // MARK: - Clamping

    func testThePreviewParksAtTheCeiling() {
        var split = PaneSplitRatio(ratio: 0.5)
        split.beginDrag()

        drag(&split, by: -900)

        XCTAssertEqual(
            split.previewRatio, maxRatio,
            "past the threshold the preview parks rather than continuing"
        )
    }

    func testThePreviewParksAtTheFloor() {
        var split = PaneSplitRatio(ratio: 0.5)
        split.beginDrag()

        drag(&split, by: 900)

        XCTAssertEqual(split.previewRatio, minRatio)
    }

    func testTheCommittedRatioIsClampedForLayout() {
        // A ratio from configuration, or from a run with wider bounds.
        let split = PaneSplitRatio(ratio: 0.95)

        XCTAssertEqual(
            split.clamped(to: bounds), maxRatio,
            "a stored ratio must not lay out a pane smaller than a drag would "
                + "allow"
        )
    }

    // MARK: - Commit

    func testCommittingAppliesThePreviewAndClearsIt() {
        var split = PaneSplitRatio(ratio: 0.5)
        split.beginDrag()
        drag(&split, by: 100)

        split.commitDrag()

        XCTAssertEqual(split.ratio, 0.4)
        XCTAssertNil(split.previewRatio, "the ghost line has nothing to draw")
    }

    /// A click on the divider that never becomes a drag.
    func testCommittingWithoutMovingLeavesTheRatioAlone() {
        var split = PaneSplitRatio(ratio: 0.5)
        split.beginDrag()

        split.commitDrag()

        XCTAssertEqual(split.ratio, 0.5)
        XCTAssertNil(split.previewRatio)
    }

    /// Two drags in a row: the second must measure from where the first left
    /// the divider, which is what `beginDrag` re-capturing is for.
    func testASecondDragMeasuresFromTheCommittedRatio() {
        var split = PaneSplitRatio(ratio: 0.5)
        split.beginDrag()
        drag(&split, by: 100)
        split.commitDrag()

        split.beginDrag()
        drag(&split, by: 100)

        XCTAssertEqual(split.previewRatio, 0.3)
    }

    // MARK: - Nothing to compute against

    func testUpdatingBeforeABeginIsIgnored() {
        var split = PaneSplitRatio(ratio: 0.5)

        drag(&split, by: 100)

        XCTAssertNil(
            split.previewRatio,
            "without a captured start there is no ratio to measure from"
        )
    }

    func testAZeroHeightIsIgnored() {
        var split = PaneSplitRatio(ratio: 0.5)
        split.beginDrag()

        split.updateDrag(
            cursorDeltaY: 100, totalHeight: 0, bounds: bounds
        )

        XCTAssertNil(split.previewRatio)
    }

    /// The complement is computed, so its bounds carry the usual binary
    /// floating-point residue — `1.0 - 0.70` is not exactly `0.30`. Every
    /// consumer multiplies these by a pixel height, so the residue is far below
    /// anything observable; asserting exact bit equality would be testing the
    /// representation rather than the behaviour.
    private let tolerance: CGFloat = 1e-9

    private func assertRange(
        _ actual: ClosedRange<Double>,
        isNear expected: ClosedRange<Double>,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.lowerBound, expected.lowerBound,
            accuracy: 1e-9, line: line
        )
        XCTAssertEqual(
            actual.upperBound, expected.upperBound,
            accuracy: 1e-9, line: line
        )
    }

    // MARK: - The bounds themselves

    func testTheStandardWindowIsThirtyToSeventy() {
        XCTAssertEqual(PaneSplitBounds.standard.minRatio, 0.30)
        XCTAssertEqual(PaneSplitBounds.standard.maxRatio, 0.70)
    }

    /// The derivation that stops the two windows drifting: the bottom pane's
    /// window is the top pane's complement, not a second stated pair.
    func testTheBottomWindowIsTheComplementOfTheTop() {
        let asymmetric = PaneSplitBounds(minRatio: 0.25, maxRatio: 0.80)

        assertRange(asymmetric.bottomRange, isNear: 0.20...0.75)
    }

    /// Why the derivation is easy to get wrong: at the standard window the two
    /// are the same numbers, so a stated pair looks correct until the window
    /// stops being symmetric.
    func testTheStandardWindowLooksSymmetricWhichIsTheTrap() {
        assertRange(
            PaneSplitBounds.standard.bottomRange, isNear: 0.30...0.70
        )
    }

    func testInvertedBoundsAreOrderedRatherThanTrusted() {
        let inverted = PaneSplitBounds(minRatio: 0.80, maxRatio: 0.20)

        XCTAssertEqual(inverted.minRatio, 0.20)
        XCTAssertEqual(
            inverted.maxRatio, 0.80,
            "clamping with a minimum above its maximum pins every ratio to the "
                + "maximum, so the divider stops moving and nothing says why"
        )
    }

    // MARK: - Configured bottom share to top ratio

    func testAConfiguredBottomShareBecomesItsTopComplement() {
        let top = PaneSplitRatio.topRatio(
            forBottomRatio: 0.40, within: .standard
        )

        XCTAssertEqual(top, 0.60)
    }

    func testAConfiguredShareOutsideTheWindowIsClamped() {
        let top = PaneSplitRatio.topRatio(
            forBottomRatio: 0.95, within: .standard
        )

        XCTAssertEqual(
            top, 0.30, accuracy: tolerance,
            "a stored value from a build with a wider window cannot ask for a "
                + "layout the drag would refuse"
        )
    }

    func testTheClampUsesTheBottomWindowNotTheTopOne() {
        // Asymmetric on purpose: clamping 0.78 against the *top* window
        // (0.25...0.80) would allow it and give 0.22, which is outside the
        // bottom window entirely.
        let bounds = PaneSplitBounds(minRatio: 0.25, maxRatio: 0.80)

        let top = PaneSplitRatio.topRatio(
            forBottomRatio: 0.78, within: bounds
        )

        XCTAssertEqual(
            top, 0.25, accuracy: tolerance,
            "0.78 clamps to the bottom window's 0.75"
        )
    }
}
