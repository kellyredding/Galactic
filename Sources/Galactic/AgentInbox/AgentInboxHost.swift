import Foundation

/// The two things only an application can answer about its own agent.
///
/// Everything else about the inbox is mechanism and lives here in Galactic.
/// What a host supplies is knowledge it alone has: whether its agent can read
/// a prompt at this instant, and how to put one in front of it.
///
/// Both are deliberately narrow. Nothing here asks a host what a message is,
/// what order things go in, or whether two of them may be joined — a host that
/// answered those would be a second implementation of the queue.
///
/// Not actor-isolated, matching the queue and both hosts. See `AgentInbox`.
public protocol AgentInboxHost: AnyObject {

    /// Whether the agent can read a prompt *right now*.
    ///
    /// Broader than "not mid-turn", on purpose. A host with its own post-reset
    /// sequences in flight answers false until they finish, which is what keeps
    /// a drain from racing them — and it does so without this file knowing such
    /// sequences exist.
    ///
    /// A false answer is always safe: the consumer wakes often, and the next
    /// wake costs nothing. A wrong true answer is the expensive one, because it
    /// spends a message on a prompt nobody can read.
    ///
    /// ### What this rests on
    ///
    /// The whole design assumes a turn ending means the agent is reachable —
    /// no form can be on screen, because a form belongs to a turn that has not
    /// finished. That assumption was tested by a message landing inside an open
    /// question form and it survived: the agent had genuinely not ended its
    /// turn. What had happened is that the host was reading a *different*
    /// session's turn end as its own.
    ///
    /// So the sharp edge is not "is turn-end safe" but "is this turn mine". A
    /// host whose hooks are installed where other agent sessions can run — a
    /// shared working directory, a tool that spawns its own short-lived
    /// sessions — will be told about turns it does not own, and every one of
    /// them looks exactly like its own. Filter those out at the source, before
    /// they reach turn state; nothing downstream can tell them apart.
    var canSendNow: Bool { get }

    /// Deliver one unit and report whether the agent took it.
    ///
    /// `accepted` reports what the host observed, not what it hopes: false
    /// means no acceptance was reported inside the host's own window, which is
    /// not the same as the message being lost. The queue treats it as a failed
    /// attempt and counts it, and the attempt ceiling is what keeps that
    /// ambiguity from turning into repeated delivery.
    ///
    /// Call `accepted` exactly once. A host that never calls it leaves the
    /// consumer holding the queue.
    func deliver(
        _ unit: AgentInboxUnit,
        accepted: @escaping (Bool) -> Void
    )
}
