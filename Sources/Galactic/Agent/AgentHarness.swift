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
    /// pressing submit again. A resubmit only ever presses the submit key, so
    /// a window that proves too short costs a keystroke, never a second copy.
    var submitVerifyTimeout: TimeInterval { get }

    /// How often to check for that confirmation within the bound above.
    var submitVerifyPollInterval: TimeInterval { get }

    /// Maximum resubmits before an unconfirmed prompt is reported as such.
    var maxSubmitRetries: Int { get }

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
