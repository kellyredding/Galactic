import Foundation

/// Where Galactic's diagnostics go, decided by the host.
///
/// Galactic runs inside apps that each already own a log file and a format.
/// Rather than pick one, or print to stdout and pollute every consumer that
/// forgot to configure it, the package emits through a sink that discards by
/// default. A host that wants these lines installs one at startup.
///
/// The lines that matter most here describe automated prompt submission —
/// which bytes went out, how long the terminal took to become ready, and
/// whether it ever did. That sequence fails silently by nature: no echo, no
/// error, just a prompt that never sends. The log is the only way to tell
/// "sent the wrong thing" from "sent the right thing too early".
public enum GalacticLog {
    /// Two channels rather than one level knob. Submission diagnostics are
    /// worth keeping on in a shipping build; everything else is not, and
    /// collapsing them would force that choice to be all or nothing.
    public struct Sink {
        /// Automated submission — the path that fails without symptoms.
        public var submit: (String) -> Void

        /// Everything else Galactic has to say, tagged by subject.
        ///
        /// The tag arrives separately rather than pre-formatted into the
        /// message because both hosts already have a house style for it, and
        /// the tag is what makes these lines greppable by subject once they
        /// are interleaved with everything else in a log file.
        public var debug: (_ tag: String, _ message: String) -> Void

        public init(
            submit: @escaping (String) -> Void = { _ in },
            debug: @escaping (_ tag: String, _ message: String) -> Void
                = { _, _ in }
        ) {
            self.submit = submit
            self.debug = debug
        }
    }

    /// Discards until a host replaces it.
    ///
    /// Written exactly once, at launch, before anything in this package can
    /// run, and read on the main thread thereafter — every call site is
    /// reached through work already dispatched to main, and nothing in the
    /// reach of a log line touches a background queue.
    ///
    /// `nonisolated(unsafe)` states that discipline rather than proving it,
    /// which is the honest position: the compiler cannot see an invariant this
    /// loose, and the alternatives buy nothing against the actual usage. A lock
    /// would be taken on every line — including inside the submission poll loop
    /// — to guard a value nothing writes twice. Main-actor isolation would be
    /// accurate, but it would force `await` onto call sites with no other
    /// reason to be async, which is the trade this package already declined
    /// once for the pane registry.
    ///
    /// Two things would make this wrong: a host assigning after launch, or a
    /// log line reached from a background queue. Neither happens today, and
    /// they are what to check first if it ever needs revisiting.
    nonisolated(unsafe) public static var sink = Sink()

    static func submit(_ message: String) { sink.submit(message) }

    static func debug(_ tag: String, _ message: String) {
        sink.debug(tag, message)
    }
}
