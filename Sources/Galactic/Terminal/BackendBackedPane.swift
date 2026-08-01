import AppKit

/// A pane that owns a terminal backend, and so can answer most of the pane
/// contract by asking it.
///
/// `TerminalPane` deliberately says nothing about where a pane's answers come
/// from — a pane that adapts some other object's terminal is a legitimate
/// conformer, and both apps have one. But a pane that *owns* a backend answers
/// a dozen of those members by forwarding a single call, and writing those
/// forwards out per pane per app is four copies of the same file's worth of
/// one-liners.
///
/// So this narrows the contract to the case where the answers are the backend's,
/// and supplies them. What a conformer still has to say for itself is the part
/// that is genuinely its own: which backend, what its font size is, how to push
/// that size down, and what the configured default is.
///
/// Adapter panes deliberately do not conform. Forwarding to a session model
/// rather than to a backend is the seam between the two apps, and it is the one
/// thing here that cannot be shared.
public protocol BackendBackedPane: TerminalPane {

    /// The backend this pane owns. Every default below is a call on it.
    var backend: TerminalBackend { get }

    /// This pane's own font size, which zooming moves.
    ///
    /// Settable because the zoom defaults below write it. A conformer typically
    /// publishes it, so the write announces itself to whatever is drawing.
    var fontSize: CGFloat { get set }

    /// Push `fontSize` down to the backend.
    ///
    /// The conformer's job because resolving a point size into an actual font
    /// needs the configured family, and settings storage is the app's.
    func applyFontSize()

    /// The size `resetFontSize()` returns to — the app's configured default.
    var defaultFontSize: CGFloat { get }

    /// The zoom window. Defaults to the shared one; a conformer overrides only
    /// to differ from it deliberately.
    var fontSizeBounds: TerminalFontSizeBounds { get }
}

public extension BackendBackedPane {

    // MARK: - The backend's answers

    var view: NSView { backend.view }

    var hasScrollbackContent: Bool { backend.hasScrollbackContent }

    var viewportRow: Int { backend.viewportRow }

    var font: NSFont { backend.font }

    var cellHeight: CGFloat { backend.cellHeight }

    /// Forwarded rather than stored, so a host adopting scroll-to-enter assigns
    /// a closure the engine will actually call. Stored, it would accept one and
    /// never invoke it, and the omission would be invisible from outside.
    var onScrollUp: ((NSEvent) -> Bool)? {
        get { backend.onScrollUp }
        set { backend.onScrollUp = newValue }
    }

    func clearSelection() { backend.clearSelection() }

    func redraw() { backend.redraw() }

    func snapViewportToBottom() { backend.snapViewportToBottom() }

    func trimBuffer() { backend.trimBuffer() }

    func reflowBuffer() { backend.reflowBuffer() }

    func reassertFollowIfIntended() { backend.reassertFollowIfIntended() }

    func captureScrollbackSnapshot() -> ScrollbackSnapshot? {
        backend.captureScrollbackSnapshot()
    }

    func send(text: String, asPaste: Bool) {
        backend.send(text: text, asPaste: asPaste)
    }

    func focus() { backend.focus() }

    // MARK: - Zoom

    var fontSizeBounds: TerminalFontSizeBounds { .standard }

    func increaseFontSize() {
        fontSize = fontSizeBounds.increased(from: fontSize)
        applyFontSize()
    }

    func decreaseFontSize() {
        fontSize = fontSizeBounds.decreased(from: fontSize)
        applyFontSize()
    }

    func resetFontSize() {
        fontSize = fontSizeBounds.clamped(defaultFontSize)
        applyFontSize()
    }

    var canIncreaseFontSize: Bool {
        fontSizeBounds.canIncrease(from: fontSize)
    }

    var canDecreaseFontSize: Bool {
        fontSizeBounds.canDecrease(from: fontSize)
    }
}
