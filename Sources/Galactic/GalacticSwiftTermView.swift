import AppKit
import SwiftTerm

/// Custom terminal view that extends LocalProcessTerminalView.
/// Intercepts terminal events (bell, scroll) without replacing
/// `terminalDelegate`, which would break SwiftTerm's internal
/// behavior. Process-lifecycle delegation is handled by the
/// owning `SwiftTermBackend` (which conforms to
/// `LocalProcessTerminalViewDelegate` and assigns itself as
/// `processDelegate` after constructing this view).
class GalacticSwiftTermView: LocalProcessTerminalView {
    /// Disable custom block glyph rendering on construction so
    /// block elements (U+2580–U+259F) and box drawing
    /// (U+2500–U+257F) fall through to CoreText font rendering,
    /// matching Terminal.app. Baked into init so callers don't
    /// have to remember to set it.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.customBlockGlyphs = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.customBlockGlyphs = false
    }

    /// Backend-agnostic flag honored by the
    /// `setNeedsDisplay(_:)` override below. The owning
    /// backend (`SwiftTermBackend`) flips this in response
    /// to `TerminalDisplayThrottle` events; the view
    /// itself has no knowledge of the throttle, of
    /// SidebarPreferences, or of why it's being paused.
    /// A future libghostty backend would expose an
    /// equivalent flag on its own view layer (or use
    /// libghostty's native pause API) and consume the same
    /// throttle from its backend init.
    var displayPaused: Bool = false

    /// Suppress display invalidation when the backend has
    /// flagged us as paused. SwiftTerm fires this every
    /// time the buffer changes (per-PTY-chunk on a
    /// streaming session); with an active Claude session,
    /// that invalidation cadence keeps the runloop busy
    /// and competes with the SwiftUI commit during the
    /// sidebar toggle window. While `displayPaused` is
    /// true, drops silently; the backend triggers a
    /// catch-up redraw covering the full bounds when it
    /// unpauses.
    public override func setNeedsDisplay(_ invalidRect: NSRect) {
        if displayPaused {
            return
        }
        super.setNeedsDisplay(invalidRect)
    }

    /// Short-circuit key view traversal — same fix as InlineEditField.
    /// When any NSView becomes first responder, AppKit may walk
    /// previousValidKeyView / nextValidKeyView to validate the target.
    /// With the ZStack architecture keeping all session views alive,
    /// each traversal walks thousands of SwiftUI-managed views.
    /// Returning nil stops the walk immediately.
    override var previousValidKeyView: NSView? { nil }
    override var nextValidKeyView: NSView? { nil }

    /// Callback invoked when terminal receives a bell (BEL character)
    var onBell: (() -> Void)?

    /// When true, becomeFirstResponder/resignFirstResponder suppress
    /// focus in/out escape sequences (mode 1004) to the PTY. Set during
    /// internal session switching to prevent Claude Code from responding
    /// to focus events and triggering false busy state.
    /// Self-clearing: each responder method clears its own flag after use.
    var suppressFocusEvents = false

    // MARK: - First Responder (focus event suppression)

    public override func becomeFirstResponder() -> Bool {
        let savedSendFocus = terminal.sendFocus
        if suppressFocusEvents {
            terminal.sendFocus = false
        }
        let result = super.becomeFirstResponder()
        terminal.sendFocus = savedSendFocus
        suppressFocusEvents = false
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let savedSendFocus = terminal.sendFocus
        if suppressFocusEvents {
            terminal.sendFocus = false
        }
        let result = super.resignFirstResponder()
        terminal.sendFocus = savedSendFocus
        suppressFocusEvents = false
        return result
    }

    // MARK: - Bell

    /// Override bell() to intercept bell events without replacing terminalDelegate
    /// We don't call super.bell() because we handle all bell behavior through onBell callback
    public override func bell(source: Terminal) {
        onBell?()
    }

    // MARK: - Scroll Interception

    /// Callback invoked on scroll-wheel-up before the parent handles
    /// the event. Returns true if the event was consumed (scrollback
    /// overlay created), false to let the parent proceed normally.
    var onScrollUp: ((NSEvent) -> Bool)?

    /// Trackpad gesture lock: latched the moment yDisp reaches yBase
    /// during a scroll gesture; cleared on the next `phase == .began`.
    /// While set, all remaining events in the gesture (continued
    /// active scrolling, momentum tail, inertial rebound) are dropped
    /// — the viewport stays pinned to the bottom regardless of what
    /// inertia would have done. See the auto-follow invariants doc on
    /// `TerminalBackend` (invariant 3) for the contract this satisfies.
    ///
    /// Mouse wheel and knob drag don't use this latch. Wheel events
    /// have no `phase` data and no inertia; each click is a discrete
    /// intent. Knob drag goes through `scroll(toPosition:)` and
    /// `NSScroller`'s clamp at 1.0 makes the existing vendor path
    /// deterministic via the `atBottom` post-block in `scrollTo`.
    private var gestureLockedAtBottom: Bool = false

    public override func scrollWheel(with event: NSEvent) {
        if event.deltaY > 0, let callback = onScrollUp, callback(event) {
            return
        }

        let isTrackpadGesture =
            event.phase != [] || event.momentumPhase != []

        // Reset on a fresh trackpad gesture so the prior gesture's
        // lock doesn't carry over.
        if isTrackpadGesture && event.phase == .began {
            gestureLockedAtBottom = false
        }

        // Once locked, drop everything else from this trackpad
        // gesture. Mouse wheel events (no phase data) bypass this
        // guard since they're stateless per click.
        if isTrackpadGesture && gestureLockedAtBottom {
            return
        }

        // Inertia must not disengage follow while we are resting at
        // the live tail. A momentum-phase event that arrives while
        // the viewport is at the bottom and following (not
        // mid-gesture, not in scrollback) is an orphaned inertial
        // tail — never a deliberate scroll, because a real scroll
        // moves the viewport off the bottom during its active,
        // finger-down phase before momentum begins. Drop it so it
        // cannot nudge yDisp above yBase and silently kill auto-
        // follow. The latch above covers the downward-reach-bottom
        // case; this covers the resting-at-bottom case.
        if event.momentumPhase != [] {
            let buf = terminal.displayBuffer
            if !terminal.userScrolling && buf.yDisp >= buf.yBase {
                return
            }
        }

        let yDispBefore = terminal.displayBuffer.yDisp
        super.scrollWheel(with: event)

        let buf = terminal.displayBuffer
        // Only treat this event as "reach-bottom" if yDisp
        // actually moved downward this event AND landed at or
        // past yBase. Without the `> yDispBefore` half, an
        // at-bottom user starting a scroll-up gesture would
        // re-trigger the lock on every sub-line event (where
        // super ran but yDisp did not move), trapping them at
        // the bottom and blocking scrollback entirely.
        if buf.yDisp > yDispBefore && buf.yDisp >= buf.yBase {
            // Reached the bottom mid-gesture — snap (defensive
            // belt-and-suspenders; vendor scrollTo's atBottom
            // post-block already does this for the common case),
            // clear the auto-follow gate, and (for trackpad
            // only) lock the rest of this gesture so momentum
            // tail and rebound can't drift us back off.
            buf.yDisp = buf.yBase
            terminal.userScrolling = false
            terminal.refresh(
                startRow: 0, endRow: terminal.rows
            )
            setNeedsDisplay(bounds)
            if isTrackpadGesture {
                gestureLockedAtBottom = true
            }
        }
    }

    // MARK: - Auto-follow across text selection

    /// Restores live-tail following after a selection that began
    /// while the viewport was at the bottom.
    ///
    /// SwiftTerm freezes the viewport for the duration of a selection
    /// (so the anchor holds while output streams), and on clear sets
    /// `userScrolling = !atBottom`. When output arrives during the
    /// selection, the frozen viewport drifts below the live bottom —
    /// so that clear evaluation leaves auto-follow disengaged a few
    /// rows short, and nothing re-pins it because the feed-time
    /// recovery only fires at the exact bottom. The viewport then
    /// sticks just above the tail and never catches up.
    ///
    /// Mirroring the reflow re-pin: capture whether the viewport was
    /// following the live tail when the selection began, and on clear
    /// snap back to the bottom — but only when the user did not move
    /// the viewport during the selection. An unchanged `yDisp` means
    /// the gap is pure output drift, not an intentional scroll-away;
    /// a selection that began in scrollback, or one the user scrolled
    /// during, is left exactly where it ended.
    private var selectionStartedFollowing = false
    private var selectionStartYDisp = 0
    private var lastSelectionActive = false

    public override func selectionChanged(source: Terminal) {
        let buf = terminal.displayBuffer
        let wasActive = lastSelectionActive
        let nowActive = selection?.active ?? false

        // Capture follow intent before super freezes the viewport.
        if !wasActive && nowActive {
            selectionStartedFollowing =
                !terminal.userScrolling && buf.yDisp >= buf.yBase
            selectionStartYDisp = buf.yDisp
        }

        super.selectionChanged(source: source)

        let stillActive = selection?.active ?? false
        if wasActive && !stillActive {
            if selectionStartedFollowing,
               buf.yDisp == selectionStartYDisp,
               buf.yDisp < buf.yBase {
                buf.yDisp = buf.yBase
                terminal.userScrolling = false
                terminal.refresh(startRow: 0, endRow: terminal.rows)
                setNeedsDisplay(bounds)
            }
            selectionStartedFollowing = false
        }

        lastSelectionActive = stillActive
    }
}

