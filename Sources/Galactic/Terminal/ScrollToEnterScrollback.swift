import AppKit

/// Whether scrolling up on a live terminal opens its scrollback surface, and
/// the cooldown that keeps the rest of that gesture from re-opening it.
///
/// ### Why the cooldown exists
///
/// A trackpad keeps delivering scroll events after the fingers have left, so
/// the gesture that dismisses a surface is usually still moving when the
/// surface goes away. Ungated, that momentum lands on the live terminal
/// underneath and opens the surface straight back up, which reads as a dismiss
/// that did not take.
///
/// The gate clears on whichever comes first: the end of the gesture, or a
/// timeout. Both are needed. A trackpad reports the end and a long glide should
/// not be cut short by a clock; a discrete wheel reports no phases at all, so
/// for it the clock is the only signal there will ever be.
///
/// ### Why configuration decides, and not the caller
///
/// Both the entry rule and the cooldown read the same flag, so a caller that
/// gated one and not the other would arm a cooldown no scroll can ever be
/// stopped by, or worse, leave the entry rule live in an app that opted out.
/// Reading it in both places here makes opting out a single value, which is
/// what lets an app keep the mechanism without the behaviour.
public final class ScrollToEnterScrollback {

    /// How long the cooldown holds when no end-of-gesture arrives to clear it.
    ///
    /// Long enough to outlast the momentum that follows a flick, short enough
    /// that a deliberate scroll a moment later still opens the surface.
    private let window: TimeInterval

    /// Whether scroll-up is currently being ignored.
    private(set) var isCoolingDown = false

    /// Fires if the gesture never reports an end — the wheel case.
    private var timeout: DispatchWorkItem?

    /// Watches for the end of the gesture — the trackpad case.
    private var monitor: Any?

    public init(window: TimeInterval = 0.3) {
        self.window = window
    }

    deinit {
        endCooldown()
    }

    /// Whether a scroll-up should open the scrollback surface now.
    ///
    /// `hasContent` keeps this stricter than a menu command deliberately. Asking
    /// for scrollback explicitly on an empty buffer is a reasonable thing to
    /// want — there is still a screen to annotate — but an ordinary scroll
    /// gesture on a terminal with nothing above the fold is not a request for
    /// anything, and honouring it puts a surface in front of the user every
    /// time they brush the trackpad.
    public func shouldEnter(
        configuration: GalacticConfiguration,
        isSurfaceOpen: Bool,
        hasContent: Bool
    ) -> Bool {
        guard configuration.scrollToEnterScrollback else { return false }
        guard !isSurfaceOpen, !isCoolingDown, hasContent else { return false }
        return true
    }

    /// Begin ignoring scroll-up, until the gesture ends or the window elapses.
    ///
    /// Ends any cooldown already running rather than layering a second one on
    /// top: the timers are cheap, but each cooldown installs an event monitor
    /// that sees every scroll in the application, and one left behind by a
    /// re-arm would keep seeing them for the life of the process.
    public func beginCooldown(configuration: GalacticConfiguration) {
        guard configuration.scrollToEnterScrollback else { return }

        endCooldown()
        isCoolingDown = true

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] event in
            if Self.gestureHasEnded(
                momentumPhase: event.momentumPhase, phase: event.phase
            ) {
                self?.endCooldown()
            }
            return event
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.endCooldown()
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + window, execute: timeout
        )
    }

    /// Stop ignoring scroll-up and release both ways of being told to.
    ///
    /// Safe to call when no cooldown is running, which is what lets teardown
    /// call it without first asking whether there is anything to tear down.
    func endCooldown() {
        isCoolingDown = false
        timeout?.cancel()
        timeout = nil
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Whether this scroll event is the end of the gesture that produced it.
    ///
    /// A trackpad flick ends twice over: the fingers lift, and some time later
    /// the momentum runs out. Only the second is the end of the *gesture*, so a
    /// momentum phase of ended is the signal — and the phase is consulted only
    /// when there is no momentum at all, which is a drag that stopped without
    /// throwing.
    static func gestureHasEnded(
        momentumPhase: NSEvent.Phase,
        phase: NSEvent.Phase
    ) -> Bool {
        momentumPhase == .ended || (momentumPhase == [] && phase == .ended)
    }
}
