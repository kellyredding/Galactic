import AppKit

/// Recording that the user cut an agent's turn short.
///
/// Pressing Escape while an agent is mid-answer is the user changing their
/// mind, and it is worth knowing about afterwards — a turn that ended because
/// someone stopped it did not end the way a completed one did, and nothing
/// downstream can tell them apart from the transcript alone.
///
/// A struct of closures, matching the other host-supplied seams here: what a
/// turn *is*, and what recording one means, both belong to whatever is running
/// the agent. Shared code only knows which keystroke asks.
///
/// Optional at the holder, and nil is the whole opt-out — for a surface with no
/// notion of a turn, and equally for one that has turns but is not the surface
/// they happen on. A shell beside an agent is the second case, and it is why
/// this is nil in one place already rather than only in theory.
public struct TurnInterrupt {

    /// Whether a turn is running right now.
    ///
    /// Asked at the moment of the keystroke rather than tracked, because the
    /// answer changes without anything here being told.
    public let isInTurn: () -> Bool

    /// Record that this turn was interrupted.
    ///
    /// Called at most once per keystroke, but a user leaning on Escape produces
    /// a stream of them against a single turn, and nothing here can tell the
    /// second from the first. Whatever is asked to record has to be the thing
    /// that makes that harmless — it is the only side that knows what a
    /// duplicate would mean.
    public let record: () -> Void

    public init(
        isInTurn: @escaping () -> Bool,
        record: @escaping () -> Void
    ) {
        self.isInTurn = isInTurn
        self.record = record
    }

    /// Whether this keystroke is Escape with nothing held down.
    ///
    /// Bare, because every modifier combination on Escape means the user asked
    /// for something else — and the terminal, not this, is where those go.
    static func isBareEscape(_ event: NSEvent) -> Bool {
        event.keyCode == Keystroke.Key.esc
            && event.modifierFlags.intersection(
                [.control, .option, .command, .shift]
            ).isEmpty
    }
}

public extension Optional where Wrapped == TurnInterrupt {

    /// Record an interruption if this keystroke is one.
    ///
    /// Deliberately consumes nothing and reports nothing back. Escape has to
    /// keep travelling to the terminal, because aborting the stream is the
    /// agent's own business on the other end of the connection — this is
    /// bookkeeping alongside that, and a caller that treated a recorded
    /// interrupt as a handled keystroke would stop the abort it is recording.
    func recordIfInterrupting(_ event: NSEvent) {
        guard let self, TurnInterrupt.isBareEscape(event) else { return }
        guard self.isInTurn() else { return }
        self.record()
    }
}
