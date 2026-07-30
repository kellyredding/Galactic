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
/// **Not yet consumed.** The submit seam and the keybindings writer still reach
/// their Claude Code implementations directly. This exists now so the contract
/// is written down while the knowledge behind it is fresh, and so the vendor
/// code has one place to live. Routing the seam through it is a refactor, and
/// bundling a refactor with a large move would make any failure ambiguous.
public protocol AgentHarness {
    /// Bytes that commit whatever is currently typed.
    ///
    /// Not necessarily a carriage return, and not necessarily constant: for
    /// Claude Code it depends on what Return currently means in the session.
    var submitBytes: [UInt8] { get }

    /// How long to leave between writing text and committing it, so the
    /// harness processes them as separate events rather than one batch.
    var inputPacingDelay: TimeInterval { get }

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
