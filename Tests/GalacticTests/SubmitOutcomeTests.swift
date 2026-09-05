import AppKit
import XCTest

@testable import Galactic

/// What a send reports back to a caller that has to decide something.
///
/// The verdict was always computed; it just went to the log and stopped there,
/// which is fine for a human reading afterwards and useless to a queue holding
/// the message. These pin that every terminal path reports, and reports once —
/// a path that stays silent leaves a caller waiting on an answer that is never
/// coming, which looks exactly like a verification still in progress.
final class SubmitOutcomeTests: XCTestCase {

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

    private let harness = StubHarness()

    /// A harness and backend for the whole-gesture cases: both bounded waits
    /// shortened, and a backend that reports ready, so the test spends its time
    /// on the outcome rather than on a five-second readiness timeout.
    private func quickGesture() -> (StubHarness, StubBackend) {
        let quick = StubHarness.quick()
        quick.bytes = [0x0D]
        let backend = StubBackend()
        backend.kitty = true
        backend.output = true
        backend.drawn = true
        return (quick, backend)
    }

    private func settle(_ turns: Int) {
        for _ in 0..<turns {
            let done = expectation(description: "poll turn")
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SessionSubmit.submitVerifyPollInterval
            ) { done.fulfill() }
            wait(for: [done], timeout: 2)
        }
    }

    /// Run past a shortened verification bound, collecting every report.
    private func pastTheBound(
        _ configure: (StubHarness, StubBackend) -> Void
    ) -> StubBackend {
        let quick = StubHarness.quick()
        quick.bytes = [0x0D]
        quick.retries = 1
        let backend = StubBackend()
        configure(quick, backend)

        let past = expectation(description: "past the bound")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + quick.verifyTimeout + 0.4
        ) { past.fulfill() }
        wait(for: [past], timeout: quick.verifyTimeout + 2)
        return backend
    }

    // MARK: - Accepted

    func testAConfirmedPromptReportsAccepted() {
        let backend = StubBackend()
        let agent = Agent()
        agent.accepted = true
        var reported: [SubmitOutcome] = []

        backend.verifySubmission(
            text: "/resume ", harness: harness,
            verification: agent.verification,
            outcome: { reported.append($0) })
        settle(2)

        XCTAssertEqual(reported, [.accepted])
    }

    /// Confirmation that lands late but inside the bound is still confirmation,
    /// and must report as such rather than as a miss.
    func testLateAcceptanceInsideTheBoundReportsAccepted() {
        let backend = StubBackend()
        let agent = Agent()
        var reported: [SubmitOutcome] = []

        backend.verifySubmission(
            text: "/resume ", harness: harness,
            verification: agent.verification,
            outcome: { reported.append($0) })
        settle(2)
        XCTAssertTrue(reported.isEmpty, "still waiting, so nothing reported")

        agent.accepted = true
        settle(3)

        XCTAssertEqual(reported, [.accepted])
    }

    // MARK: - Unverifiable

    /// Nothing failed here. The caller said in advance that no report can
    /// arrive — a context-reset command being the standing case — so this is
    /// the answer that lets a queue retire the entry instead of retrying a send
    /// that can never be confirmed.
    func testNilVerificationReportsUnverifiable() {
        let backend = StubBackend()
        var reported: [SubmitOutcome] = []

        backend.verifySubmission(
            text: "/clear ", harness: harness, verification: nil,
            outcome: { reported.append($0) })

        XCTAssertEqual(reported, [.unverifiable])
        XCTAssertTrue(
            backend.written.isEmpty, "opting out still types nothing")
    }

    // MARK: - Unconfirmed

    /// `.reportOnly` stops at the bound, so its report is the whole story.
    func testAReportOnlySendPastTheBoundReportsUnconfirmed() {
        let agent = Agent()
        var reported: [SubmitOutcome] = []

        _ = pastTheBound { quick, backend in
            backend.verifySubmission(
                text: "a long comment", harness: quick,
                verification: agent.verification,
                retry: .reportOnly,
                outcome: { reported.append($0) })
        }

        XCTAssertEqual(reported, [.unconfirmed])
    }

    /// `.retype` reports only once its retries are spent — the caller wants the
    /// verdict on the send, not on each attempt inside it.
    func testARetypedSendReportsOnceRetriesAreExhausted() {
        let agent = Agent()
        var reported: [SubmitOutcome] = []

        _ = pastTheBound { quick, backend in
            backend.verifySubmission(
                text: "/resume ", harness: quick,
                verification: agent.verification,
                retry: .retype,
                outcome: { reported.append($0) })
        }

        XCTAssertEqual(
            reported, [.unconfirmed],
            "one report for the send, not one per retry")
    }

    /// A retry that succeeds reports accepted, not unconfirmed — the interim
    /// miss that triggered the retype is not the outcome.
    func testARetryThatSucceedsReportsAccepted() {
        let agent = Agent()
        var reported: [SubmitOutcome] = []

        _ = pastTheBound { quick, backend in
            backend.verifySubmission(
                text: "/resume ", harness: quick,
                verification: agent.verification,
                retry: .retype,
                outcome: { reported.append($0) })
            DispatchQueue.main.asyncAfter(
                deadline: .now() + quick.verifyTimeout + 0.05
            ) { agent.accepted = true }
        }

        XCTAssertEqual(reported, [.accepted])
    }

    // MARK: - Abandoned

    /// A session that dies mid-verification reports rather than going quiet.
    /// Silence is indistinguishable from a verification still running, and a
    /// caller holding the message would wait forever on it.
    func testASessionThatDiesMidVerificationReportsAbandoned() {
        let agent = Agent()
        var reported: [SubmitOutcome] = []

        _ = pastTheBound { quick, backend in
            backend.verifySubmission(
                text: "/resume ", harness: quick,
                verification: agent.verification,
                outcome: { reported.append($0) })
            DispatchQueue.main.asyncAfter(
                deadline: .now() + quick.verifyTimeout / 2
            ) { agent.alive = false }
        }

        XCTAssertEqual(reported, [.abandoned])
    }

    // MARK: - The whole gesture

    /// Through `deliverPrompt` rather than `verifySubmission` directly, since
    /// that is the seam a host actually calls.
    func testDeliverPromptReportsTheOutcomeOfTheWholeGesture() {
        let (quick, backend) = quickGesture()
        let agent = Agent()
        agent.accepted = true
        var reported: [SubmitOutcome] = []
        var gestureFinished = false

        backend.deliverPrompt(
            "hello", harness: quick,
            isAlive: { true },
            verification: agent.verification,
            then: { gestureFinished = true },
            outcome: { reported.append($0) })
        settle(6)

        XCTAssertTrue(gestureFinished, "`then` still fires as it always did")
        XCTAssertEqual(reported, [.accepted])
    }

    /// A session gone before the write reports abandoned, and still releases
    /// whatever gate `then` holds.
    func testAGestureThatNeverWritesReportsAbandoned() {
        let (quick, backend) = quickGesture()
        var reported: [SubmitOutcome] = []
        var gestureFinished = false

        backend.deliverPrompt(
            "hello", harness: quick,
            isAlive: { false },
            verification: nil,
            then: { gestureFinished = true },
            outcome: { reported.append($0) })
        settle(6)

        XCTAssertTrue(gestureFinished)
        XCTAssertEqual(reported, [.abandoned])
        XCTAssertTrue(backend.written.isEmpty)
    }

    // MARK: - Waiting for the write

    /// **The regression these exist for.** The submit used to be scheduled a
    /// fixed 100ms after the write was *handed over*, which for a payload past
    /// a pty's ~1022 bytes is well before it has landed: the part that had
    /// arrived was submitted, and the remainder turned up afterwards as a
    /// fragment of its own, submitted separately as though it were an
    /// instruction. Nothing here could have caught that, because nothing
    /// distinguished handing bytes over from their arriving.
    func testTheSubmitWaitsForTheWriteToLand() {
        let (quick, backend) = quickGesture()
        let agent = Agent()
        agent.accepted = true
        backend.holdsWriteCompletion = true

        backend.deliverPrompt(
            "hello", harness: quick,
            isAlive: { true },
            verification: agent.verification,
            outcome: { _ in })
        settle(6)

        XCTAssertEqual(
            backend.written, ["hello "],
            "the text goes out first, with the harness's trailing space")
        XCTAssertTrue(
            backend.bytesWritten.isEmpty,
            "no submit while the write is still in flight")

        backend.completeHeldWrite()
        settle(6)

        XCTAssertEqual(
            backend.bytesWritten, [[0x0D]],
            "the submit follows once the bytes have landed")
    }

    /// A write that did not all get there must not be submitted. A fragment
    /// reads as a whole instruction, which is worse than a prompt that never
    /// went — and only a whole prompt can be retried.
    func testAPartialWriteIsNotSubmitted() {
        let (quick, backend) = quickGesture()
        backend.writeSucceeds = false
        var reported: [SubmitOutcome] = []
        var gestureFinished = false

        backend.deliverPrompt(
            "hello", harness: quick,
            isAlive: { true },
            verification: nil,
            then: { gestureFinished = true },
            outcome: { reported.append($0) })
        settle(6)

        XCTAssertEqual(backend.written, ["hello "])
        XCTAssertTrue(
            backend.bytesWritten.isEmpty,
            "a partial write is never followed by a Return")
        XCTAssertEqual(reported, [.abandoned])
        XCTAssertTrue(
            gestureFinished, "the gate still releases, or a queue strands")
    }
}
