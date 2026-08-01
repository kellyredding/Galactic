import Combine

/// A host-supplied signal that something able to block sending has changed.
///
/// A scrollback surface offers to send what the user selected to an agent, and
/// that offer is not always available — the agent may not be running, may have
/// exited, or may be busy behind a frozen surface of its own. Whether it is
/// available is re-read rather than carried, so all this has to say is *when* to
/// re-read.
///
/// The two applications watch different things for it: a session model's running
/// and exited flags in one, a controller's state in the other. Both are the same
/// question about the same agent, asked of whatever object happens to hold the
/// answer, which is exactly what a host is for.
///
/// ### What this deliberately does not cover
///
/// The cross-pane blocker — a shell offering to send into an agent whose own
/// scrollback is frozen open — is not here. Both applications already read that
/// from the pane registry, which shared code can reach on its own, so a host
/// passing it in would be routing around a seam that already exists.
///
/// No threading guarantee is asked for. Consumers re-read state and touch the
/// interface, so they hop to main themselves; requiring it here would mean two
/// hosts each adding a hop to satisfy a promise their subscriber does not need.
public typealias SendBlockerChanges = AnyPublisher<Void, Never>
