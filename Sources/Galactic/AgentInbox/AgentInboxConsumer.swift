import Foundation

/// Drains an inbox into a live agent session.
///
/// Bound to a session rather than to an application, and that is the whole
/// safety argument: **its existence is the gate.** A session with no agent has
/// no consumer, so nothing can drain into a terminal that is not there. That is
/// structural, where a check at each call site is something a future call site
/// can forget.
///
/// The division of labour is worth stating plainly, because it is what keeps
/// the timing bug from coming back. The host wakes this liberally — on every
/// signal that anything might have changed — and this gates strictly, asking
/// the host once, at the moment of use, whether a prompt can be read. Waking
/// too often costs a comparison. Waking too rarely strands the queue until
/// something unrelated happens to knock it loose.
///
/// Not actor-isolated, matching the queue and both hosts. See `AgentInbox`.
public final class AgentInboxConsumer {

    /// How many attempts an entry gets before it is left alone.
    ///
    /// Three, because the failure being counted is a missing acceptance report
    /// rather than a proven loss — so every attempt past the first risks
    /// handing the agent a message it already has. Small enough that a genuine
    /// hiccup is absorbed, small enough that a broken signal is visible fast.
    public static let attemptCeiling = 3

    private let inbox: AgentInbox

    /// Weak, so that a session tearing down takes its consumer's reach with it.
    /// The host owns this object; a strong reference back would mean neither
    /// ever went away, and a consumer outliving its terminal is the one thing
    /// the binding is here to prevent.
    private weak var host: AgentInboxHost?

    /// True from the moment a unit is handed to the host until the host reports
    /// on it. Not a lock — it is the record that someone else is already
    /// holding the head of the queue, which is what stops two wakes in the same
    /// frame delivering the same message twice.
    private var inFlight = false

    public init(inbox: AgentInbox, host: AgentInboxHost) {
        self.inbox = inbox
        self.host = host
    }

    /// Whether a unit is out with the host right now.
    public var isDelivering: Bool { inFlight }

    /// Whether a message the reader picked could go out this instant.
    ///
    /// Both halves of the answer live here and nowhere else: the host knows
    /// whether the agent can read a prompt, and this object knows whether the
    /// drain is already holding one. A control consulting either alone would be
    /// wrong exactly when it mattered.
    public var canSendNow: Bool {
        !inFlight && host?.canSendNow == true
    }

    /// What became of a send the reader asked for by hand.
    ///
    /// `refused` and `unconfirmed` are kept apart because the honest thing to
    /// say about them differs: nothing at all was written in the first case, so
    /// trying again shortly is free, while in the second the message may be
    /// sitting in the agent right now with only its report lost — the same
    /// ambiguity the attempt ceiling exists for. Collapsing the two would
    /// invite a reader to re-send something already delivered.
    public enum ManualSendOutcome: Equatable {
        case delivered
        case refused
        case unconfirmed
    }

    /// Deliver one entry now, because the reader asked for it.
    ///
    /// Three things this deliberately does not do. It does not count the
    /// attempt — the ceiling bounds the *consumer* talking itself into another
    /// try, and a person who can see the result is not that loop. It does not
    /// change the entry's state, so a stalled row stays stalled and a paused
    /// one stays paused unless the send actually lands. And it does not force
    /// past `inFlight` or `canSendNow`: writing while a blocker stands is the
    /// regression that once put three copies of one comment into a question
    /// form, and a button is not a good enough reason to re-earn it.
    public func sendNow(
        id: UUID,
        outcome: @escaping (ManualSendOutcome) -> Void
    ) {
        guard !inFlight,
            let host,
            host.canSendNow,
            let unit = AgentInboxSelection.unit(for: id, in: inbox.entries)
        else {
            outcome(.refused)
            return
        }

        inFlight = true

        // Same double-report guard as the drain path, for the same reason.
        var settled = false

        host.deliver(unit) { [weak self] accepted in
            guard let self, !settled else { return }
            settled = true

            self.inFlight = false

            guard accepted else {
                outcome(.unconfirmed)
                return
            }

            self.inbox.complete(unit)
            outcome(.delivered)

            // The agent just confirmed it took a prompt, so the surface is
            // known to be one that accepts them — let the ordinary drain carry
            // on from here rather than waiting for an unrelated signal.
            self.wake()
        }
    }

    /// Try to make progress.
    ///
    /// Safe to call often and from anywhere. Every guard here is a reason not
    /// to send, and they are checked in cost order: something already in
    /// flight, a host that has gone away, a host that says not now, and finally
    /// nothing to send.
    public func wake() {
        guard !inFlight,
            let host,
            host.canSendNow,
            let unit = inbox.nextUnit()
        else { return }

        inFlight = true

        // Guards against a host that reports twice. A second report would
        // otherwise retire entries that the first report already replaced —
        // and since this callback is where delivery is decided, a duplicate
        // here is a duplicate message, which is the exact failure the attempt
        // ceiling exists to bound.
        var settled = false

        host.deliver(unit) { [weak self] accepted in
            guard let self, !settled else { return }
            settled = true

            self.inFlight = false

            guard accepted else {
                self.inbox.recordAttemptFailure(
                    unit, ceiling: Self.attemptCeiling)

                // Try again, bounded by the ceiling above.
                //
                // ### Why this retries, having once been changed not to
                //
                // The failure this answers is a *transient* blocker. An
                // aborted turn is the case that proves it: the agent stops
                // being readable for as long as it takes to unwind the
                // stream, and a write inside that window is swallowed whole —
                // measured, 125 bytes and a submit chord reaching the agent's
                // transcript as nothing. Seconds later the same write lands.
                // Refusing to retry leaves that message sitting beside an idle
                // agent until the reader happens to start another turn.
                //
                // ### Why it is safe now, having once not been
                //
                // An earlier version retried and put three copies of one
                // comment into an open question form. The blocker there was
                // not transient — the form stood for minutes — and the reason
                // the queue kept writing into it was that the host's turn flag
                // had been corrupted by turn-end events belonging to a
                // different session. With that corruption fixed at its source,
                // a form on screen means the turn has not ended, which means
                // `canSendNow` is false, which means no attempt is made at
                // all. A persistent blocker now refuses the send rather than
                // absorbing it.
                //
                // ### Why there is no interval here
                //
                // There is no delay in this file and does not need to be. A
                // failure is only reported once the harness's verification
                // bound has expired, so consecutive attempts are already
                // spaced by that bound — a number this codebase owns and
                // calibrates, rather than one invented for the occasion.
                self.wake()
                return
            }

            self.inbox.complete(unit)

            // Only a success continues the drain, and it can: the agent just
            // confirmed it took a prompt, so the surface is known to be one
            // that accepts them. Several standalone commands empty the queue
            // one per confirmation rather than waiting for an unrelated signal
            // to move each one.
            self.wake()
        }
    }
}
