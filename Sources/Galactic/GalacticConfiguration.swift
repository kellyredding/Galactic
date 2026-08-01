import AppKit

/// Configuration seam between an application's settings store
/// and the terminal engine bridge.
///
/// `TerminalBackend.applySettings(_:)` reads through this
/// protocol instead of binding directly to Galaxy's `AppSettings`
/// type, so the engine bridge can ship in a reusable module
/// (`Galactic`) without dragging Galaxy's settings storage along
/// with it. Galaxy's `AppSettings` conforms via empty extension
/// because its property names and types already match this
/// protocol's surface; other host apps would either conform
/// their own settings type, or build a small adapter that maps
/// their settings shape to these members.
///
/// The surface is what *shared terminal code* reads, which is
/// wider than what `applySettings` applies — the cursor pair is
/// on it and deliberately not applied there, because the engine
/// fuses shape and blink into one value that has to be pushed
/// through `applyCursor` instead of as per-property writes.
///
/// Wider again than the engine: a member here can govern shared
/// *behaviour* rather than describe the terminal's appearance, and
/// an app that wants none of that behaviour supplies the value
/// that turns it off. That is what keeps a behaviour one app has
/// and the other does not from being the difference between code
/// that exists and code that does not.
///
/// What stays off the protocol is anything genuinely per-pane.
/// A font *size* is the clear case: two panes of one split zoom
/// independently, so a size read from configuration would be the
/// wrong size for at least one of them. Sizes travel as arguments
/// (`applySettings(_:fontSize:)`, `setFont`) for that reason, and
/// the default below is only where a pane starts.
///
/// Property names match Galaxy's `AppSettings` shape exactly
/// so the conformance is empty. A future protocol-rename pass
/// (drop the `terminal` prefix; the protocol is already
/// terminal-specific by domain) can happen once Galactic is
/// extracted — the bridge would read clean names and Galaxy's
/// conformance would gain trivial computed properties to map.
/// That refactor is deferred to keep the protocol-introduction
/// commit zero-risk.
public protocol GalacticConfiguration {
    /// Display name of the terminal color theme to apply.
    /// Looked up in `TerminalColorTheme.theme(named:)`.
    var terminalColorThemeName: String { get }

    /// Family name of the terminal font (e.g. "SF Mono",
    /// "Menlo"). Resolved to a concrete `NSFont` via
    /// `resolveTerminalFont(family:size:)` with a monospaced
    /// fallback.
    var terminalFontFamily: String { get }

    /// Point size a terminal surface *starts* at — what a
    /// fresh pane is seeded with and what resetting zoom
    /// returns to. Not what any live surface currently uses:
    /// size is per-surface, so both `applySettings` and
    /// `setFont` take it from the caller. Nothing inside the
    /// engine bridge reads this.
    var defaultTerminalFontSize: CGFloat { get }

    /// Scrollback history depth in lines. The engine bridge
    /// passes this through to the engine's scrollback
    /// allocator on every `applySettings` call.
    var terminalScrollbackLines: Int { get }

    /// Caret shape.
    ///
    /// Read by shared terminal code but deliberately *not* applied by
    /// `applySettings`: the engine fuses shape and blink into a single cursor
    /// style, so the pair has to be pushed together through `applyCursor` and
    /// cannot ride along with the per-property writes.
    var terminalCursorStyle: ShellCursorStyle { get }

    /// Whether the caret blinks. Pushed together with the shape, per above.
    var terminalCursorBlink: Bool { get }

    /// How a text entry decides that a keystroke submits rather than inserts.
    ///
    /// On the protocol because the scrollback surface builds its composer from
    /// it, and that surface is shared: a host that had to pass these in would
    /// be the only reason it needed a settings store at all.
    var textEntry: TextEntryBindings { get }

    /// Whether scrolling up on a live terminal opens its scrollback surface.
    ///
    /// The entire opt-out for that behaviour, and the reason it can be shared
    /// at all: an app that answers false keeps the mechanism, never opens a
    /// surface by scroll, and arms no cooldown — so wanting it later is
    /// changing this value rather than building the behaviour.
    var scrollToEnterScrollback: Bool { get }
}
