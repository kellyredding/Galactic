import AppKit

/// Abstraction over the PTY + terminal rendering library.
/// Implementations wrap a concrete library (SwiftTerm via
/// `SwiftTermBackend` today; libghostty target in the
/// future). Callers address this protocol, not the library
/// directly.
///
/// The surface is intentionally minimal — just what the
/// Shell pane needs (later phases). Buffer inspection calls
/// beyond `captureScrollbackSnapshot()` (like `getLine`,
/// mouse-mode queries, etc.) are deliberately not on the
/// protocol; adding them would bloat the libghostty swap
/// surface. Extend only when a concrete use appears.
///
/// ## Auto-follow invariants
///
/// Three invariants any conforming backend must uphold so
/// that "viewport stays stuck to the bottom while output
/// streams" works consistently across the chrome:
///
/// 1. **Bottom-stick across size changes.** When the
///    viewport is at the bottom and no user scroll has
///    intervened, the implementation must keep the viewport
///    at the bottom across pixel-size changes (sidebar drag,
///    window resize, font size change). Column changes
///    recompute wrapped lines and can leave the viewport
///    short of the new bottom even without any user intent
///    to scroll up — the resize path is responsible for
///    re-pinning to the bottom.
///
/// 2. **Selection freezes the viewport.** While the user has
///    an active text selection, output must NOT auto-follow.
///    New lines extend the buffer, but the viewport stays
///    anchored so the selected region keeps pointing at the
///    same cells. On selection clear, the implementation
///    restores the viewport's pre-selection intent rather than
///    judging only by where it sits at clear time:
///    - If the selection began while the viewport was
///      following the live tail AND the user did not scroll
///      during the selection, re-pin to the bottom and resume
///      auto-follow. Any gap that opened is output that
///      drifted past while the freeze held the viewport in
///      place — not a user choice to leave the tail — so the
///      viewport returns to where it was headed.
///    - Otherwise (the selection began in scrollback, or the
///      user scrolled during it), leave the viewport exactly
///      where it ended; the user expressed a position and it
///      is honored.
///    The distinguishing signal is whether the user moved the
///    viewport during the selection, not its position at clear
///    time — output drift alone must not strand a follower
///    above the tail.
///
/// 3. **Trackpad inertia must not undo reach-bottom.** When
///    a downward trackpad gesture reaches the buffer bottom
///    mid-gesture, the implementation must hold the viewport
///    there for the remainder of the gesture and ignore
///    inertial rebound deltas that would otherwise drift it
///    off by one or two rows. Without this defense, hard
///    trackpad flicks land the user at the bottom
///    momentarily and then a tail-end upward delta nudges
///    them off — the user sees themselves at the bottom but
///    auto-follow has silently disengaged, and new output
///    streams in below the visible region.
///
/// SwiftTerm implementation:
/// - Invariants 1 and 2 are satisfied by the `Terminal`
///   class's `userScrolling` flag plus Galaxy vendor
///   patches in `processSizeChange`, `selectionChanged`,
///   and `feedPrepare`. The flag is true while a selection
///   is active or the user is in scrollback, false
///   otherwise; `Terminal.scroll()` only pins yDisp to
///   yBase on each appended line when the flag is false.
///   Invariant 2's selection-clear re-pin is layered on in
///   `GalacticSwiftTermView.selectionChanged`: it records
///   whether the viewport was following when the selection
///   began and whether `yDisp` moved during it, and on clear
///   snaps to the bottom when the only thing that opened a gap
///   was output drift.
/// - Invariant 3 is satisfied by a subclass-level latch in
///   `GalacticSwiftTermView.scrollWheel`. When a trackpad
///   gesture event moves `yDisp` downward to land at or
///   past `yBase`, the subclass snaps to the bottom, clears
///   `userScrolling`, and ignores all further events in the
///   same gesture (active continuation, momentum tail,
///   rebound) until the next `phase == .began`. The
///   downward-motion qualifier is essential — without it,
///   an at-bottom user starting a scroll-up gesture would
///   re-trigger the lock on every sub-line event (where
///   `yDisp` is at `yBase` but did not move) and become
///   unable to enter scrollback. Mouse wheel and knob drag
///   do not need this defense — wheel clicks are discrete
///   with no inertia, and `NSScroller` clamps `doubleValue`
///   at `1.0` so vendor `scroll(toPosition: 1.0)` lands
///   `yDisp` exactly at `yBase` and the `atBottom`
///   post-block in `scrollTo` clears `userScrolling`.
///
/// A libghostty backend may use different internal
/// mechanisms but the observable behavior must match.
public protocol TerminalBackend: AnyObject {
    /// The terminal surface as an NSView.
    var view: NSView { get }

