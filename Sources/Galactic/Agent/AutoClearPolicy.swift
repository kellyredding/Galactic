import Foundation

/// What to do about the agent's context, and what to remember for next time.
public struct AutoClearDecision: Equatable {
    /// Clear the agent's context now.
    public var clear: Bool
    /// The latch state the caller stores and hands back on the next decision.
    /// True means a crossing has not been acted on yet.
    public var armed: Bool

    public init(clear: Bool, armed: Bool) {
        self.clear = clear
        self.armed = armed
    }
}

/// Whether the agent's context has crossed the point where clearing it is the
/// right move — and, just as load-bearing, whether it has crossed back.
///
/// An agent that runs out of context does not fail loudly; it starts refusing,
/// and an unattended task gets swallowed while its run log still says the prompt
/// was sent. Clearing before that happens is the whole point, which is also why
/// the decision is a value and not a side effect: nothing here writes anything,
/// so the rule can be exercised without a session, a socket, or a hook.
///
/// ### Why a latch rather than a cooldown
///
/// A clear does not lower the reported percentage immediately — the reading
/// arrives from outside, a moment later, and until it does it still says the
/// context is full. Something has to stop the next evaluation firing a second
/// clear on the strength of the same stale number.
///
/// A timer answers that by waiting long enough that a fresh reading has
/// probably landed. A latch answers it with evidence instead: having fired,
/// refuse to fire again until a reading actually comes back under the line.
/// That needs no interval to tune, cannot be outrun by a slow reading, and says
/// out loud what an interval only implies — that one crossing earns one clear.
///
/// The difference is not academic where a reading is polled rather than handed
/// over with the turn that ended. A poll that has not refreshed yet leaves a
/// timer free to expire against the same stale number it already acted on; the
/// latch simply keeps refusing, because no evidence has arrived.
///
/// The re-arm applies whether or not the feature is switched on, which is not an
/// oversight. Being under the threshold while disabled is still the evidence a
/// later crossing is a new one, and without it, turning the feature on above the
/// line would sit inert waiting for a round trip nobody asked for.
///
/// ### Where the latch lives
///
/// With the caller, and at whatever grain a crossing belongs to: a host running
/// one agent keeps one, and a host running many keeps one per session, because
/// each session crosses its own line. Nothing here holds state.
public enum AutoClearPolicy {
    /// The thresholds a person may choose. Below 50 is a clear so eager it would
    /// fight ordinary work; 100 can never be crossed.
    public static let thresholdRange: ClosedRange<Int> = 50...99

    /// The default: on, and late.
    public static let defaultEnabled = true
    public static let defaultThreshold = 97

    /// Whether to clear, given the latest reading and the latch.
    ///
    /// `contextPercentage` is nil when nothing has reported one yet — a session
    /// too young to have been measured, or a reading that could not be fetched.
    /// Nil decides nothing and disturbs nothing: it is the absence of evidence,
    /// and the latch has to survive it or a single missed reading would re-arm a
    /// crossing that was already acted on.
    ///
    /// Strictly greater than, so a threshold of 97 is the last value that does
    /// not fire.
    public static func decide(
        contextPercentage: Double?,
        threshold: Int,
        enabled: Bool,
        armed: Bool
    ) -> AutoClearDecision {
        guard let percentage = contextPercentage else {
            return AutoClearDecision(clear: false, armed: armed)
        }
        if percentage <= Double(threshold) {
            return AutoClearDecision(clear: false, armed: true)
        }
        guard enabled, armed else {
            return AutoClearDecision(clear: false, armed: armed)
        }
        return AutoClearDecision(clear: true, armed: false)
    }
}
