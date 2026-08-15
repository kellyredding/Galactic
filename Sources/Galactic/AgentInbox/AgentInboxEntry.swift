import Foundation

/// One message waiting to reach a terminal-hosted agent.
///
/// The body is already composed, and the surface that composed it is already
/// gone — which is the whole reason a queue is here rather than a retry. A
/// scrollback comment exists only as the `value` of a textarea inside a web
/// view, and every composing surface reads that text, tears itself down, and
/// only then sends. There is nothing left to reopen and nothing to re-read, so
/// the one faithful thing to retain is the string; retaining a string you must
/// still deliver is a queue, and this is its unit.
///
/// Nothing about *how* the string gets delivered lives here beyond the two
/// facts a producer alone knows: whether it may travel with its neighbours, and
/// what a lost submit is worth. Everything else a send needs is either the
/// harness's to answer or this queue's to track, and asking a producer for it
/// would mean asking every future producer to remember it too.
public struct AgentInboxEntry: Identifiable, Equatable {

    /// Whether this may be joined with adjacent entries into one submit.
    ///
    /// Slash commands never may — the agent reads one command per prompt, so a
    /// second one riding along behind a separator is read as argument text and
    /// silently does nothing.
    public enum Delivery: Equatable {
        case coalescable
        case standalone
    }

    public enum State: Equatable {
        case ready

        /// Held in place by the reader. Skipped entirely, and deliberately not
        /// a barrier: pausing one message means "let everything else go past
        /// me", which is the only reading under which pausing the head of a
        /// queue is not the same gesture as pausing the queue.
        case paused

        /// Attempted to the ceiling without an acceptance report, and left
        /// alone.
        ///
        /// Not a barrier either, and for a sharper reason than pausing: the
        /// failure that produces this state is a missed *report*, not a proven
        /// loss, so the agent may well be holding the message already. Sending
        /// again would duplicate it, and holding everything behind it would
        /// strand a queue on a message that probably arrived.
        case stalled
    }

    public let id: UUID

    public var body: String

    /// What produced this, for the reader. Never sent to the agent.
    public var sourceLabel: String

    public var delivery: Delivery

    /// Whether a submit found missing is worth retyping.
    ///
    /// The producer's call, because it is a fact about the payload rather than
    /// about the agent: a bounded one costs little to repeat, and an unbounded
    /// one repeated becomes a second copy of a message that may have landed
    /// with only its submit lost — which nothing downstream can tell apart from
    /// a total loss.
    public var retry: SubmitRetryPolicy

    public var state: State

    public var attempts: Int

    public var enqueuedAt: Date

    public init(
        id: UUID = UUID(),
        body: String,
        sourceLabel: String,
        delivery: Delivery,
        retry: SubmitRetryPolicy,
        state: State = .ready,
        attempts: Int = 0,
        enqueuedAt: Date = Date()
    ) {
        self.id = id
        self.body = body
        self.sourceLabel = sourceLabel
        self.delivery = delivery
        self.retry = retry
        self.state = state
        self.attempts = attempts
        self.enqueuedAt = enqueuedAt
    }
}
