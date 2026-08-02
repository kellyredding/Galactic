import Foundation

/// Whether the keystrokes a user configured are actually in force in the
/// harness.
///
/// Deliberately says nothing about *how* a harness is configured. Claude Code
/// keeps a JSON keybindings file; another harness might use a config flag, a
/// wire protocol, or nothing at all. The host only ever needs the answer, and
/// asking in terms of a file would make the next harness lie to fit.
public enum KeystrokeConfigurationState: Equatable {
    /// The harness agrees with the host's settings.
    case matching
    /// The harness is configured, and differently.
    case differs
    /// Nothing has configured the harness yet.
    case unconfigured
    /// This harness has no configurable keystrokes; the host should not offer
    /// to reconcile them.
    case unsupported
}

/// What a terminal-hosted agent must answer for a host to drive it
/// programmatically.
///
/// Everything a host needs in order to type at an agent and have the agent act
/// on it, with nothing about *which* agent. The one conformer today is Claude
/// Code, and the knowledge behind this protocol is genuinely Claude Code's —
/// a reserved key chord, an autocomplete popup, a TUI render loop with its own
/// timing. Naming that implementation for its vendor is honest. Naming the
/// capability for its vendor would not be, and would make a second harness a
/// rewrite rather than an addition.
///
/// Every value here is calibrated against a specific program's behaviour, so
/// each one is a question only a harness can answer. They are on the protocol
/// rather than in the submit seam because a constant measured against Claude
/// Code's render loop is not a fact about terminals — leaving them behind
/// would produce a seam that routes the submit bytes correctly and then
/// governs the send with another agent's timing.
public protocol AgentHarness {
    /// Bytes that commit whatever is currently typed.
    ///
    /// Not necessarily a carriage return, and not necessarily constant: for
    /// Claude Code it depends on what Return currently means in the session.
    var submitBytes: [UInt8] { get }

    /// How long to leave between writing text and committing it, so the
    /// harness processes them as separate events rather than one batch.
    var inputPacingDelay: TimeInterval { get }

    /// How long to wait for the harness to become able to read typed input
    /// before writing anyway.
    ///
    /// A program is not ready to be typed at the moment its process exists.
    /// Text written into that window is lost in silence — no echo, no error —
    /// so this bounds a wait rather than a retry.
    var inputReadinessTimeout: TimeInterval { get }

    /// How often to re-check readiness within that bound.
    var readinessPollInterval: TimeInterval { get }

    /// How long to wait for confirmation that a prompt was taken before
    /// treating it as lost.
    ///
    /// Must exceed however long this harness's acceptance signal takes to
    /// arrive. A window shorter than the signal it waits on reports every
    /// send as lost, and — where the caller retypes — duplicates prompts that
    /// worked.
    var submitVerifyTimeout: TimeInterval { get }

    /// How often to check for that confirmation within the bound above.
    var submitVerifyPollInterval: TimeInterval { get }

    /// Maximum resend attempts before a lost prompt is abandoned.
    var maxSubmitRetries: Int { get }

    /// Whether recovering a lost prompt requires retyping the whole gesture
    /// rather than resending the submit alone.
    ///
    /// True for Claude Code: by the time a retry fires the composer is
    /// usually empty, and Enter on an empty composer repeats the last
    /// command — so a bare resubmit would re-run whatever ran before it
    /// instead of rescuing what was lost. A harness that does nothing on an
    /// empty submit answers false and saves the second write.
    var retypeOnRetry: Bool { get }

    /// Commands this harness intercepts before its prompt pipeline runs, so
    /// no acceptance signal ever fires for them.
    ///
    /// A host whose acceptance signal comes from the harness's own hook must
    /// not wait on one for these. The failure this prevents is quiet and
    /// backwards: a host that compensates with optimism of its own would then
    /// be verifying a prompt against its own guess that the prompt landed.
    var acceptanceBypassingCommands: Set<String> { get }

    /// Adjust a command so any completion UI it opens is dismissed before it
    /// is committed.
    ///
    /// Returns the text unchanged when the harness has no such interference.
    func composedCommand(_ command: String) -> String

    /// Whether the host's configured keystrokes are in force.
    func keystrokeConfigurationState(
        for bindings: TextEntryBindings
    ) -> KeystrokeConfigurationState
}
