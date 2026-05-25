import Foundation

/// Opaque snapshot of a terminal's scrollback at a point in
/// time. Backends produce concrete implementations from their
/// own internal buffer types; chrome holds the protocol type
/// and iterates cells when it needs to render the snapshot in
/// whatever format the chrome owns (HTML overlay, native NSView,
/// PDF export, etc.).
///
/// The snapshot freezes the buffer state at capture time —
/// subsequent PTY output extends the live buffer without
/// affecting the snapshot. Chrome can iterate the same snapshot
/// multiple times (e.g. re-render on theme or font change)
/// without re-capturing.
///
/// This protocol is the chrome-facing seam; concrete impls
/// (e.g. `SwiftTermScrollbackSnapshot` in `SwiftTermBackend`)
/// own backend-typed fields privately and translate to the
/// engine-agnostic `ScrollbackCell` representation during
/// iteration. When a future libghostty backend lands, it gets
/// its own snapshot impl reading from Ghostty's buffer types —
/// chrome doesn't change.
///
/// Rendering format choice lives in chrome. The protocol's
/// surface is intentionally limited to data accessors — no
/// `render(...) -> String` because the output format is a
/// chrome concern, not an engine concern.
public protocol ScrollbackSnapshot: AnyObject {
    /// Column count at snapshot time. Used by chrome layout
    /// (HTML/CSS column-width units, native-view sizing) and
    /// as the upper bound for per-line cell iteration.
    var cols: Int { get }

    /// Viewport top row at snapshot time. Used by chrome as
    /// the initial scroll position when opening an overlay so
    /// the overlay opens at the user's current view rather
    /// than at the bottom of the buffer.
    var yDisp: Int { get }

    /// Total line count in the snapshot (scrollback + viewport
    /// rows). Chrome iterates `0..<lineCount` calling
    /// `enumerateCells(line:visit:)` per line.
    var lineCount: Int { get }

    /// Iterate cells in the line at `lineIndex` in column
    /// order. The visitor is called once per cell, up to
    /// `cols` cells. Continuation cells (width=0) ARE yielded
    /// — chrome filters them as needed (renderers typically
    /// skip width=0 because the leading half of the wide
    /// character at column N-1 already covers columns N-1
    /// and N).
    ///
    /// Idempotent: repeated calls with the same `lineIndex`
    /// yield the same cells. Chrome can iterate the same line
    /// multiple times during a render.
    ///
    /// `lineIndex` out of `0..<lineCount` is a programmer
    /// error; impls may trap or yield no cells.
    func enumerateCells(
        line lineIndex: Int,
        visit: (ScrollbackCell) -> Void
    )
}
