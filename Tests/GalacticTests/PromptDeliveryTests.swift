import XCTest

@testable import Galactic

/// The whole automated-send gesture: compose, wait, write, pace, submit,
/// verify.
///
/// This existed three times in two applications and had never been tested
/// once, because it lived in application targets with no bench. Each copy lost
/// something different — a readiness wait, a trailing space, a paste-then-
/// submit that swallowed the submit, a verification call that was simply
/// absent. These pin the invariants each of those violated, so the next copy
/// cannot be written by hand at all.
final class PromptDeliveryTests: XCTestCase {

    private func harness() -> StubHarness {
        let h = StubHarness.quick()
        h.bytes = [0x0D]
        return h
    }

    /// Run the main queue for a while so the paced submit lands.
    private func settle(_ turns: Int = 6) {
        for _ in 0..<turns {
            let done = expectation(description: "turn")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }

    private func readyBackend() -> StubBackend {
        let backend = StubBackend()
        backend.kitty = true
        backend.output = true
        backend.drawn = true
        return backend
    }

    // MARK: - Ordering

    /// The wait guards the write, not the submit. A pane reporting ready means
    /// its process exists; text written before its input layer is up is lost
    /// in silence, and the trailing space is the first byte to go.
    func testNothingIsWrittenBeforeTheAgentCanRead() {
        let backend = StubBackend()  // never becomes ready
        backend.kitty = false

        backend.deliverPrompt(
            "/handoff", harness: harness(),
            isAlive: { true }, verification: nil
        )
        settle(2)

        XCTAssertTrue(
            backend.written.isEmpty,
            "text must not go out before the agent can read it"
        )
    }

    func testTextIsWrittenThenSubmitted() {
        let backend = readyBackend()

        backend.deliverPrompt(
            "/handoff", harness: harness(),
            isAlive: { true }, verification: nil
        )
        settle()

        XCTAssertEqual(backend.written.count, 1, "wrote the text once")
        XCTAssertEqual(
            backend.bytesWritten, [[0x0D]],
            "and committed it with the harness's submit bytes"
        )
    }

    // MARK: - It never pastes

    /// A bracketed paste is held as pending input and can swallow the submit
    /// that follows it. Anything that submits must type. There is no flag for
    /// this — the point is that the combination cannot be spelled — so this
    /// guards the one place it is decided.
    func testAnAutomatedSendIsTypedNeverPasted() {
        let backend = readyBackend()

        backend.deliverPrompt(
            "a\nmulti\nline\npayload", harness: harness(),
            isAlive: { true }, verification: nil
        )
        settle()

        XCTAssertEqual(
            backend.pasted, [false],
            "an automated send types, at any size"
        )
    }

    // MARK: - Composition

    func testTheCommandIsComposedByTheHarness() {
        let backend = readyBackend()
        let h = harness()
        h.compose = { $0 + "!" }

        backend.deliverPrompt(
            "/handoff", harness: h, isAlive: { true }, verification: nil
        )
        settle()

        XCTAssertEqual(backend.written, ["/handoff!"])
    }

    /// Composition happens once, inside. A caller that pre-composed and a seam
    /// that composes again would double the trailing space — harmless for one
    /// agent and not a property to rely on.
    func testCompositionIsNotAppliedTwice() {
        let backend = readyBackend()

        backend.deliverPrompt(
            "/handoff", harness: harness(),
            isAlive: { true }, verification: nil
        )
        settle()

        XCTAssertEqual(
            backend.written, ["/handoff "],
            "exactly one trailing space, applied by the seam"
        )
    }

    /// The retype must re-send what was actually written the first time. If
    /// composition sat at the call site and the retype used the raw command,
    /// a rescued prompt would arrive missing the byte that closes the popup.
    func testARetypeResendsTheComposedText() {
        let backend = readyBackend()
        let h = harness()
        h.retries = 1
        let agent = SubmitVerification(isAccepted: { false }, isAlive: { true })

        backend.deliverPrompt(
            "/handoff", harness: h, isAlive: { true }, verification: agent
        )

        let past = expectation(description: "past the bound")
        DispatchQueue.main.asyncAfter(deadline: .now() + h.verifyTimeout + 0.3) {
            past.fulfill()
        }
        wait(for: [past], timeout: 3)

        XCTAssertEqual(
            backend.written, ["/handoff ", "/handoff "],
            "the retype must match the original write byte for byte"
        )
    }

    // MARK: - Liveness and the completion hook

    /// A caller serializing sends releases its gate in `then`. Skipping it on
    /// an abandoned send would strand a queue behind a prompt never written.
    func testTheHookRunsWhenTheSessionDiesBeforeTheWrite() {
        let backend = readyBackend()
        var ran = false

        backend.deliverPrompt(
            "/handoff", harness: harness(),
            isAlive: { false }, verification: nil, then: { ran = true }
        )
        settle(2)

        XCTAssertTrue(ran, "an abandoned send must still free its caller")
        XCTAssertTrue(backend.written.isEmpty, "and must not write")
    }

    func testTheHookRunsWhenTheSessionDiesBetweenWriteAndSubmit() {
        let backend = readyBackend()
        var alive = true
        var ran = false

        backend.deliverPrompt(
            "/handoff", harness: harness(),
            isAlive: { alive }, verification: nil, then: { ran = true }
        )
        alive = false
        settle()

        XCTAssertTrue(ran, "the gap between write and submit is not an exit")
        XCTAssertTrue(
            backend.bytesWritten.isEmpty,
            "a dead session must not be submitted into"
        )
    }

    func testTheHookRunsOnceOnTheSuccessfulPath() {
        let backend = readyBackend()
        var runs = 0

        backend.deliverPrompt(
            "/handoff", harness: harness(),
            isAlive: { true }, verification: nil, then: { runs += 1 }
        )
        settle()

        XCTAssertEqual(runs, 1, "exactly once, or a queue drains twice")
    }
}
