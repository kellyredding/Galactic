import Foundation

/// Where a scrollback surface sends composed text, and whether it may.
///
/// Supplied by the host rather than resolved here, because who receives the
/// text and what "ready" means are both properties of the session the surface
/// is attached to, not of the surface.
public struct SendToClaudeTarget {
    /// Hand composed text to the owning session, which types it
    /// and commits it.
    ///
    /// One closure rather than a write and a submit the caller
    /// paces itself. The session's own send path already owns that
    /// sequence — wait for the child to be able to read, type,
    /// pace, then submit whichever bytes the pane will act on —
    /// and a second implementation of it drifted: it paced with a
    /// number of its own for three months, and never gained the
    /// readiness wait at all. Nothing here resolves the submit
    /// bytes either, deliberately, because which ones work
    /// depends on what Return currently means in that pane.
    public let send: (String) -> Void

    /// Preflight: nil = enabled, Some(reason) = disabled
    /// with the given tooltip string.
    public let disabledReason: () -> String?

    public init(
        send: @escaping (String) -> Void,
        disabledReason: @escaping () -> String?
    ) {
        self.send = send
        self.disabledReason = disabledReason
    }
}