    /// Launch a subprocess under the PTY.
    func startProcess(
        executable: String,
        args: [String],
        environment: [String],
        execName: String,
        currentDirectory: String
    )

    /// Terminate the running subprocess.
    ///
    /// - Parameter signal: POSIX signal number
    ///   (e.g., `SIGTERM`=15, `SIGKILL`=9).
    ///
    /// Implementations may fall back to a terse terminate
    /// if the underlying library doesn't expose signal-
    /// level control. See `SwiftTermBackend.terminateProcess`
    /// for the current caveat.
    func terminateProcess(signal: Int32)

    /// Send bytes to the PTY.
    func send(bytes: [UInt8])

    /// Send text to the PTY (UTF-8 encoded). When `asPaste` is
    /// true and the terminal has bracketed-paste-mode enabled,
    /// the implementation wraps the text in `ESC[200~` …
    /// `ESC[201~` so the remote process can distinguish a paste
    /// from typed input. When bracketed-paste-mode is disabled,
    /// `asPaste` has no effect and the text is sent verbatim.
    func send(text: String, asPaste: Bool)

    /// Adjust scrollback history size at runtime.
    func changeHistorySize(_ lines: Int)

    /// Install a 16-color ANSI palette. Implementations convert
    /// `TerminalPaletteColor` to the backend's native color
    /// representation at the boundary.
    func installColors(_ palette: [TerminalPaletteColor])

    /// Set foreground / background colors.
    func setForegroundColor(_ color: NSColor)
    func setBackgroundColor(_ color: NSColor)

    /// Set the bold-rendering foreground color (the effective
    /// foreground for cells with the SGR bold attribute set).
    /// Wraps the fork-patched `galacticBoldForegroundColor` on
    /// the SwiftTerm side; a future libghostty backend exposes
    /// a config knob with equivalent semantics.
    func setBoldForegroundColor(_ color: NSColor)

    /// Apply the host app's terminal configuration to the
    /// backend. Reads through the `GalacticConfiguration`
    /// protocol so the engine bridge does not bind to any
    /// specific settings-storage type. Galaxy's `AppSettings`
    /// conforms directly (empty extension); other host apps
    /// can conform their own settings type or build an adapter.
    /// Translates the protocol values into the backend's native
    /// config shape — for SwiftTerm that's per-property writes
    /// (font, palette, scrollback, etc.); for a future
    /// libghostty backend that's a config blob plus an
    /// `update_config` call.
    ///
    /// Idempotent and incremental: callers can fire on every
    /// settings change; the backend is responsible for
    /// skipping no-ops where it cares about that.
    func applySettings(_ settings: GalacticConfiguration)

    /// When true, the next `becomeFirstResponder` /
    /// `resignFirstResponder` call suppresses focus-event
    /// escape sequences (mode 1004) to the PTY. Self-clears
    /// after each responder transition. Set during internal
    /// session switching to prevent TUIs (Claude Code, shell
    /// prompts that redraw on focus, etc.) from interpreting
    /// the spurious focus event as a semantic signal.
    var suppressFocusEvents: Bool { get set }

    /// Inject text into the terminal as if it had arrived
    /// from the PTY. Used for cleanup escape sequences during
    /// internal pane handoffs (e.g. mode-1004 disable, screen
    /// clear). Must NOT be used as a general-purpose IO path
    /// — `send(text:asPaste:)` is the correct channel for
    /// user-facing input.
    func feed(text: String)

