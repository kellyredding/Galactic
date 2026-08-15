import Foundation
import XCTest

@testable import Galactic

/// One crossing earns one clear, and only evidence re-arms it.
final class AutoClearPolicyTests: XCTestCase {

    private func decide(
        _ percentage: Double?,
        threshold: Int = 90,
        enabled: Bool = true,
        armed: Bool = true
    ) -> AutoClearDecision {
        AutoClearPolicy.decide(
            contextPercentage: percentage,
            threshold: threshold,
            enabled: enabled,
            armed: armed)
    }

    // MARK: - The line itself

    func testOverTheLineClears() {
        XCTAssertEqual(decide(91), AutoClearDecision(clear: true, armed: false))
    }

    /// Strictly greater than, so the threshold is the last value that does not
    /// fire. A reader who picks 90 means "90 is still fine".
    func testAtTheLineDoesNotClear() {
        XCTAssertEqual(decide(90), AutoClearDecision(clear: false, armed: true))
    }

    func testUnderTheLineDoesNotClear() {
        XCTAssertEqual(decide(12), AutoClearDecision(clear: false, armed: true))
    }

    // MARK: - The latch

    /// The whole point: having fired, it refuses again on the same crossing.
    /// A clear does not lower the reported figure immediately, so the next
    /// evaluation sees the same number it already acted on.
    func testDisarmedRefusesWhileStillOverTheLine() {
        XCTAssertEqual(
            decide(99, armed: false),
            AutoClearDecision(clear: false, armed: false))
    }

    /// Evidence, not elapsed time — a reading back under the line is what
    /// re-arms, and nothing else does.
    func testAReadingUnderTheLineReArms() {
        XCTAssertEqual(
            decide(40, armed: false),
            AutoClearDecision(clear: false, armed: true))
    }

    /// Fire, refuse, re-arm, fire again — the full cycle a session lives.
    func testCrossingTwiceEarnsTwoClears() {
        var armed = true

        let first = decide(95, armed: armed)
        XCTAssertTrue(first.clear)
        armed = first.armed

        let held = decide(95, armed: armed)
        XCTAssertFalse(held.clear, "the same crossing must not fire twice")
        armed = held.armed

        let reArmed = decide(20, armed: armed)
        XCTAssertFalse(reArmed.clear)
        XCTAssertTrue(reArmed.armed)
        armed = reArmed.armed

        XCTAssertTrue(decide(95, armed: armed).clear)
    }

    // MARK: - Absent readings

    /// Nil is the absence of evidence, not evidence of being under the line.
    /// A single missed reading must not re-arm a crossing already acted on, or
    /// a fetch that failed would earn a second clear.
    func testNilLeavesTheLatchAlone() {
        XCTAssertEqual(
            decide(nil, armed: false),
            AutoClearDecision(clear: false, armed: false))
        XCTAssertEqual(
            decide(nil, armed: true),
            AutoClearDecision(clear: false, armed: true))
    }

    // MARK: - Disabled

    func testDisabledNeverClears() {
        XCTAssertFalse(decide(99, enabled: false).clear)
    }

    /// Re-arming while switched off is deliberate. Being under the line is
    /// still the evidence that a later crossing is a new one — without it,
    /// switching the feature on above the line would sit inert waiting for a
    /// round trip nobody asked for.
    func testDisabledStillReArms() {
        XCTAssertEqual(
            decide(40, enabled: false, armed: false),
            AutoClearDecision(clear: false, armed: true))
    }

    /// Switched on while already over the line and still armed: it fires,
    /// rather than waiting for a crossing it already missed.
    func testEnablingAboveTheLineFiresImmediately() {
        XCTAssertTrue(decide(99, enabled: true, armed: true).clear)
    }

    // MARK: - The dial

    func testThresholdRangeRefusesTheUnusableEnds() {
        XCTAssertEqual(AutoClearPolicy.thresholdRange.lowerBound, 50)
        XCTAssertEqual(AutoClearPolicy.thresholdRange.upperBound, 99)
        XCTAssertTrue(
            AutoClearPolicy.thresholdRange.contains(
                AutoClearPolicy.defaultThreshold),
            "the default has to be a value the dial can express")
    }

    /// 100 can never be crossed, which is why the dial stops short of it.
    func testTheUpperBoundIsStillCrossable() {
        XCTAssertTrue(
            decide(
                100,
                threshold: AutoClearPolicy.thresholdRange.upperBound
            ).clear)
    }
}
