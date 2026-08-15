import Foundation

/// What the queue hands a consumer that asks for work: one submit's worth of
/// message, and the entries it will retire if the agent takes it.
///
/// Deliberately not an entry, and deliberately not a list of them. A consumer
/// that received entries would have to decide how they combine, which is the
/// one decision this whole file exists to keep in one place.
public struct AgentInboxUnit: Equatable {
    /// The entries this unit consumed, in the order they were joined. Held so
    /// the queue can retire exactly these on acceptance, rather than assuming
    /// its own head is still what it handed out.
    public let entryIDs: [UUID]

    /// The text to submit, separators already applied.
    public let body: String

    public let retry: SubmitRetryPolicy

    public init(entryIDs: [UUID], body: String, retry: SubmitRetryPolicy) {
        self.entryIDs = entryIDs
        self.body = body
        self.retry = retry
    }
}

/// Which entries make up the next submit.
///
/// A value rather than a method on the queue, because this is the rule the
/// whole inbox turns on and it is the one part that can be exercised with no
/// PTY, no socket, and no live agent. Everything hard about the bug this
/// mechanism fixes — a form nobody can see swallowing a message — is timing;
/// everything decidable about it is here, where timing does not exist.
///
/// Nothing in here holds state, and nothing in here delivers anything.
public enum AgentInboxSelection {

    /// A Markdown horizontal rule.
    ///
    /// Both surfaces that compose these messages already speak Markdown, and so
    /// does the agent reading them, so a coalesced submit arrives as separate
    /// sections rather than as two paragraphs that appear to be one thought.
    public static let separator = "\n\n---\n\n"

    /// The next unit, in queue order, or nil when nothing is sendable.
    ///
    /// Order is intent — a reader who dragged a row expects that to matter — so
    /// this never reorders. It takes the head and, when the head may travel
    /// with others, everything contiguous with it up to the first entry that
    /// may not.
    ///
    /// "Contiguous" is measured over the sendable entries alone, which is what
    /// makes a paused or stalled row a passenger rather than a wall: neither is
    /// evidence that the messages around it must stay apart, and treating them
    /// as barriers would let one held row hold up everything behind it.
    public static func nextUnit(
        from entries: [AgentInboxEntry]
    ) -> AgentInboxUnit? {
        let sendable = entries.filter { $0.state == .ready }
        guard let head = sendable.first else { return nil }

        guard head.delivery == .coalescable else {
            return AgentInboxUnit(
                entryIDs: [head.id],
                body: head.body,
                retry: head.retry)
        }

        let run = sendable.prefix { $0.delivery == .coalescable }
        return AgentInboxUnit(
            entryIDs: run.map(\.id),
            body: run.map(\.body).joined(separator: separator),
            retry: resolvedRetry(across: run))
    }

    /// The most conservative policy in a run wins.
    ///
    /// In practice a run is always prose and always agrees; the rule exists so
    /// that a disagreement has an answer rather than a discovery. It resolves
    /// toward `.reportOnly` because the two failures are not symmetric — one
    /// costs a message that may only be late, the other sends the agent a
    /// second copy of something it may already be holding.
    private static func resolvedRetry(
        across run: ArraySlice<AgentInboxEntry>
    ) -> SubmitRetryPolicy {
        run.contains { $0.retry == .reportOnly } ? .reportOnly : .retype
    }
}