    /// Set the terminal font.
    func setFont(_ font: NSFont)

    /// Apply cursor appearance. SwiftTerm's native
    /// `CursorStyle` enum fuses shape + blink into one
    /// value, so we pass both here and let the backend
    /// map to the 6-case combination. Shell-only in
    /// practice today — the Session pane's caret is
    /// hidden by Claude Code's own cursor rendering, so
    /// it doesn't subscribe.
    func applyCursor(style: ShellCursorStyle, blink: Bool)

    /// Hide or show the engine's native text caret. The
    /// Session pane sets this true at setup because Claude
    /// Code self-renders the cursor and the engine's caret
    /// would double up; other panes leave it at the default
    /// (false). Each engine implements this against its own
    /// caret view — SwiftTerm exposes `caretView.isHidden`
    /// on `MacTerminalView`, libghostty exposes a similar
    /// config knob.
    func setCaretHidden(_ hidden: Bool)

    /// Capture the current scrollback buffer. Returns an
    /// opaque `ScrollbackSnapshot` that freezes the buffer +
    /// terminal state at this moment, suitable for rendering
    /// now and re-rendering later (e.g. on theme/font change
    /// while the overlay is open). Returns nil if no buffer
    /// is available (pane teardown in progress, etc.).
    func captureScrollbackSnapshot() -> ScrollbackSnapshot?

    /// Make the terminal surface first responder.
    func focus()

    /// Called when the child process exits (success or
    /// otherwise). Exit code is SwiftTerm's best effort —
    /// nil becomes 0 for normalization.
    var onProcessTerminated: ((Int32) -> Void)? { get set }

    /// Called when the terminal parses a BEL byte.
    var onBell: (() -> Void)? { get set }

    /// Called on scroll-wheel-up. Return `true` to consume
    /// the event (e.g., entered scrollback), `false` to
    /// let normal scrolling proceed.
    var onScrollUp: ((NSEvent) -> Bool)? { get set }

    /// True when the scrollback buffer has any content
    /// above the current viewport (i.e. `yBase > 0`).
    /// Used by chrome to gate scrollback overlay creation
    /// — there's no point opening the overlay if there's
    /// nothing above to look at.
    var hasScrollbackContent: Bool { get }

    /// Current viewport top row inside the scrollback
    /// buffer (`yDisp`). Used as the initial scroll
    /// position when opening the scrollback overlay so
    /// the overlay opens at the user's current view
    /// rather than at the bottom.
    var viewportRow: Int { get }

    /// Clear any active text selection on the terminal
    /// surface. Called before opening the scrollback
    /// overlay so selection state doesn't bleed across
    /// the live → frozen transition.
    func clearSelection()

    /// Active font on the terminal surface. Consumers
    /// (e.g. the scrollback HTML renderer) read `fontName`
    /// and `pointSize` for CSS matching against the live
    /// cells.
    var font: NSFont { get }

    /// Pixel height of one terminal cell. Consumers use
    /// this for CSS line-height in the scrollback overlay
    /// so frozen cells align exactly with their live
    /// counterparts during the open animation. Force-
    /// unwrapped at the SwiftTerm boundary today
    /// (`cellDimension!`); backend impls own the
    /// optionality decision.
    var cellHeight: CGFloat { get }

    /// Force a paint of the entire terminal surface. Used
    /// to recover from cases where the surface stalled
    /// (e.g. window going inactive) — `setNeedsDisplay`
    /// is too coarse for the chrome to express via AppKit
    /// alone because the chrome doesn't own the surface.
    func redraw()

    /// Unconditionally snap the viewport to the bottom of
    /// the scrollback buffer (`yDisp = yBase`) and clear
    /// the `userScrolling` gate so subsequent output auto-
    /// follows. No threshold, no selection-active guard, no
    /// return value. Used by the scrollback overlay's
    /// `onReady` hook to scroll the live terminal
    /// underneath after the overlay has fully painted.
    func snapViewportToBottom()
}
