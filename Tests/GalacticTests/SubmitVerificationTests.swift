import AppKit
import XCTest
@testable import Galactic

/// Whether an automated prompt was actually taken.
///
/// The mechanism exists because readiness is not observable from this side of
/// the PTY: the keyboard protocol flag, bytes received, screen content under
/// three anchors, output silence, and the agent's own readiness hook were each
/// measured and each reported ready against a prompt that did not exist. The
/// only honest answer is the agent reporting receipt, which arrives late — so
/// these pin the two ways that lateness can be mishandled.
final class SubmitVerificationTests: XCTestCase {

    /// Drive acceptance on a clock the test controls rather than a real hook.
    private final class Agent {
        var accepted = false
        var alive = true

        var verification: SubmitVerification {
            SubmitVerification(
                isAccepted: { [unowned self] in self.accepted },
                isAlive: { [unowned self] in self.alive }
            )
        }
    }

    /// Let the poll run for a while in real time. The bound under test is
    /// `submitVerifyTimeout`; these waits are in poll intervals.
    private func settle(_ turns: Int) {
        for _ in 0..<turns {
            let done = expectation(description: "poll turn")
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SessionSubmit.submitVerifyPollInterval
            ) { done.fulfill() }
            wait(for: [done], timeout: 2)
        }
    }

    // MARK: - Opting out

    /// The supported opt-out is a nil value, not a skipped call — so a host
    /// that has no acceptance signal still has the mechanism wired.
    func testNilVerificationNeverRetypes() {
        let backend = StubBackend()
        backend.verifySubmission(text: "/resume ", verification: nil)
        settle(4)
        XCTAssertTrue(
            backend.written.isEmpty,
            "opting out must not type anything"
        )
    }

    // MARK: - The accepted case

    func testAnAcceptedPromptIsNeverRetyped() {
        let backend = StubBackend()
        let agent = Agent()
        agent.accepted = true

        backend.verifySubmission(
            text: "/resume ", verification: agent.verification
        )
        settle(4)
        XCTAssertTrue(
            backend.written.isEmpty,
            "a prompt the agent confirmed must not be sent twice"
        )
    }

    /// The regression that duplicated a prompt in the field. Confirmation
    /// arrived 35ms after a 250ms window expired, so the retry typed a second
    /// copy of a prompt that had already run. Acceptance that lands late but
    /// inside the bound must still count.
    func testLateAcceptanceInsideTheBoundStillCounts() {
        let backend = StubBackend()
        let agent = Agent()

        backend.verifySubmission(
            text: "/resume ", verification: agent.verification
        )
        settle(2)
        XCTAssertTrue(
            backend.written.isEmpty, "still waiting, so nothing retyped yet"
        )

        agent.accepted = true
        settle(3)
        XCTAssertTrue(
            backend.written.isEmpty,
            "confirmation after a delay is still confirmation"
        )
    }

    // MARK: - The lost case

    /// A prompt that is never confirmed gets the whole gesture again — text
    /// then submit — not a bare submit. Claude Code reads Enter-on-empty as
    /// "repeat the last command", so a retry that only re-submits would re-run
    /// whatever preceded it instead of rescuing what was lost.
    func testAnUnconfirmedPromptIsRetypedBeforeItIsResubmitted() {
        let backend = StubBackend()
        let agent = Agent()

        backend.verifySubmission(
            text: "/resume ", verification: agent.verification
        )

        let past = expectation(description: "past the bound")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SessionSubmit.submitVerifyTimeout + 0.3
        ) { past.fulfill() }
        wait(for: [past], timeout: SessionSubmit.submitVerifyTimeout + 2)

        XCTAssertEqual(
            backend.written, ["/resume "],
            "the retry must retype the prompt, not just press Enter again"
        )
    }

    /// A dead session is not something to keep typing into.
    func testADeadSessionStopsTheLoop() {
        let backend = StubBackend()
        let agent = Agent()
        agent.alive = false

        backend.verifySubmission(
            text: "/resume ", verification: agent.verification
        )
        settle(4)
        XCTAssertTrue(
            backend.written.isEmpty,
            "a session that has gone away must not be retried into"
        )
    }
}
