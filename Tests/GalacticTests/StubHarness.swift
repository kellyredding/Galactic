import Foundation

@testable import Galactic

/// An agent harness whose every answer a test can set.
///
/// Defaults match `ClaudeCodeHarness`, so a suite that says nothing about
/// timing is testing the shipped behaviour rather than an invented one. What
/// it buys is the ability to shorten a bound deliberately: the readiness gate
/// and the submit verifier are both bounded waits, and pinning their
/// give-up behaviour against the real five- and two-second timeouts made the
/// suite pay those seconds on every run.
///
/// Shared with `StubBackend` rather than nested, for the same reason that one
/// is shared — the readiness gate and the submit verifier are two halves of
/// one path, and two ideas of what a harness answers would drift.
final class StubHarness: AgentHarness {
    var bytes: [UInt8] = SessionSubmit.bytes
    var pacing: TimeInterval = SessionSubmit.inputPacingDelay
    var readinessTimeout: TimeInterval = SessionSubmit.kittyReadyTimeout
    var readinessPoll: TimeInterval = SessionSubmit.kittyPollInterval
    var verifyTimeout: TimeInterval = SessionSubmit.submitVerifyTimeout
    var verifyPoll: TimeInterval = SessionSubmit.submitVerifyPollInterval
    var retries: Int = SessionSubmit.maxSubmitRetries
    var retype: Bool = true
    var bypassing: Set<String> = ["/clear", "/compact"]
    var compose: (String) -> String = { $0 + " " }
    var configurationState: KeystrokeConfigurationState = .matching

    var submitBytes: [UInt8] { bytes }
    var inputPacingDelay: TimeInterval { pacing }
    var inputReadinessTimeout: TimeInterval { readinessTimeout }
    var readinessPollInterval: TimeInterval { readinessPoll }
    var submitVerifyTimeout: TimeInterval { verifyTimeout }
    var submitVerifyPollInterval: TimeInterval { verifyPoll }
    var maxSubmitRetries: Int { retries }
    var retypeOnRetry: Bool { retype }
    var acceptanceBypassingCommands: Set<String> { bypassing }

    func composedCommand(_ command: String) -> String { compose(command) }

    func keystrokeConfigurationState(
        for bindings: TextEntryBindings
    ) -> KeystrokeConfigurationState {
        configurationState
    }

    /// A harness with both bounded waits shortened, for the cases that exist
    /// to pin what happens when a wait gives up.
    static func quick() -> StubHarness {
        let harness = StubHarness()
        harness.readinessTimeout = 0.2
        harness.verifyTimeout = 0.2
        return harness
    }
}
