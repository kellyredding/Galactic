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

    /// Shipped timings unless a case says otherwise.
    private let harness = StubHarness()

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

    /// Run past a shortened verification bound and return the harness used.
    private func pastTheBound(
        _ configure: (StubHarness, StubBackend) -> Void
    ) -> StubBackend {
        let quick = StubHarness.quick()
        // A bare carriage return, so the resubmit inside a retry takes the
        // path that needs no keyboard protocol and the test is not timing
        // against a kitty wait it does not care about.
        quick.bytes = [0x0D]
        // One retry, so the count of writes is decided by the policy rather
        // than by how many shortened rounds happen to fit in the window. At
        // the shipped ceiling of two, a second retype lands within a
        // millisecond of the observation deadline and the assertion races.
        quick.retries = 1
        let backend = StubBackend()
        configure(quick, backend)

        let past = expectation(description: "past the bound")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + quick.verifyTimeout + 0.3
        ) { past.fulfill() }
        wait(for: [past], timeout: quick.verifyTimeout + 2)
        return backend
    }

    // MARK: - Opting out

    /// The supported opt-out is a nil value, not a skipped call — so a host
    /// that has no acceptance signal still has the mechanism wired.
    func testNilVerificationNeverRetypes() {
        let backend = StubBackend()
        backend.verifySubmission(
            text: "/resume ", harness: harness, verification: nil
        )
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
            text: "/resume ", harness: harness, verification: agent.verification
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
            text: "/resume ", harness: harness, verification: agent.verification
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
        let agent = Agent()
        let backend = pastTheBound { quick, backend in
            backend.verifySubmission(
                text: "/resume ", harness: quick,
                verification: agent.verification
            )
        }
        XCTAssertEqual(
            backend.written, ["/resume "],
            "the retry must retype the prompt, not just press Enter again"
        )
    }

    // MARK: - Detection is separate from retry

    /// The split this policy exists for. A caller that declines the retype is
    /// saying the payload is too large to risk a second copy of — not that it
    /// would rather not know the prompt vanished.
    func testReportOnlyNoticesTheLossWithoutRetyping() {
        let agent = Agent()
        let backend = pastTheBound { quick, backend in
            backend.verifySubmission(
                text: "a very large scrollback payload ",
                harness: quick,
                verification: agent.verification,
                retry: .reportOnly
            )
        }
        XCTAssertTrue(
            backend.written.isEmpty,
            "reportOnly must not put a second copy of the payload on the wire"
        )
        XCTAssertTrue(
            backend.bytesWritten.isEmpty,
            "and must not resubmit either — the whole gesture is declined"
        )
    }

    /// Guards the regression that would make the split pointless: retype is
    /// still the default, so an existing caller that says nothing about retry
    /// behaves exactly as it did before the policy existed.
    func testRetypeRemainsTheDefault() {
        let agent = Agent()
        let backend = pastTheBound { quick, backend in
            backend.verifySubmission(
                text: "/resume ", harness: quick,
                verification: agent.verification
            )
        }
        XCTAssertEqual(
            backend.written, ["/resume "],
            "omitting the policy must keep retyping, not silently stop"
        )
    }

    /// A nil verification outranks the policy. There is nothing to detect
    /// without a signal, so reportOnly has nothing to report.
    func testNilVerificationIsInertUnderEitherPolicy() {
        let backend = pastTheBound { quick, backend in
            backend.verifySubmission(
                text: "/resume ", harness: quick,
                verification: nil, retry: .reportOnly
            )
        }
        XCTAssertTrue(
            backend.written.isEmpty, "no signal means no work of any kind"
        )
    }

    /// The ceiling is the harness's answer, not a shared constant. Zero
    /// retries means the first loss is final.
    func testTheRetryCeilingComesFromTheHarness() {
        let agent = Agent()
        let backend = pastTheBound { quick, backend in
            quick.retries = 0
            backend.verifySubmission(
                text: "/resume ", harness: quick,
                verification: agent.verification
            )
        }
        XCTAssertTrue(
            backend.written.isEmpty,
            "a harness that allows no retries must not get one anyway"
        )
    }

    /// A dead session is not something to keep typing into.
    func testADeadSessionStopsTheLoop() {
        let backend = StubBackend()
        let agent = Agent()
        agent.alive = false

        backend.verifySubmission(
            text: "/resume ", harness: harness, verification: agent.verification
        )
        settle(4)
        XCTAssertTrue(
            backend.written.isEmpty,
            "a session that has gone away must not be retried into"
        )
    }
}
