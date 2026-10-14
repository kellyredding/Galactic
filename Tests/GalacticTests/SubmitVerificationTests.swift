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
        // One retry, so the count of presses is decided by the policy rather
        // than by how many shortened rounds happen to fit in the window. At
        // the shipped ceiling of two, a second press lands within a
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
    func testNilVerificationNeverPressesAnything() {
        let backend = StubBackend()
        backend.verifySubmission(
            harness: harness, verification: nil
        )
        settle(4)
        XCTAssertTrue(
            backend.written.isEmpty && backend.bytesWritten.isEmpty,
            "opting out must not type or press anything"
        )
    }

    // MARK: - The accepted case

    func testAnAcceptedPromptIsNeverResubmitted() {
        let backend = StubBackend()
        let agent = Agent()
        agent.accepted = true

        backend.verifySubmission(
            harness: harness, verification: agent.verification
        )
        settle(4)
        XCTAssertTrue(
            backend.bytesWritten.isEmpty,
            "a prompt the agent confirmed must not be submitted again"
        )
    }

    /// Confirmation that lands late but inside the bound must still count.
    func testLateAcceptanceInsideTheBoundStillCounts() {
        let backend = StubBackend()
        let agent = Agent()

        backend.verifySubmission(
            harness: harness, verification: agent.verification
        )
        settle(2)
        XCTAssertTrue(
            backend.bytesWritten.isEmpty, "still waiting, so nothing pressed yet"
        )

        agent.accepted = true
        settle(3)
        XCTAssertTrue(
            backend.bytesWritten.isEmpty,
            "confirmation after a delay is still confirmation"
        )
    }

    // MARK: - The lost case

    /// An unconfirmed prompt gets the submit key again and nothing else. If
    /// the text is still in the composer this sends it; if the prompt already
    /// went, the composer is empty and the keystroke does nothing — measured
    /// against Claude Code, idle and mid-turn. A retyped copy is what doubled
    /// prompts whose confirmation was only late.
    func testAnUnconfirmedPromptIsResubmittedNeverRetyped() {
        let agent = Agent()
        let backend = pastTheBound { quick, backend in
            backend.verifySubmission(
                harness: quick,
                verification: agent.verification
            )
        }
        XCTAssertTrue(
            backend.written.isEmpty, "a retry must never write the text again"
        )
        XCTAssertEqual(
            backend.bytesWritten, [[0x0D]],
            "a retry presses the harness's submit bytes, once per retry"
        )
    }

    // MARK: - Detection is separate from retry

    /// A caller that declines the resubmit still learns the bound passed.
    func testReportOnlyNoticesTheLossWithoutPressingAnything() {
        let agent = Agent()
        var reported: SubmitOutcome?
        let backend = pastTheBound { quick, backend in
            backend.verifySubmission(
                harness: quick,
                verification: agent.verification,
                retry: .reportOnly,
                outcome: { reported = $0 }
            )
        }
        XCTAssertTrue(
            backend.written.isEmpty && backend.bytesWritten.isEmpty,
            "reportOnly must neither type nor press"
        )
        XCTAssertEqual(reported, .unconfirmed)
    }

    /// A caller that says nothing about retry gets the resubmit.
    func testResubmitIsTheDefault() {
        let agent = Agent()
        let backend = pastTheBound { quick, backend in
            backend.verifySubmission(
                harness: quick,
                verification: agent.verification
            )
        }
        XCTAssertFalse(
            backend.bytesWritten.isEmpty,
            "omitting the policy must still recover a swallowed submit"
        )
    }

    /// A nil verification outranks the policy. There is nothing to detect
    /// without a signal, so reportOnly has nothing to report.
    func testNilVerificationIsInertUnderEitherPolicy() {
        let backend = pastTheBound { quick, backend in
            backend.verifySubmission(
                harness: quick,
                verification: nil, retry: .reportOnly
            )
        }
        XCTAssertTrue(
            backend.written.isEmpty && backend.bytesWritten.isEmpty,
            "no signal means no work of any kind"
        )
    }

    /// The ceiling is the harness's answer, not a shared constant. Zero
    /// retries means the first loss is final.
    func testTheRetryCeilingComesFromTheHarness() {
        let agent = Agent()
        let backend = pastTheBound { quick, backend in
            quick.retries = 0
            backend.verifySubmission(
                harness: quick,
                verification: agent.verification
            )
        }
        XCTAssertTrue(
            backend.bytesWritten.isEmpty,
            "a harness that allows no retries must not get one anyway"
        )
    }

    /// A dead session is not something to keep typing into.
    func testADeadSessionStopsTheLoop() {
        let backend = StubBackend()
        let agent = Agent()
        agent.alive = false

        backend.verifySubmission(
            harness: harness, verification: agent.verification
        )
        settle(4)
        XCTAssertTrue(
            backend.bytesWritten.isEmpty,
            "a session that has gone away must not be retried into"
        )
    }
}
