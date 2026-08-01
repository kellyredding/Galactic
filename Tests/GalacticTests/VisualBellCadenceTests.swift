import XCTest
@testable import Galactic

/// The rhythm of a persistent attention flash.
///
/// Two things are worth pinning. The sequence itself, because a cue that ends
/// lit leaves a row permanently tinted. And `totalDuration`, because a bell gate
/// is sized to it — the arrangement this replaced computed that length by hand
/// in another file and documented it 100ms wrong, which is exactly the drift a
/// derived value prevents.
final class VisualBellCadenceTests: XCTestCase {

    /// Fast enough to keep the suite quick, with the same shape as the real one.
    private let quick = VisualBellCadence(
        flashCount: 3, flashDuration: 0.03, gapDuration: 0.01
    )

    private func collect(
        _ cadence: VisualBellCadence
    ) -> [Bool] {
        var states: [Bool] = []
        cadence.run { states.append($0) }

        let done = expectation(description: "cadence finished")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + cadence.totalDuration + 0.1
        ) { done.fulfill() }
        wait(for: [done], timeout: cadence.totalDuration + 2)

        return states
    }

    // MARK: - The sequence

    func testItFlashesOnceForEachFlashInTheCadence() {
        let states = collect(quick)

        XCTAssertEqual(
            states, [true, false, true, false, true, false],
            "three flashes are three on/off pairs, in order"
        )
    }

    /// A cue that ended lit would leave whatever renders it permanently tinted.
    func testItEndsDark() {
        let states = collect(quick)

        XCTAssertEqual(states.last, false, "the sequence must settle dark")
    }

    func testASingleFlashCadenceIsOnePair() {
        let states = collect(
            VisualBellCadence(
                flashCount: 1, flashDuration: 0.03, gapDuration: 0.01
            )
        )

        XCTAssertEqual(states, [true, false])
    }

    // MARK: - The duration a gate is sized to

    /// Gaps go *between* flashes, so three flashes have two gaps and not three.
    /// An off-by-one here shows up as a bell gate that reopens while the flash
    /// is still running.
    func testTotalDurationCountsGapsBetweenFlashesOnly() {
        let cadence = VisualBellCadence(
            flashCount: 3, flashDuration: 0.375, gapDuration: 0.1
        )

        XCTAssertEqual(
            cadence.totalDuration, (0.375 * 3) + (0.1 * 2), accuracy: 0.0001
        )
    }

    func testTheStandardCadenceIsThreeFlashes() {
        XCTAssertEqual(VisualBellCadence.standard.flashCount, 3)
        XCTAssertEqual(
            VisualBellCadence.standard.totalDuration, 1.325, accuracy: 0.0001,
            "the figure a bell gate is sized to — the value it replaced was documented as 1.225"
        )
    }

    func testASingleFlashHasNoGap() {
        let cadence = VisualBellCadence(
            flashCount: 1, flashDuration: 0.375, gapDuration: 0.1
        )

        XCTAssertEqual(cadence.totalDuration, 0.375, accuracy: 0.0001)
    }

    func testAnEmptyCadenceHasNoDuration() {
        let cadence = VisualBellCadence(
            flashCount: 0, flashDuration: 0.375, gapDuration: 0.1
        )

        XCTAssertEqual(
            cadence.totalDuration, 0,
            "no flashes is zero length, not a negative gap"
        )
    }
}
