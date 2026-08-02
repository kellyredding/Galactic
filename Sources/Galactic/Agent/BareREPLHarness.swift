import Foundation

/// A terminal program with no completion UI, no configurable keystrokes, and
/// no way to report that it took a prompt.
///
/// The degenerate case, and the reason it exists is to hold the protocol
/// honest. `ClaudeCodeHarness` is the only conformer anyone runs, so every
/// member of `AgentHarness` risks being shaped around one program's habits
/// without anyone noticing — a default that reads as neutral because there is
/// nothing to contradict it. This answers differently on every axis the
/// protocol names, so an assumption that leaked into shared code shows up as
/// a wrong answer here rather than as a silent agreement.
///
/// Deliberately not a second vendor. Modelling a program nobody has measured
/// would put guesses in the codebase wearing the same clothes as the measured
/// values next to them. What a bare REPL does is knowable without measuring
/// anything: a carriage return submits, and nothing else is true of it.
public struct BareREPLHarness: AgentHarness {
    public init() {}

    /// A carriage return, always. No keybinding file to consult and no
    /// reserved chord to fall back to.
    public var submitBytes: [UInt8] { [0x0D] }

    /// No render loop to lose a batched keystroke to.
    public var inputPacingDelay: TimeInterval { 0 }

    /// A shell prompt is readable as soon as it has drawn; there is no
    /// startup sequence to wait out.
    public var inputReadinessTimeout: TimeInterval { 1.0 }

    public var readinessPollInterval: TimeInterval { 0.05 }

    /// Nothing will ever report acceptance, so a host that verifies against
    /// this harness would wait out the full bound on every send. Kept short
    /// for that reason: the honest configuration is for the host to supply no
    /// verification at all, and this bounds the cost of getting that wrong.
    public var submitVerifyTimeout: TimeInterval { 0.5 }

    public var submitVerifyPollInterval: TimeInterval { 0.05 }

    /// Nothing to verify against means nothing to retry from.
    public var maxSubmitRetries: Int { 0 }

    /// A bare submit against an empty line does nothing, so resending the
    /// submit alone is safe and there is no reason to write the payload
    /// twice.
    public var retypeOnRetry: Bool { false }

    /// No prompt pipeline to intercept.
    public var acceptanceBypassingCommands: Set<String> { [] }

    /// Nothing to compose around: no popup, no autocomplete, no token under a
    /// cursor to terminate.
    public func composedCommand(_ command: String) -> String { command }

    /// No keystroke configuration exists, so a host must not offer to
    /// reconcile one. This is the case `.unsupported` was added for.
    public func keystrokeConfigurationState(
        for bindings: TextEntryBindings
    ) -> KeystrokeConfigurationState {
        .unsupported
    }
}
