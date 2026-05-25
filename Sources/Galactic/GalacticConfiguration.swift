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
/// The surface is intentionally minimal — only the values the
/// engine bridge actually reads at `applySettings` time. Per-
/// pane overrides (font-size adjustments, cursor-style
/// subscriptions, etc.) stay on the host app and reach the
/// backend through other `TerminalBackend` protocol members
/// (`setFont`, `applyCursor`, etc.). Settings that vary by
/// pane lifecycle (Session vs Shell) are not on this protocol
/// because the engine bridge treats `applySettings` as
/// pane-agnostic.
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

    /// Default point size for terminal text. Per-pane size
    /// overrides (e.g. ⌘+/⌘− in the Shell pane, session-level
    /// adjustments) reach the backend through `setFont(_:)`
    /// separately — `applySettings` always uses this default.
    var defaultTerminalFontSize: CGFloat { get }

    /// Scrollback history depth in lines. The engine bridge
    /// passes this through to the engine's scrollback
    /// allocator on every `applySettings` call.
    var terminalScrollbackLines: Int { get }
}
