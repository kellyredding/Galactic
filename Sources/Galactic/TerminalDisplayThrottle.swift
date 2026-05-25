import Foundation
import Combine

/// Coordinates "pause terminal display invalidation"
/// signals during chrome animations (e.g. sidebar toggle) so
/// SwiftUI's animation transaction commit doesn't compete
/// with PTY-driven redraw work on the main thread.
///
/// Backend- and chrome-agnostic. The throttle exposes `pause`
/// and publishes `isPaused`. Chrome code (in the host app)
/// calls `pause(for:)` from animation-trigger sites; each
/// backend's implementation (`SwiftTermBackend`, future
/// `LibghosttyBackend`, etc.) subscribes to `$isPaused` from
/// its own init and translates the signal into whatever pause
/// mechanism its rendering layer supports — for SwiftTerm
/// that's a flag on `GalacticSwiftTermView` consulted inside
/// an override of `setNeedsDisplay(_:)`; for libghostty that
/// would be its native invalidation hook. Neither the
/// throttle nor the chrome cares which backend is below the
/// `TerminalBackend` adapter seam.
///
/// Diagnostic log identified the click-to-motion gap getting
/// noticeably worse when a Claude session was actively
/// streaming output. That symptom is main-thread contention
/// between the terminal's per-PTY-chunk `drawRect:` (CoreText
/// layout + glyph rendering) and SwiftUI's animation
/// transaction commit. Both run on main; SwiftUI's commit
/// waits for a free runloop pass; the terminal's
/// invalidations keep that runloop occupied. Pausing
/// invalidation for ~250ms starting at the toggle (slightly
/// longer than the `easeOut(0.15)` slide duration) lets the
/// commit land in its normal slot, and a single catch-up
/// redraw fires when the pause ends.
///
/// Output isn't *lost* — the underlying terminal buffer
/// keeps accumulating PTY data; only the display
/// invalidation is suppressed. When the pause ends, each
/// backend triggers a single catch-up redraw covering its
/// view's full bounds, and the buffer state renders in
/// one pass.
public final class TerminalDisplayThrottle {
    public static let shared = TerminalDisplayThrottle()

    /// Drives backend-side pause / unpause. Each backend's
    /// init subscribes to this and propagates to its own
    /// view (or rendering layer) however that backend
    /// expresses "stop invalidating now."
    @Published public private(set) var isPaused: Bool = false

    private var pauseTimer: DispatchWorkItem?

    private init() { }

    /// Pause display invalidation for `duration`, then
    /// auto-resume. A new pause cancels any prior pending
    /// resume so a rapid toggle sequence (collapse →
    /// expand → collapse in <250ms) doesn't end with
    /// invalidation re-enabled mid-transition.
    ///
    /// Called by chrome code from animation-trigger sites
    /// (e.g. `SidebarPreferences.isVisible` didSet). Safe to
    /// call concurrently with no-op semantics if already
    /// paused — the timer restarts at the new duration.
    public func pause(for duration: TimeInterval) {
        pauseTimer?.cancel()
        isPaused = true

        let work = DispatchWorkItem { [weak self] in
            self?.isPaused = false
        }
        pauseTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + duration, execute: work
        )
    }
}
