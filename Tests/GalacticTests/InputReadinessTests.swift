import AppKit
import XCTest
@testable import Galactic

/// When a host may type at a child.
///
/// Answered wrongly three times, each time by a signal that looked like
/// readiness and was not. The keyboard protocol goes up early in startup and
/// is never taken back down. Received output is cleared per process, but a
/// child's first bytes are terminal setup, so it lands at the same instant.
/// Visible content arrives when an input layer does, but a restarted child
/// inherits a screen that already has the last one's output on it.
///
/// Each is wrong in a way the others are not, so the gate requires all three.
/// These pin every one of those failure modes.
final class InputReadinessTests: XCTestCase {

    /// Give the bounded poll room to run several intervals.
    private func settle(_ turns: Int = 6) {
        for _ in 0..<turns {
            let done = expectation(description: "poll turn")
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SessionSubmit.kittyPollInterval
            ) { done.fulfill() }
            wait(for: [done], timeout: 2)
        }
    }

    private func readiness(
        kitty: Bool, output: Bool, drawn: Bool
    ) -> (backend: StubBackend, answered: () -> Bool?) {
        let backend = StubBackend()
        backend.kitty = kitty
        backend.output = output
        backend.drawn = drawn
        var answer: Bool?
        backend.whenAcceptingInput { answer = $0 }
        return (backend, { answer })
    }

    // MARK: - All three are required

    func testReadyOnlyWhenALiveChildHasDrawnAndCanDecode() {
        let (_, answered) = readiness(kitty: true, output: true, drawn: true)
        settle(1)
        XCTAssertEqual(
            answered(), true,
            "a live child that has drawn and decodes is ready to be typed at"
        )
    }

    /// The protocol goes up early in a program's startup; a gate satisfied by
    /// that alone types into nothing.
    func testProtocolUpButNothingDrawnIsNotReady() {
        let (_, answered) = readiness(kitty: true, output: true, drawn: false)
        settle(2)
        XCTAssertNil(
            answered(),
            "a blank screen must not report ready just because the protocol is up"
        )
    }

    /// The failure that survived the previous fix. Received output is fresh,
    /// but a child's opening bytes are terminal setup — so this state is a
    /// started child that has not yet drawn, and typing at it loses the text.
    func testOutputReceivedButNothingDrawnIsNotReady() {
        let (_, answered) = readiness(kitty: true, output: true, drawn: false)
        settle(2)
        XCTAssertNil(
            answered(),
            "the child's first bytes are setup, not an input layer"
        )
    }

    /// The inherited screen. Content is on display, but it belongs to the
    /// child that just died — nothing has come from the one now starting.
    func testDrawnContentFromAPreviousLifecycleIsNotReady() {
        let (_, answered) = readiness(kitty: true, output: false, drawn: true)
        settle(2)
        XCTAssertNil(
            answered(),
            "a screen the new child inherited is not evidence the new child ran"
        )
    }

    /// Something is drawing, but a chord written now would be discarded rather
    /// than decoded.
    func testDrawnButProtocolDownIsNotReady() {
        let (_, answered) = readiness(kitty: false, output: true, drawn: true)
        settle(2)
        XCTAssertNil(
            answered(),
            "a drawn screen must not report ready while the chord is undecodable"
        )
    }

    // MARK: - It resolves once the child catches up

    /// The real sequence: flags and first bytes land together, and the paint
    /// follows a beat later. Only the last of those may open the gate.
    func testBecomesReadyWhenTheChildFinallyDraws() {
        let backend = StubBackend()
        backend.kitty = true
        backend.output = true
        var answer: Bool?
        backend.whenAcceptingInput { answer = $0 }
        settle(1)
        XCTAssertNil(answer, "started but still blank, so still waiting")

        backend.drawn = true
        settle(2)
        XCTAssertEqual(
            answer, true, "the wait should resolve on the next poll after paint"
        )
    }

    // MARK: - Failing open

    /// A wait that never resolved would strand every automated prompt behind a
    /// child that is merely slow. Reporting not-ready is the signal; writing
    /// anyway is the behaviour, because a late write beats no write.
    func testGivingUpReportsNotReadyRatherThanNeverAnswering() {
        let backend = StubBackend()
        var answer: Bool?
        backend.whenAcceptingInput { answer = $0 }

        let deadline = expectation(description: "past the timeout")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SessionSubmit.kittyReadyTimeout + 0.3
        ) { deadline.fulfill() }
        wait(for: [deadline], timeout: SessionSubmit.kittyReadyTimeout + 2)

        XCTAssertEqual(
            answer, false,
            "the gate must answer even when the child never becomes ready"
        )
    }
}
