import AppKit
@testable import Galactic

/// A terminal backend that answers readiness however a test tells it to, and
/// records what was written.
///
/// Shared rather than nested, because the readiness gate and the submit
/// verifier are two halves of the same automated-send path and drift apart if
/// each keeps its own idea of what a backend does.
final class StubBackend: TerminalBackend {
    var kitty = false
    var output = false
    var drawn = false
    var written: [String] = []
    /// Whether each write asked to be bracketed, parallel to `written`.
    /// Recorded because "an automated send never pastes" is an invariant, and
    /// one no test could see while this threw the flag away.
    var pasted: [Bool] = []
    var bytesWritten: [[UInt8]] = []

    var isKittyKeyboardActive: Bool { kitty }
    var hasReceivedOutput: Bool { output }
    var hasVisibleContent: Bool { drawn }

    func send(text: String, asPaste: Bool) {
        written.append(text)
        pasted.append(asPaste)
    }
    func send(bytes: [UInt8]) { bytesWritten.append(bytes) }

    // Unused by the tests that share this.
    var view: NSView { NSView() }
    var viewportRow: Int { 0 }
    var hasScrollbackContent: Bool { false }
    var font: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    var cellHeight: CGFloat { 12 }
    var suppressFocusEvents: Bool = false
    var onProcessTerminated: ((Int32) -> Void)?
    var onBell: (() -> Void)?
    var onScrollUp: ((NSEvent) -> Bool)?
    func captureScrollbackSnapshot() -> ScrollbackSnapshot? { nil }
    func clearSelection() {}
    func redraw() {}
    func snapViewportToBottom() {}
    func reassertFollowIfIntended() {}
    func changeHistorySize(_ lines: Int) {}
    func installColors(_ palette: [TerminalPaletteColor]) {}
    func setForegroundColor(_ color: NSColor) {}
    func setBoldForegroundColor(_ color: NSColor) {}
    func setBackgroundColor(_ color: NSColor) {}
    func setFont(_ font: NSFont) {}
    func applyCursor(style: ShellCursorStyle, blink: Bool) {}
    func setCaretHidden(_ hidden: Bool) {}
    func applySettings(
        _ settings: GalacticConfiguration, fontSize: CGFloat
    ) {}
    func feed(text: String) {}
    func startProcess(
        executable: String,
        args: [String],
        environment: [String],
        execName: String,
        currentDirectory: String
    ) {}
    func terminateProcess(signal: Int32) {}
    func focus() {}
}
