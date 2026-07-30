import Galactic

/// Buffer-level terminal operations layered on the Galactic
/// `TerminalBackend` chokepoints. Kept in Galaxy (not Galactic) so the
/// gesture needs no engine release: it rides existing public protocol
/// requirements.
extension TerminalBackend {
    /// Trim the scrollback history and reflow the viewport — the
    /// "Trim Buffer" gesture.
    ///
    /// Two steps. First a local wipe via `feed(text:)` (which the
    /// protocol sanctions for screen-clear escapes): the same escape the
    /// `clear` command emits — ESC[H (home), ESC[2J (erase screen),
    /// ESC[3J (erase scrollback) — applied directly to the emulator
    /// buffer with nothing sent to the child. That drops the scrollback
    /// and blanks the screen, but the prompt is content the child owns,
    /// so a form feed (Ctrl+L, 0x0C) is then sent out to make the child
    /// reflow its viewport onto the clean screen. In a full-screen TUI
    /// (Claude Code) that reflow repaints the current view, so the net
    /// effect is a trimmed scrollback with the live screen intact; in a
    /// plain shell it lands as a cleared screen with a fresh prompt. A
    /// program that ignores Ctrl+L simply stays blank until its next
    /// output.
    public func trimBuffer() {
        feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        reflowBuffer()
    }

    /// Reflow the viewport — the "Reflow Buffer" gesture. Sends a form
    /// feed (Ctrl+L, 0x0C) out to the child so it redraws its current
    /// screen and prompt in place. PTY-side op; the scrollback is left
    /// untouched — that's the distinction from `trimBuffer()`, which
    /// drops the scrollback before reflowing.
    public func reflowBuffer() {
        send(bytes: [0x0C])
    }
}
