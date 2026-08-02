import XCTest

@testable import Galactic

/// What every agent harness must answer sanely, run against every conformer.
///
/// The protocol has one conformer anyone actually runs, which is the condition
/// under which a shared default quietly becomes one program's habit. These
/// cases exist to be run against both `ClaudeCodeHarness` and
/// `BareREPLHarness` — a Claude Code assumption that leaked into shared code
/// shows up as the bare harness answering something absurd, rather than as two
/// conformers agreeing because only one of them was ever considered.
final class AgentHarnessContractTests: XCTestCase {

    private var conformers: [(name: String, harness: AgentHarness)] {
        [
            ("ClaudeCodeHarness", ClaudeCodeHarness()),
            ("BareREPLHarness", BareREPLHarness()),
        ]
    }

    // MARK: - Submission

    /// A harness that submits nothing cannot be driven at all.
    func testEveryHarnessSubmitsSomething() {
        for (name, harness) in conformers {
            XCTAssertFalse(
                harness.submitBytes.isEmpty,
                "\(name) must name bytes that commit a prompt"
            )
        }
    }

    // MARK: - Composition

    /// Composition adjusts a command; it does not replace it. A harness that
    /// dropped or reordered the caller's text would send something the caller
    /// never asked for.
    func testCompositionPreservesTheCommand() {
        for (name, harness) in conformers {
            let composed = harness.composedCommand("/handoff")
            XCTAssertTrue(
                composed.hasPrefix("/handoff"),
                "\(name) must not alter the command it was given"
            )
        }
    }

    /// Empty in, nothing invented. Guards a composition that would turn a
    /// no-op into a stray keystroke.
    func testCompositionOfNothingAddsNoCommand() {
        for (name, harness) in conformers {
            XCTAssertTrue(
                harness.composedCommand("").trimmingCharacters(
                    in: .whitespaces
                ).isEmpty,
                "\(name) must not compose a command out of an empty string"
            )
        }
    }

    // MARK: - Bounds

    /// Every bound is a real wait somebody sits behind. A zero or negative
    /// one turns a bounded wait into no wait at all, silently.
    func testEveryBoundIsPositive() {
        for (name, harness) in conformers {
            XCTAssertGreaterThan(
                harness.inputReadinessTimeout, 0, "\(name) readiness timeout")
            XCTAssertGreaterThan(
                harness.readinessPollInterval, 0, "\(name) readiness poll")
            XCTAssertGreaterThan(
                harness.submitVerifyTimeout, 0, "\(name) verify timeout")
            XCTAssertGreaterThan(
                harness.submitVerifyPollInterval, 0, "\(name) verify poll")
            XCTAssertGreaterThanOrEqual(
                harness.maxSubmitRetries, 0, "\(name) retry ceiling")
        }
    }

    /// A poll slower than its own bound never fires inside it — the wait would
    /// resolve only by timing out, whatever actually happened.
    func testEveryPollFitsInsideItsBound() {
        for (name, harness) in conformers {
            XCTAssertLessThan(
                harness.readinessPollInterval, harness.inputReadinessTimeout,
                "\(name) would never re-check readiness before giving up"
            )
            XCTAssertLessThan(
                harness.submitVerifyPollInterval, harness.submitVerifyTimeout,
                "\(name) would never re-check acceptance before giving up"
            )
        }
    }

    // MARK: - Vendor-specific answers stay vendor-specific

    /// The two commands Claude Code intercepts before its prompt pipeline
    /// runs. A host that waits for an acceptance signal on these waits forever.
    func testClaudeCodeNamesItsHookBypassingCommands() {
        let harness = ClaudeCodeHarness()
        XCTAssertTrue(harness.acceptanceBypassingCommands.contains("/clear"))
        XCTAssertTrue(harness.acceptanceBypassingCommands.contains("/compact"))
    }

    /// Nothing about a bare REPL should have picked up Claude Code's shape.
    /// This is the case that catches a leaked default.
    func testABareREPLCarriesNoClaudeCodeAssumptions() {
        let harness = BareREPLHarness()
        XCTAssertEqual(
            harness.submitBytes, [0x0D],
            "a plain program submits on a carriage return"
        )
        XCTAssertEqual(
            harness.composedCommand("/handoff"), "/handoff",
            "no completion popup means nothing to compose around"
        )
        XCTAssertTrue(
            harness.acceptanceBypassingCommands.isEmpty,
            "no prompt pipeline means nothing to bypass it"
        )
        XCTAssertFalse(
            harness.retypeOnRetry,
            "an empty submit does nothing, so a bare resubmit is safe"
        )
        XCTAssertEqual(
            harness.keystrokeConfigurationState(for: .default),
            .unsupported,
            "a host must not offer to reconcile bindings that do not exist"
        )
    }

    /// The seam must honour a harness that declines retyping — otherwise the
    /// protocol member is decoration and the second write happens anyway.
    func testAHarnessThatDeclinesRetypingIsResubmittedNotRetyped() {
        let quick = StubHarness.quick()
        quick.bytes = [0x0D]
        quick.retype = false
        let backend = StubBackend()
        let agent = Agent()

        backend.verifySubmission(
            text: "print(1) ", harness: quick, verification: agent.verification
        )

        let past = expectation(description: "past the bound")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + quick.verifyTimeout + 0.3
        ) { past.fulfill() }
        wait(for: [past], timeout: quick.verifyTimeout + 2)

        XCTAssertTrue(
            backend.written.isEmpty,
            "retypeOnRetry false must skip the second write of the payload"
        )
        XCTAssertFalse(
            backend.bytesWritten.isEmpty,
            "but the submit itself must still be retried"
        )
    }

    /// Drive acceptance on a clock the test controls.
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
}
